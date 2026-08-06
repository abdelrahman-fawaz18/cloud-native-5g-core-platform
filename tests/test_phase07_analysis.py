import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ANALYZER = ROOT / "scripts" / "analyze-phase07.py"
RESULTS = ROOT / "benchmarks" / "phase-07" / "results"
REPORT = ROOT / "reports" / "07_phase07_performance.md"


def load_analyzer():
    spec = importlib.util.spec_from_file_location("phase07_analysis", ANALYZER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class Phase07AnalysisTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_analyzer()
        cls.summary = json.loads((RESULTS / "summary.json").read_text(encoding="utf-8"))

    def test_statistical_helpers_are_deterministic(self):
        self.assertEqual(self.module.percentile([1, 2, 3], 95), 3)
        result = self.module.distribution([1, 2, 3])
        self.assertEqual(result["median"], 2)
        self.assertEqual(result["sample_standard_deviation"], 1)
        self.assertAlmostEqual(self.module.jain([10, 10, 10]), 1.0)

    def test_protocol_parsers_reject_incomplete_or_negative_evidence(self):
        log = "\n".join([
            "[2026-08-06 12:00:00.000] Sending Initial Registration",
            "[2026-08-06 12:00:00.050] Initial Registration is successful",
            "[2026-08-06 12:00:00.060] Sending PDU Session Establishment Request",
            "[2026-08-06 12:00:00.160] PDU Session establishment is successful",
        ])
        self.assertEqual(self.module.procedure_latencies(log), (50.0, 100.0))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ping.txt"
            path.write_text(
                "10 packets transmitted, 10 received, 0% packet loss\n"
                "rtt min/avg/max/mdev = 1.000/2.000/3.000/0.500 ms\n",
                encoding="utf-8",
            )
            self.assertEqual(self.module.parse_ping(path), (0.0, 2.0, 3.0))

    def test_reviewed_summary_contains_exact_accepted_matrix(self):
        campaign = self.summary["campaign"]
        self.assertEqual(campaign["status"], "reviewed_complete")
        self.assertEqual(campaign["accepted_attempt_count"], 9)
        self.assertEqual(set(self.summary["per_level"]), {"1", "3", "5"})
        for level in ("1", "3", "5"):
            result = self.summary["per_level"][level]
            self.assertEqual(result["repetitions"], 3)
            self.assertEqual(result["registration_success_rate_percent"], 100.0)
            self.assertEqual(result["pdu_session_success_rate_percent"], 100.0)
            self.assertEqual(result["new_restarts"], 0)

    def test_reviewed_outputs_are_complete_and_sanitized(self):
        expected_rows = {"per-ue.csv": 27, "condition-summary.csv": 9}
        for name, count in expected_rows.items():
            with (RESULTS / name).open(encoding="utf-8", newline="") as handle:
                self.assertEqual(len(list(csv.DictReader(handle))), count)
        for name in ("throughput.svg", "procedures.svg", "resources.svg"):
            text = (RESULTS / "plots" / name).read_text(encoding="utf-8")
            self.assertIn("<svg", text)
            self.assertIn("<title>", text)
        public_text = REPORT.read_text(encoding="utf-8") + json.dumps(self.summary)
        self.assertNotIn("/home/", public_text)
        self.assertNotIn("fawaz", public_text.lower())
        self.assertIn("not production sizing", public_text)


if __name__ == "__main__":
    unittest.main()
