#!/usr/bin/env python3
"""Static contract tests for the public platform interface and naming model."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
ENTRYPOINT = ROOT / "scripts" / "cn5g-platform.sh"


class ProductInterfaceStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.entrypoint = ENTRYPOINT.read_text(encoding="utf-8")

    def test_unified_entrypoint_is_executable_and_syntax_valid(self):
        self.assertTrue(ENTRYPOINT.stat().st_mode & 0o111)
        result = subprocess.run(
            ["bash", "-n", str(ENTRYPOINT)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_public_commands_cover_the_operating_lifecycle(self):
        for command in (
            "preflight", "deploy", "validate", "status", "dashboard",
            "test", "campaign", "verify", "destroy",
        ):
            self.assertRegex(self.entrypoint, rf"\b{re.escape(command)}\b")
        for profile in ("default", "core-only", "resource-limited", "single-ue"):
            self.assertIn(profile, self.entrypoint)
        self.assertIn("five-UE/two-DNN platform with observability", self.entrypoint)

    def test_default_profile_is_the_complete_platform(self):
        values = yaml.safe_load((ROOT / "charts" / "cn5g" / "values.yaml").read_text())
        profile = yaml.safe_load((ROOT / "profiles" / "default.yaml").read_text())
        for data in (values, profile):
            self.assertTrue(data["platform"]["enabled"])
            self.assertTrue(data["observability"]["enabled"])
            self.assertFalse(data["performance"]["enabled"])
        self.assertEqual(values["platform"]["ueReplicas"], 5)

    def test_single_ue_is_explicit_not_implicit(self):
        profile = yaml.safe_load((ROOT / "profiles" / "single-ue.yaml").read_text())
        self.assertFalse(profile["platform"]["enabled"])
        self.assertFalse(profile["observability"]["enabled"])
        self.assertFalse(profile["performance"]["enabled"])

    def test_destructive_boundary_is_explicit_and_scoped(self):
        self.assertIn("destroy --confirm", self.entrypoint)
        self.assertIn('"$script_dir/cluster-lifecycle.sh" delete --confirm', self.entrypoint)
        for forbidden in (
            "docker system prune", "docker network prune", "docker volume prune",
            "kubectl delete namespace", "iptables -F", "nft flush",
        ):
            self.assertNotIn(forbidden, self.entrypoint)

    def test_profile_switches_fail_closed(self):
        self.assertIn("active_core_profile", self.entrypoint)
        self.assertIn("guard_profile_selection", self.entrypoint)
        self.assertIn(
            "active profile %s differs from requested profile %s",
            self.entrypoint,
        )

    def test_persistence_test_targets_the_default_platform(self):
        self.assertIn(
            'persistence) "$script_dir/resilience-campaign.sh" test-mongodb ;;',
            self.entrypoint,
        )
        self.assertNotIn(
            'persistence) "$script_dir/single-ue-lifecycle.sh" test-persistence ;;',
            self.entrypoint,
        )

    def test_public_paths_do_not_use_numbered_stage_names(self):
        ignored = {".git", "artifacts", "migration", "__pycache__"}
        numbered = re.compile(r"phase[-_ ]?0?[0-9]", re.IGNORECASE)
        offenders: list[str] = []
        for path in ROOT.rglob("*"):
            relative = path.relative_to(ROOT)
            if any(part in ignored for part in relative.parts):
                continue
            if relative.parts[:2] == ("benchmarks", "raw"):
                continue
            if numbered.search(path.name):
                offenders.append(relative.as_posix())
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_landing_page_uses_product_visuals_and_one_quickstart(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn("docs/images/platform-overview.svg", readme)
        self.assertIn("service-overview-healthy.png", readme)
        self.assertIn("performance-reviewed.png", readme)
        self.assertIn("resilience-reviewed.png", readme)
        self.assertIn("scripts/cn5g-platform.sh deploy", readme)
        self.assertNotRegex(readme, r"\b[Pp]hase\s*[-_ ]?\d+")

    def test_github_metadata_does_not_override_the_repository_landing_page(self):
        self.assertFalse((ROOT / ".github" / "README.md").exists())
        self.assertTrue((ROOT / ".github" / "AUTOMATION.md").is_file())


if __name__ == "__main__":
    unittest.main()
