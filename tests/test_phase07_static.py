#!/usr/bin/env python3
"""Static safety and experiment-contract tests for Phase 7."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts" / "cn5g"
OBS_CHART = ROOT / "charts" / "cn5g-observability"
OVERLAYS = [
    CHART / "values-phase05.yaml",
    CHART / "values-phase06.yaml",
    CHART / "values-phase07.yaml",
]
SCRIPT = ROOT / "scripts" / "phase07-lab.sh"
DOCKERFILE = ROOT / "containers" / "benchmark" / "Dockerfile"
VERSIONS = ROOT / "versions" / "phase-07.env"
EXPERIMENT = ROOT / "benchmarks" / "phase-07" / "experiment.json"
MATRIX_RUNNER = ROOT / "scripts" / "run-phase07-matrix.py"
REVIEWED_SUMMARY = ROOT / "benchmarks" / "phase-07" / "results" / "summary.json"
REVIEWED_METRICS = OBS_CHART / "files" / "phase07-reviewed.prom"
METRICS_GENERATOR = ROOT / "scripts" / "generate-phase07-dashboard-metrics.py"
PERFORMANCE_DASHBOARD = (
    OBS_CHART / "files" / "dashboards" / "05-performance-capacity.json"
)


def helm(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["helm", *arguments], cwd=ROOT, check=False, capture_output=True, text=True
    )


class Phase07StaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        values = [item for path in OVERLAYS for item in ("--values", str(path))]
        rendered = helm(
            "template", "cn5g", str(CHART), "--namespace", "cn5g",
            "--kube-version", "1.36.1", *values,
        )
        if rendered.returncode:
            raise AssertionError(rendered.stderr)
        observability = helm(
            "template", "cn5g-observability", str(OBS_CHART),
            "--namespace", "cn5g-observability", "--kube-version", "1.36.1",
        )
        if observability.returncode:
            raise AssertionError(observability.stderr)
        cls.rendered_text = rendered.stdout
        cls.objects = [item for item in yaml.safe_load_all(rendered.stdout) if item]
        cls.obs_rendered_text = observability.stdout
        cls.obs_objects = [
            item for item in yaml.safe_load_all(observability.stdout) if item
        ]
        cls.script = SCRIPT.read_text(encoding="utf-8")
        cls.dockerfile = DOCKERFILE.read_text(encoding="utf-8")
        cls.versions = VERSIONS.read_text(encoding="utf-8")
        cls.experiment = json.loads(EXPERIMENT.read_text(encoding="utf-8"))
        cls.matrix_runner = MATRIX_RUNNER.read_text(encoding="utf-8")
        cls.reviewed_summary = json.loads(REVIEWED_SUMMARY.read_text(encoding="utf-8"))
        cls.reviewed_metrics = REVIEWED_METRICS.read_text(encoding="utf-8")
        cls.performance_dashboard = json.loads(
            PERFORMANCE_DASHBOARD.read_text(encoding="utf-8")
        )

    def object_named(self, kind: str, name: str) -> dict:
        return next(
            item for item in self.objects
            if item["kind"] == kind and item["metadata"]["name"] == name
        )

    def obs_object_named(self, kind: str, name: str) -> dict:
        return next(
            item for item in self.obs_objects
            if item["kind"] == kind and item["metadata"]["name"] == name
        )

    def test_chart_lints_and_renders_deterministically(self):
        values = [item for path in OVERLAYS for item in ("--values", str(path))]
        lint = helm("lint", str(CHART), "--strict", *values)
        self.assertEqual(lint.returncode, 0, lint.stdout + lint.stderr)
        repeat = helm(
            "template", "cn5g", str(CHART), "--namespace", "cn5g",
            "--kube-version", "1.36.1", *values,
        )
        self.assertEqual(repeat.returncode, 0, repeat.stderr)
        self.assertEqual(repeat.stdout, self.rendered_text)

    def test_benchmark_image_source_and_packages_are_exactly_pinned(self):
        self.assertIn(
            "FROM alpine:3.22.1@sha256:eafc1edb577d2e9b458664a15f23ea1c370214193226069eb22921169fc7e43f",
            self.dockerfile,
        )
        for package in (
            "iperf3=3.19.1-r0", "iproute2=6.15.0-r0", "iputils=20240905-r0"
        ):
            self.assertIn(package, self.dockerfile)
            self.assertIn(package.split("=")[1], self.versions)
        self.assertNotIn(":latest", self.dockerfile + self.versions)
        self.assertIn("USER 65532:65532", self.dockerfile)
        self.assertIn("PHASE_07_IPERF_PORT_COUNT='5'", self.versions)

    def test_sidecars_share_the_real_namespaces_and_have_zero_capabilities(self):
        ue = self.object_named("StatefulSet", "cn5g-ue")
        containers = {
            item["name"]: item for item in ue["spec"]["template"]["spec"]["containers"]
        }
        self.assertEqual(
            set(containers), {"ue", "user-plane-metrics", "benchmark-client"}
        )
        client = containers["benchmark-client"]
        self.assertEqual(client["image"], "cn5g/benchmark:0.1.0")
        self.assertEqual(client["securityContext"]["capabilities"]["drop"], ["ALL"])
        self.assertFalse(client["securityContext"]["privileged"])
        self.assertFalse(client["securityContext"]["allowPrivilegeEscalation"])
        self.assertTrue(client["securityContext"]["readOnlyRootFilesystem"])
        self.assertIn("uesimtun0", json.dumps(client["readinessProbe"]))
        self.assertEqual(client["env"], [{"name": "TMPDIR", "value": "/tmp"}])
        self.assertEqual(client["volumeMounts"], [{"name": "benchmark-tmp", "mountPath": "/tmp"}])
        ue_volumes = {
            item["name"]: item for item in ue["spec"]["template"]["spec"]["volumes"]
        }
        self.assertEqual(
            ue_volumes["benchmark-tmp"]["emptyDir"],
            {"medium": "Memory", "sizeLimit": "16Mi"},
        )
        for component in ("data-internet", "data-enterprise"):
            workload = self.object_named("Deployment", f"cn5g-{component}")
            server = next(
                item for item in workload["spec"]["template"]["spec"]["containers"]
                if item["name"] == "benchmark-server"
            )
            self.assertEqual(server["securityContext"]["capabilities"]["drop"], ["ALL"])
            self.assertEqual(server["command"], ["/bin/sh", "-ec"])
            for port in range(5201, 5206):
                self.assertIn(f"iperf3 --server --port {port} &", server["args"][0])
            self.assertEqual(server["env"], [{"name": "TMPDIR", "value": "/tmp"}])
            self.assertEqual(server["volumeMounts"], [{"name": "benchmark-tmp", "mountPath": "/tmp"}])
            volumes = {
                item["name"]: item
                for item in workload["spec"]["template"]["spec"]["volumes"]
            }
            self.assertEqual(
                volumes["benchmark-tmp"]["emptyDir"],
                {"medium": "Memory", "sizeLimit": "16Mi"},
            )

    def test_only_controlled_dnn_services_expose_benchmark_protocols(self):
        for component in ("data-internet", "data-enterprise"):
            service = self.object_named("Service", f"cn5g-{component}")
            ports = {(item["name"], item["protocol"], item["port"]) for item in service["spec"]["ports"]}
            self.assertEqual(
                ports,
                {("http", "TCP", 8080)} |
                {(f"iperf-tcp-{ordinal}", "TCP", 5201 + ordinal) for ordinal in range(5)} |
                {(f"iperf-udp-{ordinal}", "UDP", 5201 + ordinal) for ordinal in range(5)},
            )

    def test_default_and_phase06_renders_do_not_gain_benchmark_containers(self):
        phase06 = helm(
            "template", "cn5g", str(CHART), "--namespace", "cn5g",
            "--kube-version", "1.36.1", "--values", str(OVERLAYS[0]),
            "--values", str(OVERLAYS[1]),
        )
        self.assertEqual(phase06.returncode, 0, phase06.stderr)
        self.assertNotIn("benchmark-client", phase06.stdout)
        self.assertNotIn("benchmark-server", phase06.stdout)
        self.assertNotIn("iperf-tcp", phase06.stdout)

    def test_experiment_has_three_levels_repetitions_and_fail_closed_path(self):
        data = self.experiment
        self.assertEqual(data["topology"]["ue_levels"], [1, 3, 5])
        self.assertEqual(data["controls"]["repetitions"], 3)
        self.assertGreater(data["controls"]["warm_up_seconds"], 0)
        self.assertGreaterEqual(data["controls"]["measurement_seconds"], 10)
        self.assertEqual(data["controls"]["restore_replicas_after_each_run"], 5)
        self.assertEqual(
            data["controls"]["session_state_reset"]["scope"],
            "before_each_condition",
        )
        self.assertEqual(
            data["controls"]["iperf_server_port_by_ordinal"],
            {str(ordinal): 5201 + ordinal for ordinal in range(5)},
        )
        self.assertEqual(data["traffic"]["tcp"]["forward_offered_rate"], "unbounded")
        self.assertEqual(
            data["traffic"]["tcp"]["reverse_offered_rate_per_ue_bits_per_second"],
            10_000_000,
        )
        self.assertEqual(
            data["pilot"]["measurement_seconds"],
            data["controls"]["measurement_seconds"],
        )
        self.assertFalse(data["abort_thresholds"]["route_bypass_allowed"])
        self.assertEqual(data["publication"]["raw_data"], "ignored")
        self.assertIn("production sizing", data["publication"]["prohibited_claims"])

    def test_lifecycle_has_identity_safety_abort_and_restoration_gates(self):
        for required in (
            "phase07_local_image=verified", "phase07_node_image=verified",
            "apk info -v 2>/dev/null", "grep -Fx 'iperf3-",
            "server_side_phase07_dry_run=pass", "phase07_benchmark_boundary=pass",
            "dev uesimtun0 table 1000", "from $ue_ip lookup 1000",
            "route bypasses the UE TUN",
            "host_available_memory_mib", "restart count changed during pilot",
            "wait_for_ue_replicas", ".status.readyReplicas // 0",
            "restore_five_ues", "pilot_restore_pending", "trap - EXIT",
            "phase05-lab.sh\" validate",
            "mongodb_pvc_identity", "phase07_rollback=pass",
            "benchmarks/raw/phase-07", "run-matrix", "run-phase07-matrix.py",
        ):
            self.assertIn(required, self.script)
        self.assertNotIn("docker system prune", self.script)
        self.assertNotIn("kubectl delete namespace", self.script)
        pilot = self.script[self.script.index("run_pilot()") :]
        self.assertLess(
            pilot.index('rollout restart "deployment/cn5g-$component"'),
            pilot.index('phase05-lab.sh" repair-sessions'),
        )

    def test_matrix_runner_is_resumable_concurrent_and_fail_closed(self):
        compile(self.matrix_runner, str(MATRIX_RUNNER), "exec")
        for required in (
            "ThreadPoolExecutor", "attempt-", "accepted.json", "experiment_sha256",
            "benchmark_image_id", "helm_revision", "scale_ues(0)",
            "restore_five", "finally:", "dev uesimtun0 table 1000",
            "from {ue_ip} lookup 1000", "container restart count changed",
            "OOMKilled", "prometheus_query_range", "idle_baseline_seconds",
            'for stage in ("tcp-forward", "tcp-reverse", "udp")',
            "successful_pilot_exists", "data.get(\"helm_revision\") == release_revision",
            "reset_condition_state", "repair-sessions", "preserved-abandoned",
            '"--reverse", "--bitrate", str(rate)',
        ):
            self.assertIn(required, self.matrix_runner)
        self.assertNotIn("docker system prune", self.matrix_runner)
        reset = self.matrix_runner[
            self.matrix_runner.index("def reset_condition_state") :
            self.matrix_runner.index("def endpoint_ip")
        ]
        self.assertLess(
            reset.index('deployment/cn5g-{component}'),
            reset.index('"repair-sessions"'),
        )

    def test_reviewed_dashboard_metrics_are_deterministic_bounded_and_sanitized(self):
        check = subprocess.run(
            [str(METRICS_GENERATOR), "--check"], cwd=ROOT, check=False,
            capture_output=True, text=True,
        )
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        samples = [
            line for line in self.reviewed_metrics.splitlines()
            if line.startswith("cn5g_phase07_reviewed_")
        ]
        self.assertEqual(len(samples), 556)
        self.assertLessEqual(len(samples), 600)
        self.assertIn(
            'cn5g_phase07_reviewed_campaign_info{campaign_id="20260806T223341Z-matrix",status="reviewed_complete"} 1',
            self.reviewed_metrics,
        )
        self.assertIn("cn5g_phase07_reviewed_accepted_conditions 9", self.reviewed_metrics)
        self.assertEqual(self.reviewed_summary["campaign"]["accepted_attempt_count"], 9)
        serialized = self.reviewed_metrics.lower()
        self.assertNotIn("imsi", serialized)
        self.assertNotIn("supi", serialized)
        self.assertNotIn("/home/", serialized)

    def test_reviewed_results_exporter_is_project_scoped_and_least_privileged(self):
        deployment = self.obs_object_named(
            "Deployment", "cn5g-observability-phase07-results"
        )
        pod_spec = deployment["spec"]["template"]["spec"]
        container = pod_spec["containers"][0]
        self.assertFalse(pod_spec["automountServiceAccountToken"])
        self.assertEqual(container["image"], "cn5g/data-network:0.1.0")
        self.assertEqual(container["securityContext"]["capabilities"]["drop"], ["ALL"])
        self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(container["resources"]["limits"]["memory"], "16Mi")
        self.assertEqual(
            pod_spec["volumes"][1]["emptyDir"],
            {"medium": "Memory", "sizeLimit": "2Mi"},
        )
        service = self.obs_object_named(
            "Service", "cn5g-observability-phase07-results"
        )
        self.assertEqual(service["spec"]["ports"], [{
            "name": "metrics", "port": 8080, "targetPort": "metrics",
            "protocol": "TCP",
        }])
        scrape = self.obs_object_named(
            "ConfigMap", "cn5g-observability-prometheus-config"
        )["data"]["prometheus.yml"]
        self.assertIn("job_name: phase07-reviewed-results", scrape)
        self.assertIn("cn5g-observability-phase07-results:8080", scrape)

    def test_performance_dashboard_explains_reviewed_evidence_and_limitations(self):
        dashboard = self.performance_dashboard
        self.assertEqual(dashboard["uid"], "cn5g-performance")
        self.assertEqual(dashboard["title"], "CN5G Performance And Capacity Experiments")
        self.assertEqual(set(dashboard["tags"]), {
            "cn5g", "phase-07", "performance", "reviewed-evidence",
        })
        self.assertFalse(dashboard["editable"])
        self.assertEqual(len(dashboard["links"]), 5)
        self.assertEqual(
            {item["url"] for item in dashboard["links"]},
            {
                "/d/cn5g-platform", "/d/cn5g-5g-service",
                "/d/cn5g-kubernetes", "/d/cn5g-logs", "/d/cn5g-performance",
            },
        )
        self.assertEqual(dashboard["templating"]["list"][0]["name"], "ue_level")
        self.assertEqual(dashboard["templating"]["list"][0]["query"], "1,3,5")
        titles = {panel["title"] for panel in dashboard["panels"]}
        for required in (
            "Campaign state", "Accepted conditions", "Traffic scaling",
            "Forward TCP aggregate median", "Forward TCP fairness",
            "Reverse TCP target delivered", "Registration success",
            "PDU-session latency by UE level", "Median component CPU peak",
            "Median component memory peak", "Scope and publication limits",
        ):
            self.assertIn(required, titles)
        serialized = json.dumps(dashboard)
        self.assertIn("benchmarks/phase-07/experiment.json", serialized)
        self.assertIn("reports/07_phase07_performance.md", serialized)
        self.assertIn("reviewed phase 7 local-lab results", serialized.lower())
        self.assertIn("not a live speed test", serialized.lower())
        self.assertNotIn("/home/", serialized)
        self.assertNotIn("imsi", serialized.lower())
        expressions = "\n".join(
            target["expr"]
            for panel in dashboard["panels"]
            for target in panel.get("targets", [])
            if "expr" in target
        )
        self.assertIn("cn5g_phase07_reviewed_throughput_bits_per_second", expressions)
        self.assertIn("cn5g_phase07_reviewed_component_cpu_peak_cores", expressions)
        self.assertNotIn("rate(", expressions)


if __name__ == "__main__":
    unittest.main()
