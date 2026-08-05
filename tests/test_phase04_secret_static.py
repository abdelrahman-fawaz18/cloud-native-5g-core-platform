#!/usr/bin/env python3
"""Static tests for the Phase 4 synthetic-subscriber material boundary."""

from __future__ import annotations

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "generate-subscriber-secret.sh"
TEMPLATE_DIR = ROOT / "configs" / "kubernetes" / "phase-04" / "secret-templates"


class Phase04SecretStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = SCRIPT.read_text(encoding="utf-8")
        cls.ue_template = (TEMPLATE_DIR / "ue.yaml.tmpl").read_text(encoding="utf-8")
        cls.subscriber_template = (
            TEMPLATE_DIR / "subscriber-init.js.tmpl"
        ).read_text(encoding="utf-8")

    def test_generator_is_valid_bash(self):
        result = subprocess.run(
            ["bash", "-n", str(SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_check_mode_is_read_only_and_current_state_is_valid(self):
        result = subprocess.run(
            [str(SCRIPT), "--check"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("check_result=pass", result.stdout)

    def test_runtime_output_is_inside_an_ignored_artifact_directory(self):
        self.assertIn("artifacts/secrets/phase-04", self.script)
        result = subprocess.run(
            ["git", "check-ignore", "-q", "artifacts/secrets/phase-04/ue.yaml"],
            cwd=ROOT,
            check=False,
        )
        self.assertEqual(result.returncode, 0)

    def test_templates_contain_placeholders_not_authentication_values(self):
        for template in (self.ue_template, self.subscriber_template):
            self.assertIn("__SUBSCRIBER_KEY__", template)
            self.assertIn("__SUBSCRIBER_OPC__", template)
        self.assertIn("__GNB_IP__", self.ue_template)

    def test_generator_creates_random_values_without_printing_them(self):
        self.assertGreaterEqual(self.script.count("openssl rand -hex 16"), 2)
        self.assertIn("unset subscriber_key subscriber_opc", self.script)
        self.assertNotIn("--from-literal", self.script)
        self.assertNotIn("printf '%s\\n' \"$subscriber_key\"", self.script)
        self.assertNotIn("printf '%s\\n' \"$subscriber_opc\"", self.script)

    def test_generator_enforces_permissions_and_refuses_overwrite(self):
        self.assertIn("install -d -m 0700", self.script)
        self.assertIn("install -m 0600", self.script)
        self.assertIn("chmod 0600", self.script)
        self.assertIn("refusing to replace existing", self.script)
        self.assertIn("-L $output_dir", self.script)
        self.assertIn("mode must be 700", self.script)
        self.assertIn("mode must be 600", self.script)

    def test_public_secret_files_do_not_embed_local_identity(self):
        for content in (self.script, self.ue_template, self.subscriber_template):
            self.assertNotIn("/home/", content)
            self.assertNotIn("fawaz", content.lower())


if __name__ == "__main__":
    unittest.main()
