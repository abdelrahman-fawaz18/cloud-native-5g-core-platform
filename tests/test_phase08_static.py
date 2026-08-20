#!/usr/bin/env python3
"""Static safety and experiment-contract tests for Phase 8."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts" / "cn5g"
OBS_CHART = ROOT / "charts" / "cn5g-observability"
OVERLAYS = [CHART / "values-phase05.yaml", CHART / "values-phase06.yaml"]
EXPERIMENT = ROOT / "benchmarks" / "phase-08" / "experiment.json"
LIFECYCLE = ROOT / "scripts" / "phase08-lab.sh"
RUNNER = ROOT / "scripts" / "run-phase08-recovery.py"
ANALYZER = ROOT / "scripts" / "analyze-phase08.py"
ADR = ROOT / "docs" / "adr" / "0011-phase-08-fault-model.md"
METHODOLOGY = ROOT / "docs" / "architecture" / "phase-08-reliability-methodology.md"
RUNBOOK = ROOT / "docs" / "runbooks" / "phase-08-recovery.md"
REVIEWED_SUMMARY = ROOT / "benchmarks" / "phase-08" / "results" / "summary.json"
REVIEWED_METRICS = OBS_CHART / "files" / "phase08-reviewed.prom"
METRICS_GENERATOR = ROOT / "scripts" / "generate-phase08-dashboard-metrics.py"
RELIABILITY_DASHBOARD = (
    OBS_CHART / "files" / "dashboards" / "06-reliability-recovery.json"
)


def helm(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["helm", *arguments], cwd=ROOT, check=False, capture_output=True, text=True
    )


class Phase08StaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        values = [item for path in OVERLAYS for item in ("--values", str(path))]
        rendered = helm(
            "template", "cn5g", str(CHART), "--namespace", "cn5g",
            "--kube-version", "1.36.1", *values,
        )
        if rendered.returncode:
            raise AssertionError(rendered.stderr)
        cls.rendered_text = rendered.stdout
        cls.objects = [item for item in yaml.safe_load_all(rendered.stdout) if item]
        observability = helm(
            "template", "cn5g-observability", str(OBS_CHART),
            "--namespace", "cn5g-observability", "--kube-version", "1.36.1",
        )
        if observability.returncode:
            raise AssertionError(observability.stderr)
        cls.obs_objects = [
            item for item in yaml.safe_load_all(observability.stdout) if item
        ]
        cls.experiment = json.loads(EXPERIMENT.read_text(encoding="utf-8"))
        cls.lifecycle = LIFECYCLE.read_text(encoding="utf-8")
        cls.runner = RUNNER.read_text(encoding="utf-8")
        cls.analyzer = ANALYZER.read_text(encoding="utf-8")
        cls.reviewed_summary = json.loads(REVIEWED_SUMMARY.read_text(encoding="utf-8"))
        cls.reviewed_metrics = REVIEWED_METRICS.read_text(encoding="utf-8")
        cls.reliability_dashboard = json.loads(
            RELIABILITY_DASHBOARD.read_text(encoding="utf-8")
        )

    def deployment(self, name: str) -> dict:
        return next(
            item for item in self.objects
            if item["kind"] == "Deployment" and item["metadata"]["name"] == name
        )

    def obs_object_named(self, kind: str, name: str) -> dict:
        return next(
            item for item in self.obs_objects
            if item["kind"] == kind and item["metadata"]["name"] == name
        )

    def test_accepted_baseline_lints_and_renders_deterministically(self):
        values = [item for path in OVERLAYS for item in ("--values", str(path))]
        lint = helm("lint", str(CHART), "--strict", *values)
        self.assertEqual(lint.returncode, 0, lint.stdout + lint.stderr)
        repeat = helm(
            "template", "cn5g", str(CHART), "--namespace", "cn5g",
            "--kube-version", "1.36.1", *values,
        )
        self.assertEqual(repeat.returncode, 0, repeat.stderr)
        self.assertEqual(repeat.stdout, self.rendered_text)

    def test_fault_targets_are_single_replica_deployments_with_probes(self):
        for component in ("amf", "smf", "upf"):
            deployment = self.deployment(f"cn5g-{component}")
            self.assertEqual(deployment["spec"]["replicas"], 1)
            self.assertEqual(deployment["spec"]["strategy"]["type"], "Recreate")
            container = deployment["spec"]["template"]["spec"]["containers"][0]
            self.assertIn("startupProbe", container)
            self.assertIn("readinessProbe", container)
            self.assertIn("livenessProbe", container)
            self.assertFalse(container["securityContext"]["privileged"])

    def test_experiment_contract_has_exact_fault_and_timing_scope(self):
        data = self.experiment
        self.assertEqual(data["schema_version"], 1)
        self.assertEqual(set(data["faults"]), {"amf", "smf", "upf"})
        self.assertEqual(data["controls"]["run_order"], ["amf", "smf", "upf"])
        self.assertEqual(data["controls"]["repetitions"], 3)
        self.assertTrue(data["controls"]["pilot_required_per_component"])
        self.assertTrue(data["controls"]["one_intended_fault_per_attempt"])
        self.assertGreaterEqual(
            data["controls"]["automatic_recovery_observation_seconds"], 60
        )
        self.assertEqual(data["topology"]["replicas_per_faulted_component"], 1)
        self.assertFalse(
            data["abort_thresholds"]["mongodb_pvc_identity_change_allowed"]
        )
        self.assertIn("high availability", data["publication"]["prohibited_claims"])
        self.assertIn("Pod readiness alone is never MTTR", data["timing"]["mttr"])
        self.assertIn("timestamp(metric)", data["evidence"]["freshness_rule"])
        for component, fault in data["faults"].items():
            self.assertEqual(fault["workload_name"], f"cn5g-{component}")
            self.assertEqual(fault["prometheus_job"], f"open5gs-{component}")
            self.assertIn("replacement_ready", fault["service_recovery_signals"])
            self.assertIn("user_plane_paths_five", fault["service_recovery_signals"])

    def test_lifecycle_is_scoped_resumable_and_fail_closed(self):
        for required in (
            "phase08_preflight=pass", "phase08_fault_targets=pass",
            "phase08-lab.sh pilot amf", "--mode \"$mode\"",
            "test-mongodb", "test-invalid-config", "dry-run=server",
            "phase05-lab.sh\" repair-sessions", "phase05-lab.sh\" validate",
            "phase06-lab.sh\" validate", "phase08_recovery=pass",
            "mongodb-data-cn5g-mongodb-0", "release_revision_unchanged",
            "benchmarks/raw/phase-08",
        ):
            self.assertIn(required, self.lifecycle)
        forbidden = (
            "docker system prune", "kubectl delete namespace", "delete deployment",
            "delete statefulset", "delete pvc", "kind delete cluster",
        )
        for item in forbidden:
            self.assertNotIn(item, self.lifecycle.lower())

    def test_runner_preserves_fault_identity_and_restores_after_interruption(self):
        compile(self.runner, str(RUNNER), "exec")
        for required in (
            '"delete", "pod", before["pod_name"], "--wait=false"',
            "old_pod_present", "replacement_ready_time", "service_recovered",
            "automatic_service_recovery_time", "operator-assisted",
            "phase08_emergency_restoration=started", "emergency_restore",
            "finally:", "accepted.json", "attempt-", "raw_complete",
            "successful_pilot_exists", "experiment_sha256", "helm_revision",
            "mongodb_pvc_before", "mongodb_pvc_after", "loki_range",
            "prometheus_range", "baseline_restored",
            "source_timestamp_query", "timestamp(metric)",
            "min(timestamp(cn5g_ue_user_plane_probe_success))",
            'pfcp_peers_active{job=\"open5gs-smf\"}',
            'pfcp_peers_active{job=\"open5gs-upf\"}',
        ):
            self.assertIn(required, self.runner)
        self.assertNotIn("--force", self.runner)
        self.assertNotIn("--grace-period=0", self.runner)
        self.assertNotIn("delete\", \"deployment", self.runner)
        self.assertNotIn("delete\", \"statefulset", self.runner)
        self.assertNotIn("delete\", \"pvc", self.runner)

    def test_analysis_requires_exact_reviewed_campaign_and_is_sanitized(self):
        compile(self.analyzer, str(ANALYZER), "exec")
        for required in (
            "raw_complete", "exact nine accepted conditions", "accepted.json",
            "experiment_sha256", "MongoDB PVC identity changed",
            "user-plane failure has no later recovered observation",
            "reviewed_complete", "attempt-summary.csv", "component-summary.csv",
            "recovery-times.svg", "recovery-modes.svg",
            "user-plane-disruption.svg", "08_phase08_reliability.md",
        ):
            self.assertIn(required, self.analyzer)
        self.assertNotIn("/home/", self.analyzer)
        self.assertNotIn("fawaz", self.analyzer.lower())

    def test_public_methodology_and_runbook_explain_the_real_boundary(self):
        public = "\n".join(
            path.read_text(encoding="utf-8") for path in (ADR, METHODOLOGY, RUNBOOK)
        )
        for required in (
            "single-replica recovery", "Pod readiness", "operator-assisted",
            "MTTD", "MTTR", "PersistentVolumeClaim", "Phase 5",
            "Phase 6", "not high availability",
        ):
            self.assertIn(required.lower(), public.lower())
        self.assertNotIn("/home/", public)
        self.assertNotIn("fawaz", public.lower())

    def test_reviewed_dashboard_metrics_are_deterministic_bounded_and_sanitized(self):
        check = subprocess.run(
            [str(METRICS_GENERATOR), "--check"], cwd=ROOT, check=False,
            capture_output=True, text=True,
        )
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        samples = [
            line for line in self.reviewed_metrics.splitlines()
            if line.startswith("cn5g_phase08_reviewed_")
        ]
        self.assertEqual(len(samples), 75)
        self.assertLessEqual(len(samples), 100)
        self.assertIn(
            'cn5g_phase08_reviewed_campaign_info{campaign_id="20260807T050635Z-matrix",status="reviewed_complete"} 1',
            self.reviewed_metrics,
        )
        self.assertIn("cn5g_phase08_reviewed_accepted_conditions 9", self.reviewed_metrics)
        self.assertEqual(self.reviewed_summary["campaign"]["accepted_attempt_count"], 9)
        serialized = self.reviewed_metrics.lower()
        for forbidden in ("imsi", "supi", "/home/", "pod_name", "pvc_uid"):
            self.assertNotIn(forbidden, serialized)

    def test_reviewed_results_exporter_is_scoped_and_least_privileged(self):
        deployment = self.obs_object_named(
            "Deployment", "cn5g-observability-phase08-results"
        )
        pod_spec = deployment["spec"]["template"]["spec"]
        container = pod_spec["containers"][0]
        self.assertFalse(pod_spec["automountServiceAccountToken"])
        self.assertEqual(container["image"], "cn5g/data-network:0.1.0")
        self.assertEqual(container["securityContext"]["capabilities"]["drop"], ["ALL"])
        self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(container["resources"]["limits"]["memory"], "16Mi")
        service = self.obs_object_named(
            "Service", "cn5g-observability-phase08-results"
        )
        self.assertEqual(service["spec"]["ports"], [{
            "name": "metrics", "port": 8080, "targetPort": "metrics",
            "protocol": "TCP",
        }])
        scrape = self.obs_object_named(
            "ConfigMap", "cn5g-observability-prometheus-config"
        )["data"]["prometheus.yml"]
        self.assertIn("job_name: phase08-reviewed-results", scrape)
        self.assertIn("cn5g-observability-phase08-results:8080", scrape)

    def test_reliability_dashboard_separates_infrastructure_and_service_recovery(self):
        dashboard = self.reliability_dashboard
        self.assertEqual(dashboard["uid"], "cn5g-reliability")
        self.assertEqual(dashboard["title"], "CN5G Reliability And Recovery")
        self.assertEqual(set(dashboard["tags"]), {
            "cn5g", "phase-08", "reliability", "reviewed-evidence",
        })
        self.assertFalse(dashboard["editable"])
        self.assertEqual(dashboard["templating"]["list"][0]["name"], "component")
        self.assertEqual(dashboard["templating"]["list"][0]["query"], "amf,smf,upf")
        titles = {panel["title"] for panel in dashboard["panels"]}
        for required in (
            "Campaign state", "Automatic recoveries", "Assisted recoveries",
            "Median MTTD", "Median replacement Pod Ready", "Median MTTR",
            "Median service-restoration gap", "Median observed user-plane disruption",
            "Selected MTTR distribution", "Scope and publication limits",
        ):
            self.assertIn(required, titles)
        serialized = json.dumps(dashboard)
        self.assertIn("benchmarks/phase-08/experiment.json", serialized)
        self.assertIn("reports/08_phase08_reliability.md", serialized)
        self.assertIn("pod ready", serialized.lower())
        self.assertIn("not service recovery", serialized.lower())
        self.assertNotIn("/home/", serialized)
        self.assertNotIn("imsi", serialized.lower())
        expressions = "\n".join(
            target["expr"]
            for panel in dashboard["panels"]
            for target in panel.get("targets", [])
            if "expr" in target
        )
        self.assertIn("boundary=\"detection\"", expressions)
        self.assertIn("boundary=\"pod_ready\"", expressions)
        self.assertIn("boundary=\"service_recovery\"", expressions)
        self.assertIn("boundary=\"user_plane_disruption\"", expressions)


if __name__ == "__main__":
    unittest.main()
