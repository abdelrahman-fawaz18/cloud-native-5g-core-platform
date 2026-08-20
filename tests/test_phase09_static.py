#!/usr/bin/env python3
"""Static safety and release-contract tests for Phase 9."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
VERSIONS = ROOT / "versions" / "phase-09.env"
LIFECYCLE = ROOT / "scripts" / "phase09-lab.sh"
CHECKER = ROOT / "scripts" / "check-phase09-policies.py"
POLICY = ROOT / "policy" / "kubernetes.rego"
ARCHITECTURE = ROOT / "docs" / "architecture" / "phase-09-ci-security.md"
RUNBOOK = ROOT / "docs" / "runbooks" / "phase-09-release-gate.md"
REPORT = ROOT / "reports" / "09_phase09_security.md"


def version_values_from(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([A-Z0-9_]+)='([^']*)'", line)
        if match:
            result[match.group(1)] = match.group(2)
    return result


def version_values() -> dict[str, str]:
    return version_values_from(VERSIONS)


class Phase09StaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow_text = WORKFLOW.read_text(encoding="utf-8")
        cls.workflow = yaml.load(cls.workflow_text, Loader=yaml.BaseLoader)
        cls.versions = version_values()
        cls.lifecycle = LIFECYCLE.read_text(encoding="utf-8")
        cls.checker = CHECKER.read_text(encoding="utf-8")
        cls.policy = POLICY.read_text(encoding="utf-8")

    def test_tool_and_action_identities_are_complete_and_immutable(self):
        self.assertNotIn("latest", VERSIONS.read_text(encoding="utf-8").lower())
        urls = [value for key, value in self.versions.items() if key.endswith("_URL")]
        checksums = [
            value for key, value in self.versions.items() if key.endswith("_SHA256")
        ]
        actions = [
            value for key, value in self.versions.items()
            if key.endswith("_ACTION_SHA")
        ]
        self.assertEqual(len(urls), 11)
        self.assertEqual(len(checksums), 11)
        self.assertEqual(len(actions), 3)
        self.assertTrue(all(url.startswith("https://github.com/") for url in urls))
        self.assertTrue(all(re.fullmatch(r"[0-9a-f]{64}", item) for item in checksums))
        self.assertTrue(all(re.fullmatch(r"[0-9a-f]{40}", item) for item in actions))
        for name in (
            "PHASE_09_DATA_NETWORK_IMAGE_ID", "PHASE_09_BENCHMARK_IMAGE_ID"
        ):
            self.assertRegex(self.versions[name], r"^sha256:[0-9a-f]{64}$")
        self.assertEqual(
            self.versions["PHASE_09_DATA_NETWORK_IMAGE_ID"],
            version_values_from(ROOT / "versions" / "phase-02.env")[
                "DATA_NETWORK_LOCAL_IMAGE_ID"
            ],
        )

    def test_workflow_has_read_only_hosted_boundary(self):
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        events = self.workflow["on"]
        self.assertIn("pull_request", events)
        self.assertIn("push", events)
        self.assertIn("workflow_dispatch", events)
        self.assertNotIn("pull_request_target", events)
        self.assertNotIn("secrets.", self.workflow_text)
        self.assertNotIn("self-hosted", self.workflow_text)
        for job in self.workflow["jobs"].values():
            self.assertEqual(job["runs-on"], "ubuntu-24.04")
            self.assertIn("timeout-minutes", job)
        self.assertEqual(self.workflow_text.count("persist-credentials: false"), 2)

    def test_workflow_actions_match_version_contract(self):
        expected = {
            value for key, value in self.versions.items()
            if key.endswith("_ACTION_SHA")
        }
        references = re.findall(r"uses:\s+[^@\s]+@([0-9a-f]{40})", self.workflow_text)
        self.assertEqual(set(references), expected)
        self.assertEqual(len(references), 6)

    def test_lifecycle_is_fail_closed_and_does_not_publish_or_prune(self):
        for required in (
            "phase09_safe_gate=pass", "phase09_image_gate=pass",
            "phase09_privileged_gate=pass", "gitleaks git", "trivy fs",
            "trivy image", "spdx-json", "kubeconform -strict",
            "conftest test", "phase05-lab.sh\" validate",
            "phase06-lab.sh\" validate", "registry_push=none",
            "phase09_image_promotion=pass", "rollback-images --confirm",
            "phase09_image_promotion_rollback=pass",
            "phase09_core_image_promotion=already-active upgrade=skipped",
        ):
            self.assertIn(required, self.lifecycle)
        for forbidden in (
            "docker system prune", "docker push", "kubectl delete namespace",
            "kind delete cluster", "helm uninstall", "git push",
        ):
            self.assertNotIn(forbidden, self.lifecycle.lower())

    def test_negative_controls_cover_four_failure_classes(self):
        for required in (
            "actions/checkout@main", "FROM alpine:latest",
            "privileged: true", "SYNTHETIC_TEST_TOKEN",
            "phase09_negative_controls=pass",
            "printf -v cleanup 'rm -rf -- %q' \"$temp\"",
            "trap - RETURN",
        ):
            self.assertIn(required, self.lifecycle)

    def test_repository_checker_compiles_and_accepts_current_sources(self):
        compile(self.checker, str(CHECKER), "exec")
        result = subprocess.run(
            [str(CHECKER), "all"], cwd=ROOT, check=False,
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("phase09_workflow_policy=pass", result.stdout)
        self.assertIn("phase09_publication_boundary=pass", result.stdout)

    def test_docker_sources_and_data_network_privilege_boundary_are_exact(self):
        for dockerfile in sorted((ROOT / "containers").glob("*/Dockerfile")):
            text = dockerfile.read_text(encoding="utf-8")
            args = dict(re.findall(r"^ARG\s+([A-Z0-9_]+)=([^\s]+)$", text, re.M))
            for base in re.findall(r"^FROM\s+([^\s]+)", text, re.M):
                if base.startswith("${"):
                    base = args[base[2:-1]]
                self.assertIn("@sha256:", base, dockerfile)
        alpine_sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (
                ROOT / "containers" / "benchmark" / "Dockerfile",
                ROOT / "containers" / "data-network" / "Dockerfile",
            )
        )
        self.assertEqual(alpine_sources.count("alpine:3.22.5@sha256:"), 2)
        self.assertNotIn("alpine:3.22.1", alpine_sources)
        network = (ROOT / "containers" / "data-network" / "Dockerfile").read_text(
            encoding="utf-8"
        )
        self.assertIn("USER 0:0", network)
        entrypoint = (
            ROOT / "containers" / "data-network" / "entrypoint.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("ip route replace 10.60.0.0/24 via 10.62.0.2", entrypoint)
        self.assertIn("exec su-exec 65532:65532", entrypoint)
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        block = compose.split("  data-network:\n", 1)[1].split("\n  gnb:\n", 1)[0]
        self.assertIn('user: "0:0"', block)
        self.assertIn("- NET_ADMIN", block)
        self.assertIn("- SETGID", block)
        self.assertIn("- SETUID", block)
        self.assertIn("no-new-privileges:true", block)
        rendered = subprocess.run(
            [
                "helm", "template", "cn5g", str(ROOT / "charts" / "cn5g"),
                "--namespace", "cn5g", "--kube-version", "1.36.1",
                "--values", str(ROOT / "charts" / "cn5g" / "values-phase05.yaml"),
                "--values", str(ROOT / "charts" / "cn5g" / "values-phase06.yaml"),
            ],
            cwd=ROOT, check=False, capture_output=True, text=True,
        )
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        self.assertIn("runAsUser: 65532", rendered.stdout)
        self.assertIn("capabilities: {drop: [\"ALL\"]}", rendered.stdout)
        self.assertIn("cn5g.io/expected-image-id:", rendered.stdout)

    def test_policy_prohibits_broad_privilege_and_keeps_exact_exceptions(self):
        for required in (
            "must not be privileged", "must not use hostNetwork",
            "must not use hostPID", "must not use hostIPC",
            "permits privilege escalation", '"/dev/net/tun"',
            '"NET_ADMIN"', '"NET_RAW"', "approved_token_workload",
        ):
            self.assertIn(required, self.policy)
        self.assertNotIn('"privileged": true', self.policy)
        self.assertIn("approved_node_proxy_rule(rule)", self.policy)
        self.assertIn('object.get(rule, "verbs", []) == ["get"]', self.policy)

    def test_python_ci_dependency_is_version_and_hash_locked(self):
        requirements = (ROOT / "requirements-ci.txt").read_text(encoding="utf-8")
        self.assertIn("PyYAML==6.0.2", requirements)
        self.assertEqual(requirements.count("--hash=sha256:"), 2)
        self.assertIn("--require-hashes", self.workflow_text)

    def test_exception_files_are_narrow_documented_and_expiring(self):
        trivy = yaml.safe_load((ROOT / ".trivyignore.yaml").read_text(encoding="utf-8"))
        findings = trivy["misconfigurations"]
        self.assertTrue(findings)
        for finding in findings:
            self.assertIn("paths", finding)
            self.assertTrue(all("*" not in path for path in finding["paths"]))
            self.assertGreaterEqual(len(finding["statement"]), 40)
            self.assertRegex(str(finding["expired_at"]), r"^2027-")
        gitleaks = (ROOT / ".gitleaks.toml").read_text(encoding="utf-8")
        self.assertIn("useDefault = true", gitleaks)
        self.assertIn("targetRules", gitleaks)
        self.assertNotIn("stopwords", gitleaks)

    def test_public_phase09_docs_explain_claims_and_rollback_without_private_data(self):
        public = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (ARCHITECTURE, RUNBOOK, REPORT)
        )
        for required in (
            "Continuous Integration", "SBOM", "policy-as-code",
            "privileged gate", "negative controls", "rollback",
            "does not", "Phase 5", "Phase 6",
        ):
            self.assertIn(required.lower(), public.lower())
        self.assertNotIn("/home/", public)
        self.assertNotIn("fawaz", public.lower())

    def test_report_does_not_overclaim_pending_hosted_or_privileged_results(self):
        report = REPORT.read_text(encoding="utf-8")
        self.assertIn("Pending Acceptance Evidence", report)
        self.assertIn("GitHub-hosted workflow results", report)
        self.assertIn(
            "A skipped or unavailable gate is never recorded as passing", report
        )


if __name__ == "__main__":
    unittest.main()
