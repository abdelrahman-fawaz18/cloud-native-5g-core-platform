#!/usr/bin/env python3
"""Unit tests for deterministic resilience campaign analysis helpers."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ANALYZER = ROOT / "scripts" / "analyze-resilience.py"


def load_analyzer():
    spec = importlib.util.spec_from_file_location("resilience_analysis", ANALYZER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class ResilienceCampaignAnalysisTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_analyzer()

    def test_distribution_is_deterministic(self):
        self.assertEqual(self.module.percentile([1, 2, 3], 95), 3)
        result = self.module.distribution([1, 2, 3])
        self.assertEqual(result["minimum"], 1)
        self.assertEqual(result["median"], 2)
        self.assertEqual(result["mean"], 2)
        self.assertEqual(result["p95_nearest_rank"], 3)
        self.assertEqual(result["sample_standard_deviation"], 1)

    def test_user_plane_disruption_detects_failure_and_recovery(self):
        def sample(epoch, value):
            return {
                "epoch": epoch,
                "prometheus": {
                    "user_plane_paths": {
                        "present": True, "value": value,
                    }
                },
            }

        observed, duration = self.module.user_plane_disruption(
            [sample(10, 5), sample(12, 3), sample(14, 0), sample(18, 5)], 11
        )
        self.assertTrue(observed)
        self.assertEqual(duration, 6)
        self.assertEqual(
            self.module.user_plane_disruption([sample(10, 5), sample(12, 5)], 11),
            (False, 0.0),
        )

    def test_unrecovered_user_plane_failure_is_rejected(self):
        timeline = [{
            "epoch": 12,
            "prometheus": {
                "user_plane_paths": {"present": True, "value": 0}
            },
        }]
        with self.assertRaises(self.module.AnalysisError):
            self.module.user_plane_disruption(timeline, 11)

    def test_svg_outputs_are_accessible_and_self_describing(self):
        metric = {
            "minimum": 1.0, "median": 2.0, "mean": 2.0,
            "p95_nearest_rank": 3.0, "maximum": 3.0,
            "sample_standard_deviation": 1.0,
        }
        summary = {
            component: {
                "mttd_seconds": metric,
                "replacement_ready_seconds": metric,
                "mttr_seconds": metric,
                "user_plane_disruption_seconds": metric,
            }
            for component in self.module.COMPONENTS
        }
        rows = [
            {"component": component, "service_recovery_mode": "automatic"}
            for component in self.module.COMPONENTS
        ]
        for svg in (
            self.module.svg_grouped(summary),
            self.module.svg_modes(rows),
            self.module.svg_disruption(summary),
        ):
            self.assertIn("<svg", svg)
            self.assertIn("<title>", svg)
            self.assertNotIn("/home/", svg)


if __name__ == "__main__":
    unittest.main()
