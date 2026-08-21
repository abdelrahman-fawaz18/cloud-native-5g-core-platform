#!/usr/bin/env python3
"""Fail-closed publication, claim, and visual-evidence checks for Phase 10."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / "release" / "phase-10-evidence.json"
VISUALS = ROOT / "release" / "dashboard-evidence.json"
REPORT = ROOT / "reports" / "10_release_readiness.md"
EXCLUDED_PARTS = {".git", "artifacts", "migration", "__pycache__"}


class CheckFailure(RuntimeError):
    """A Phase 10 release requirement did not pass."""


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


def load_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise CheckFailure(f"required file is absent: {path.relative_to(ROOT)}") from error
    if not isinstance(data, dict):
        raise CheckFailure(f"expected a JSON object: {path.relative_to(ROOT)}")
    return data


def relative_file(value: str) -> Path:
    path = (ROOT / value).resolve()
    try:
        path.relative_to(ROOT)
    except ValueError as error:
        raise CheckFailure(f"evidence path escapes the repository: {value}") from error
    if not path.is_file():
        raise CheckFailure(f"evidence file is absent: {value}")
    return path


def check_structure() -> None:
    required = (
        "LICENSE",
        "THIRD_PARTY_NOTICES.md",
        "release/README.md",
        "release/phase-10-evidence.json",
        "scripts/phase10-lab.sh",
        "scripts/check-phase10-release.py",
        "tests/test_phase10_static.py",
        "docs/architecture/phase-10-release-readiness.md",
        "docs/runbooks/phase-10-release.md",
        "docs/dashboard-gallery.md",
        "docs/images/dashboards/README.md",
    )
    for item in required:
        relative_file(item)
    contract = load_json(CONTRACT)
    if contract.get("schema_version") != 1:
        raise CheckFailure("Phase 10 evidence schema_version must be 1")
    if contract.get("release_candidate") != "v1.0.0":
        raise CheckFailure("release candidate must be v1.0.0")
    if contract.get("status") not in {"candidate", "accepted"}:
        raise CheckFailure("evidence status must be candidate or accepted")
    if len(contract.get("claims", [])) < 7:
        raise CheckFailure("at least seven bounded release claims are required")
    print(
        "phase10_release_structure=pass "
        f"claims={len(contract['claims'])} status={contract['status']}"
    )


def check_claims() -> None:
    contract = load_json(CONTRACT)
    identifiers: set[str] = set()
    evidence_count = 0
    for claim in contract.get("claims", []):
        if not isinstance(claim, dict):
            raise CheckFailure("every release claim must be an object")
        identifier = claim.get("id", "")
        if not re.fullmatch(r"[a-z0-9-]+", identifier):
            raise CheckFailure(f"invalid claim identifier: {identifier!r}")
        if identifier in identifiers:
            raise CheckFailure(f"duplicate claim identifier: {identifier}")
        identifiers.add(identifier)
        if not claim.get("claim") or not claim.get("scope_limit"):
            raise CheckFailure(f"claim or scope limit is absent: {identifier}")
        evidence = claim.get("evidence", [])
        if not evidence:
            raise CheckFailure(f"claim has no evidence: {identifier}")
        for value in evidence:
            relative_file(value)
            evidence_count += 1
    print(
        f"phase10_claim_traceability=pass claims={len(identifiers)} "
        f"evidence_links={evidence_count}"
    )


def check_privacy() -> None:
    prohibited_tracked = (
        re.compile(r"(^|/)AGENTS\.md$"),
        re.compile(r"(^|/)migration/"),
        re.compile(r"(^|/)artifacts/"),
        re.compile(r"\.(?:pcap|pcapng|cap|har|kubeconfig|pem|key|p12)$", re.I),
    )
    forbidden_text = {
        "absolute user home path": re.compile(r"/home/[A-Za-z0-9._-]+/"),
        "terminal prompt": re.compile(
            r"\b[A-Za-z][A-Za-z0-9._-]*@[A-Za-z0-9._-]+:(?:~|/)[^\n]*\$"
        ),
        "private migration reference": re.compile(r"migration/0[1-9]_"),
        "GitHub token shape": re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"),
        "private key material": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    }
    findings: list[str] = []
    files = repository_files()
    for path in files:
        relative = path.relative_to(ROOT).as_posix()
        for pattern in prohibited_tracked:
            if pattern.search(relative):
                findings.append(f"{relative}: prohibited publication path")
        if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".gif", ".svg", ".pdf"}:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for label, pattern in forbidden_text.items():
            if pattern.search(text):
                findings.append(f"{relative}: {label}")
    if findings:
        raise CheckFailure("\n".join(findings))
    print(f"phase10_publication_privacy=pass files={len(files)}")


def png_metadata(path: Path) -> tuple[int, int, set[str]]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise CheckFailure(f"dashboard evidence is not PNG: {path.relative_to(ROOT)}")
    offset = 8
    width = height = 0
    chunks: set[str] = set()
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        kind = data[offset + 4 : offset + 8].decode("ascii", errors="replace")
        payload_start = offset + 8
        payload_end = payload_start + length
        if payload_end + 4 > len(data):
            raise CheckFailure(f"truncated PNG: {path.relative_to(ROOT)}")
        chunks.add(kind)
        if kind == "IHDR":
            width, height = struct.unpack(">II", data[payload_start : payload_start + 8])
        offset = payload_end + 4
        if kind == "IEND":
            break
    return width, height, chunks


def dashboard_sources() -> dict[str, dict]:
    result: dict[str, dict] = {}
    root = ROOT / "charts" / "cn5g-observability" / "files" / "dashboards"
    for path in sorted(root.glob("*.json")):
        data = load_json(path)
        result[data.get("uid", "")] = {"title": data.get("title"), "path": path}
    return result


def check_visuals() -> None:
    manifest = load_json(VISUALS)
    if manifest.get("schema_version") != 1 or manifest.get("status") != "accepted":
        raise CheckFailure("dashboard evidence must use schema 1 and accepted status")
    captures = manifest.get("captures", [])
    if len(captures) < 4:
        raise CheckFailure("at least four accepted dashboard captures are required")
    required_roles = {"overview", "telecom", "performance", "reliability"}
    observed_roles: set[str] = set()
    sources = dashboard_sources()
    for capture in captures:
        role = capture.get("role", "")
        observed_roles.add(role)
        path = relative_file(capture.get("file", ""))
        if path.suffix.lower() != ".png":
            raise CheckFailure(f"dashboard evidence must be PNG: {path.relative_to(ROOT)}")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != capture.get("sha256"):
            raise CheckFailure(f"dashboard evidence checksum mismatch: {path.relative_to(ROOT)}")
        width, height, chunks = png_metadata(path)
        if width < 1200 or height < 600:
            raise CheckFailure(
                f"dashboard evidence is too small ({width}x{height}): {path.relative_to(ROOT)}"
            )
        unsafe_chunks = chunks & {"tEXt", "zTXt", "iTXt", "eXIf"}
        if unsafe_chunks:
            raise CheckFailure(
                f"dashboard PNG contains unreviewed metadata {sorted(unsafe_chunks)}: "
                f"{path.relative_to(ROOT)}"
            )
        uid = capture.get("dashboard_uid", "")
        if uid not in sources:
            raise CheckFailure(f"unknown dashboard UID in visual evidence: {uid}")
        if sources[uid]["title"] != capture.get("dashboard_title"):
            raise CheckFailure(f"dashboard title does not match source JSON: {uid}")
        for field in ("captured_at", "git_commit", "time_range", "scenario", "proof"):
            if not capture.get(field):
                raise CheckFailure(f"visual evidence lacks {field}: {path.relative_to(ROOT)}")
        if not re.fullmatch(r"[0-9a-f]{40}", capture["git_commit"]):
            raise CheckFailure(f"invalid visual commit identity: {path.relative_to(ROOT)}")
    missing = required_roles - observed_roles
    if missing:
        raise CheckFailure(f"required dashboard roles are absent: {sorted(missing)}")
    print(f"phase10_visual_evidence=pass captures={len(captures)} roles=4")


def check_public_release() -> None:
    check_structure()
    check_claims()
    check_privacy()
    check_visuals()
    contract = load_json(CONTRACT)
    if contract.get("status") != "accepted":
        raise CheckFailure("public evidence contract is not accepted")
    report = REPORT.read_text(encoding="utf-8") if REPORT.is_file() else ""
    if "Release decision: READY" not in report:
        raise CheckFailure("release-readiness report has no READY decision")
    if re.search(r"\b(?:TODO|TBD|PENDING)\b", report, re.I):
        raise CheckFailure("release-readiness report still contains a pending marker")
    print("phase10_public_release_gate=pass decision=ready")


CHECKS = {
    "structure": check_structure,
    "claims": check_claims,
    "privacy": check_privacy,
    "visuals": check_visuals,
    "public-release": check_public_release,
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("check", choices=[*CHECKS, "candidate"])
    args = parser.parse_args()
    selected = (
        (check_structure, check_claims, check_privacy)
        if args.check == "candidate"
        else (CHECKS[args.check],)
    )
    try:
        for function in selected:
            function()
    except (CheckFailure, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
