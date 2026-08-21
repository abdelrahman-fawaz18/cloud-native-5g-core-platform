#!/usr/bin/env python3
"""Deterministic repository and workflow policy checks for supply-chain assurance."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
VERSION_FILE = ROOT / "versions" / "assurance-toolchain.env"
EXCLUDED_PARTS = {".git", "artifacts", "migration", "__pycache__"}


class CheckFailure(RuntimeError):
    """A release-gate policy did not pass."""


def repository_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return [
        ROOT / item
        for item in result.stdout.splitlines()
        if item and not any(part in EXCLUDED_PARTS for part in Path(item).parts)
    ]


def load_versions() -> dict[str, str]:
    values: dict[str, str] = {}
    assignment = re.compile(r"^([A-Z0-9_]+)='([^']*)'$")
    for number, line in enumerate(VERSION_FILE.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        match = assignment.fullmatch(line)
        if not match:
            raise CheckFailure(f"invalid supply-chain assurance version assignment at line {number}")
        key, value = match.groups()
        if key in values:
            raise CheckFailure(f"duplicate supply-chain assurance version key: {key}")
        values[key] = value
    return values


def check_workflow() -> None:
    versions = load_versions()
    workflow = Path(os.environ.get("ASSURANCE_WORKFLOW_PATH", WORKFLOW))
    text = workflow.read_text(encoding="utf-8")
    data = yaml.load(text, Loader=yaml.BaseLoader)
    if set(data) - {"name", "on", "permissions", "concurrency", "jobs"}:
        raise CheckFailure("workflow contains an unexpected top-level key")
    if data.get("permissions") != {"contents": "read"}:
        raise CheckFailure("workflow permissions must be exactly contents: read")
    events = data.get("on", {})
    if "pull_request_target" in events:
        raise CheckFailure("pull_request_target is prohibited")
    if not {"pull_request", "push", "workflow_dispatch"}.issubset(events):
        raise CheckFailure("workflow must run for pull requests, main pushes, and dispatch")
    if "secrets." in text or "${{ secrets" in text:
        raise CheckFailure("the unprivileged workflow must not consume repository secrets")

    expected_actions = {
        "actions/checkout": versions["ASSURANCE_CHECKOUT_ACTION_SHA"],
        "actions/setup-python": versions["ASSURANCE_SETUP_PYTHON_ACTION_SHA"],
        "actions/upload-artifact": versions["ASSURANCE_UPLOAD_ARTIFACT_ACTION_SHA"],
    }
    uses = re.findall(r"^\s*-?\s*uses:\s*([^\s#]+)", text, flags=re.MULTILINE)
    if not uses:
        raise CheckFailure("workflow has no actions")
    for reference in uses:
        if reference.startswith("./") or reference.startswith("docker://"):
            continue
        if "@" not in reference:
            raise CheckFailure(f"action has no immutable reference: {reference}")
        action, revision = reference.rsplit("@", 1)
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise CheckFailure(f"action is not pinned to a full commit SHA: {reference}")
        if action not in expected_actions:
            raise CheckFailure(f"unreviewed external action: {action}")
        if expected_actions[action] != revision:
            raise CheckFailure(f"action SHA differs from versions/assurance-toolchain.env: {action}")

    for job_name, job in data.get("jobs", {}).items():
        if "timeout-minutes" not in job:
            raise CheckFailure(f"workflow job lacks timeout-minutes: {job_name}")
        if job.get("runs-on") != "ubuntu-24.04":
            raise CheckFailure(f"workflow job is not pinned to ubuntu-24.04: {job_name}")
        for step in job.get("steps", []):
            if step.get("uses", "").startswith("actions/checkout@"):
                if step.get("with", {}).get("persist-credentials") != "false":
                    raise CheckFailure("checkout must disable persisted credentials")
    print("assurance_workflow_policy=pass permissions=contents-read actions=full-sha")


def check_dockerfiles() -> None:
    dockerfile_root = Path(os.environ.get("ASSURANCE_DOCKERFILE_ROOT", ROOT / "containers"))
    dockerfiles = sorted(dockerfile_root.glob("*/Dockerfile"))
    if not dockerfiles:
        raise CheckFailure("no project Dockerfiles found")
    for path in dockerfiles:
        text = path.read_text(encoding="utf-8")
        args = dict(re.findall(r"^ARG\s+([A-Z0-9_]+)=([^\s]+)$", text, re.MULTILINE))
        for base in re.findall(r"^FROM\s+([^\s]+)", text, re.MULTILINE):
            if base.startswith("${") and base.endswith("}"):
                base = args.get(base[2:-1], "")
            if "@sha256:" not in base:
                raise CheckFailure(f"unpinned base image in {path}: {base}")
        for line in text.splitlines():
            if re.match(r"^ADD\s+https?://", line) and "--checksum=sha256:" not in line:
                raise CheckFailure(f"remote ADD lacks checksum in {path}")
    print(f"assurance_docker_source_policy=pass dockerfiles={len(dockerfiles)}")


def check_structured_data() -> None:
    json_count = 0
    yaml_count = 0
    for path in repository_files():
        if path.suffix == ".json":
            json.loads(path.read_text(encoding="utf-8"))
            json_count += 1
        elif (
            path.suffix in {".yaml", ".yml"}
            and ".github/workflows" not in path.as_posix()
            and not (
                "charts" in path.parts
                and "templates" in path.parts
            )
        ):
            list(yaml.safe_load_all(path.read_text(encoding="utf-8")))
            yaml_count += 1
    print(f"assurance_structured_data=pass json={json_count} yaml={yaml_count}")


def slug(value: str) -> str:
    value = re.sub(r"<[^>]+>", "", value).strip().lower()
    value = re.sub(r"[^\w\- ]", "", value)
    return re.sub(r"[ _]+", "-", value)


def check_markdown_links() -> None:
    link_pattern = re.compile(r"(?<!!)\[[^\]]*\]\(([^)]+)\)")
    headings: dict[Path, set[str]] = {}
    errors: list[str] = []
    markdown = [path for path in repository_files() if path.suffix.lower() == ".md"]
    for path in markdown:
        text = path.read_text(encoding="utf-8")
        headings[path.resolve()] = {
            slug(match.group(1))
            for match in re.finditer(r"^#{1,6}\s+(.+?)\s*$", text, re.MULTILINE)
        }
    for path in markdown:
        for raw in link_pattern.findall(path.read_text(encoding="utf-8")):
            target = raw.strip().split(maxsplit=1)[0].strip("<>")
            if not target or re.match(r"^(https?|mailto):", target):
                continue
            file_part, separator, anchor = unquote(target).partition("#")
            resolved = (path.parent / file_part).resolve() if file_part else path.resolve()
            try:
                resolved.relative_to(ROOT)
            except ValueError:
                errors.append(f"{path.relative_to(ROOT)}: link escapes repository: {target}")
                continue
            if not resolved.exists():
                errors.append(f"{path.relative_to(ROOT)}: missing target: {target}")
            elif separator and resolved.suffix.lower() == ".md":
                if anchor not in headings.get(resolved, set()):
                    errors.append(f"{path.relative_to(ROOT)}: missing heading: {target}")
    if errors:
        raise CheckFailure("\n".join(errors))
    print(f"assurance_local_links=pass markdown_files={len(markdown)}")


def check_privacy() -> None:
    forbidden = {
        "local home path": re.compile(r"/home/[A-Za-z0-9._-]+/"),
        "private migration material": re.compile(r"migration/0[1-9]_"),
    }
    findings: list[str] = []
    for path in repository_files():
        if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".gif", ".pdf"}:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        relative = path.relative_to(ROOT)
        for label, pattern in forbidden.items():
            if pattern.search(text):
                findings.append(f"{relative}: {label}")
    if findings:
        raise CheckFailure("\n".join(findings))
    print("assurance_publication_boundary=pass private_paths=absent")


CHECKS = {
    "workflow": check_workflow,
    "dockerfiles": check_dockerfiles,
    "data": check_structured_data,
    "links": check_markdown_links,
    "privacy": check_privacy,
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("check", choices=[*CHECKS, "all"])
    args = parser.parse_args()
    selected = CHECKS.values() if args.check == "all" else [CHECKS[args.check]]
    try:
        for function in selected:
            function()
    except (CheckFailure, OSError, ValueError, json.JSONDecodeError, yaml.YAMLError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
