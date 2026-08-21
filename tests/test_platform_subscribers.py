#!/usr/bin/env python3
"""Behavioral tests for deterministic platform subscriber generation."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "generate-subscribers.py"
PLAN = ROOT / "configs" / "kubernetes" / "platform" / "subscriber-plan.json"


def load_generator():
    spec = importlib.util.spec_from_file_location("platform_generator", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GENERATOR = load_generator()


class MultiUePlatformSubscriberTests(unittest.TestCase):
    def run_generator(self, output: Path, action: str = "--generate", plan: Path = PLAN):
        return subprocess.run(
            ["python3", str(SCRIPT), action, "--plan", str(plan), "--output", str(output)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_public_plan_passes_and_contains_exact_identity_contract(self):
        plan = GENERATOR.load_plan(PLAN)
        self.assertEqual(len(plan["subscribers"]), 5)
        self.assertEqual([sub["ordinal"] for sub in plan["subscribers"]], list(range(5)))
        self.assertEqual(len({sub["imsi"] for sub in plan["subscribers"]}), 5)
        self.assertEqual({sub["dnn"] for sub in plan["subscribers"]}, {"internet", "enterprise"})
        self.assertEqual({dnn["pool"] for dnn in plan["dnns"]}, {"10.60.0.0/24", "10.61.0.0/24"})

    def test_generation_is_byte_deterministic_and_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "platform"
            first = self.run_generator(output)
            self.assertEqual(first.returncode, 0, first.stderr)
            first_content = {path.name: path.read_bytes() for path in output.iterdir()}
            second = self.run_generator(output)
            self.assertEqual(second.returncode, 0, second.stderr)
            second_content = {path.name: path.read_bytes() for path in output.iterdir()}
            self.assertEqual(first_content, second_content)
            checked = self.run_generator(output, "--check")
            self.assertEqual(checked.returncode, 0, checked.stderr)
            self.assertIn("platform_subscriber_material_validation=pass", checked.stdout)

    def test_generated_material_is_permission_restricted_and_consistent(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "platform"
            result = self.run_generator(output)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o700)
            self.assertTrue(all((os.stat(path).st_mode & 0o777) == 0o600 for path in output.iterdir()))
            javascript = (output / "subscriber-init.js").read_text(encoding="utf-8")
            for ordinal in range(5):
                imsi = (output / f"imsi-{ordinal}").read_text(encoding="ascii").strip()
                dnn = (output / f"dnn-{ordinal}").read_text(encoding="ascii").strip()
                ue = (output / f"ue-{ordinal}.yaml").read_text(encoding="utf-8")
                self.assertIn(f"supi: 'imsi-{imsi}'", ue)
                self.assertIn(f"apn: '{dnn}'", ue)
                self.assertIn(f"imsi: '{imsi}'", javascript)
            self.assertNotIn("derivation-seed", javascript)
            self.assertNotIn("subscriber_key", result.stdout)

    def test_duplicate_identity_is_rejected_before_generation(self):
        plan = json.loads(PLAN.read_text(encoding="utf-8"))
        plan["subscribers"][4]["imsi"] = plan["subscribers"][0]["imsi"]
        with tempfile.TemporaryDirectory() as temporary:
            bad_plan = Path(temporary) / "duplicate.json"
            bad_plan.write_text(json.dumps(plan), encoding="utf-8")
            result = self.run_generator(Path(temporary) / "output", plan=bad_plan)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("duplicate subscriber identity", result.stderr)
            self.assertFalse((Path(temporary) / "output").exists())

    def test_unsupported_dnn_is_rejected_before_generation(self):
        plan = json.loads(PLAN.read_text(encoding="utf-8"))
        plan["subscribers"][0]["dnn"] = "unmanaged"
        with tempfile.TemporaryDirectory() as temporary:
            bad_plan = Path(temporary) / "unsupported.json"
            bad_plan.write_text(json.dumps(plan), encoding="utf-8")
            result = self.run_generator(Path(temporary) / "output", plan=bad_plan)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsupported subscriber DNN", result.stderr)
            self.assertFalse((Path(temporary) / "output").exists())

    def test_unsupported_slice_is_rejected_before_generation(self):
        plan = json.loads(PLAN.read_text(encoding="utf-8"))
        plan["slice"] = {"sst": 2}
        with tempfile.TemporaryDirectory() as temporary:
            bad_plan = Path(temporary) / "unsupported-slice.json"
            bad_plan.write_text(json.dumps(plan), encoding="utf-8")
            result = self.run_generator(Path(temporary) / "output", plan=bad_plan)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("accepted SST 1 slice", result.stderr)
            self.assertFalse((Path(temporary) / "output").exists())

    def test_tampering_and_extra_files_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "platform"
            self.assertEqual(self.run_generator(output).returncode, 0)
            (output / "ue-0.yaml").write_text("tampered\n", encoding="utf-8")
            tampered = self.run_generator(output, "--check")
            self.assertNotEqual(tampered.returncode, 0)
            self.assertIn("differs from deterministic contract", tampered.stderr)
            self.assertEqual(self.run_generator(output).returncode, 0)
            extra = output / "unexpected"
            extra.write_text("x\n", encoding="utf-8")
            os.chmod(extra, 0o600)
            checked = self.run_generator(output, "--check")
            self.assertNotEqual(checked.returncode, 0)
            self.assertIn("missing or unexpected files", checked.stderr)

    def test_public_files_contain_no_authentication_material_or_local_identity(self):
        public = SCRIPT.read_text(encoding="utf-8") + PLAN.read_text(encoding="utf-8")
        self.assertNotIn("/home/", public)
        self.assertNotIn("fawaz", public.lower())
        self.assertNotRegex(public, r"key: '[0-9A-F]{32}'")
        self.assertNotRegex(public, r"opc: '[0-9A-F]{32}'")


if __name__ == "__main__":
    unittest.main()
