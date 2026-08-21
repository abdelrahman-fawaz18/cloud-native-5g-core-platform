#!/usr/bin/env python3
"""Static release-readiness and safety-contract tests for Phase 10."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
LIFECYCLE = ROOT / "scripts" / "phase10-lab.sh"
CHECKER = ROOT / "scripts" / "check-phase10-release.py"
CONTRACT = ROOT / "release" / "phase-10-evidence.json"
ARCHITECTURE = ROOT / "docs" / "architecture" / "phase-10-release-readiness.md"
RUNBOOK = ROOT / "docs" / "runbooks" / "phase-10-release.md"
VISUAL_RULES = ROOT / "docs" / "images" / "dashboards" / "README.md"
GALLERY = ROOT / "docs" / "dashboard-gallery.md"


class Phase10StaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lifecycle = LIFECYCLE.read_text(encoding="utf-8")
        cls.checker = CHECKER.read_text(encoding="utf-8")
        cls.contract = json.loads(CONTRACT.read_text(encoding="utf-8"))

    def test_candidate_contract_is_bounded_and_traceable(self):
        self.assertEqual(self.contract["schema_version"], 1)
        self.assertEqual(self.contract["release_candidate"], "v1.0.0")
        self.assertIn(self.contract["status"], {"candidate", "accepted"})
        self.assertGreaterEqual(len(self.contract["claims"]), 7)
        for claim in self.contract["claims"]:
            self.assertTrue(claim["id"])
            self.assertTrue(claim["claim"])
            self.assertTrue(claim["scope_limit"])
            self.assertTrue(claim["evidence"])
            for evidence in claim["evidence"]:
                self.assertTrue((ROOT / evidence).is_file(), evidence)

    def test_candidate_checker_compiles_and_passes_without_visual_overclaim(self):
        compile(self.checker, str(CHECKER), "exec")
        result = subprocess.run(
            [str(CHECKER), "candidate"], cwd=ROOT, check=False,
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("phase10_release_structure=pass", result.stdout)
        self.assertIn("phase10_claim_traceability=pass", result.stdout)
        self.assertIn("phase10_publication_privacy=pass", result.stdout)

    def test_visual_gate_requires_four_roles_and_source_bound_metadata(self):
        for required in (
            'required_roles = {"overview", "telecom", "performance", "reliability"}',
            'len(captures) < 4',
            'chunks & {"tEXt", "zTXt", "iTXt", "eXIf"}',
            'width < 1200 or height < 600',
            'digest != capture.get("sha256")',
            'uid not in sources',
            're.fullmatch(r"[0-9a-f]{40}"',
        ):
            self.assertIn(required, self.checker)

    def test_final_gate_requires_accepted_contract_visuals_and_ready_report(self):
        for required in (
            "check_visuals()",
            'contract.get("status") != "accepted"',
            '"Release decision: READY" not in report',
            "phase10_public_release_gate=pass decision=ready",
            "phase10_release_audit=pass decision=ready",
            "verify_local_evidence",
            "require_clean_candidate",
        ):
            source = self.checker if required in self.checker else self.lifecycle
            self.assertIn(required, source)

    def test_lifecycle_is_scoped_and_never_publishes_or_deletes(self):
        for required in (
            "git clone --quiet --local --no-hardlinks --no-checkout",
            'checkout --quiet --detach "$commit"',
            '"$script_dir/phase09-lab.sh" privileged-gate',
            "phase10_clean_checkout=pass",
            "phase10_privileged_gate=pass",
            "phase10_clean_runtime_targets=reviewed",
            "phase10_clean_runtime_rebind=pass",
            "merge-base --is-ancestor",
            ".target_review_commit",
            "phase10_clean_deployment=pass",
            "phase10_clean_runtime=pass deployment=pass teardown=pass",
            'recreated_node_id != "$source_node_id"',
            '"$clean_runtime_evidence"',
            "phase10_hosted_gate=pass privileged_validation=not-run",
        ):
            self.assertIn(required, self.lifecycle)
        for forbidden in (
            "docker system prune", "kind delete cluster", "helm uninstall",
            "kubectl delete namespace", "docker push", "git push", "git tag",
            "gh release create", "rm -rf",
        ):
            self.assertNotIn(forbidden, self.lifecycle.lower())

    def test_publication_scan_rejects_sensitive_material(self):
        for required in (
            're.compile(r"(^|/)AGENTS\\.md$")',
            're.compile(r"(^|/)migration/")',
            're.compile(r"(^|/)artifacts/")',
            '"absolute user home path"',
            '"GitHub token shape"',
            '"private key material"',
        ):
            self.assertIn(required, self.checker)

    def test_release_docs_explain_boundary_and_destructive_clean_lab_caveat(self):
        public = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (ARCHITECTURE, RUNBOOK, VISUAL_RULES)
        ).lower()
        for required in (
            "clean-clone", "local privileged", "dashboard", "sha-256",
            "source of truth", "volume claim", "explicit confirmation",
            "does not", "git tag",
        ):
            self.assertIn(required, public)
        self.assertNotIn("/home/", public)

    def test_gallery_links_every_required_visual_role(self):
        gallery = GALLERY.read_text(encoding="utf-8")
        for image in (
            "service-overview-healthy.png",
            "telecom-sessions-and-dnns-healthy.png",
            "phase07-performance-reviewed.png",
            "phase08-reliability-reviewed.png",
        ):
            self.assertIn(image, gallery)

    def test_license_and_third_party_notices_exist(self):
        license_text = (ROOT / "LICENSE").read_text(encoding="utf-8")
        notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
        self.assertIn("Apache License", license_text)
        self.assertIn("Version 2.0, January 2004", license_text)
        for required in (
            "Open5GS", "UERANSIM", "MongoDB", "Prometheus", "Grafana",
            "Loki", "Alloy", "kube-state-metrics",
        ):
            self.assertIn(required, notices)


if __name__ == "__main__":
    unittest.main()
