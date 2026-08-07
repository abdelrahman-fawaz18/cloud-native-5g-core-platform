#!/usr/bin/env python3
"""Static architecture, security, and lifecycle tests for Phase 6."""

from __future__ import annotations

from pathlib import Path
import json
import re
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
CORE_CHART = ROOT / "charts" / "cn5g"
OBS_CHART = ROOT / "charts" / "cn5g-observability"
PHASE05 = CORE_CHART / "values-phase05.yaml"
PHASE06 = CORE_CHART / "values-phase06.yaml"
LIFECYCLE = ROOT / "scripts" / "phase06-lab.sh"
VERSIONS = ROOT / "versions" / "phase-06.env"


def helm(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["helm", *arguments], cwd=ROOT, check=False, capture_output=True, text=True
    )


class Phase06StaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        core = helm(
            "template", "cn5g", str(CORE_CHART), "--namespace", "cn5g",
            "--kube-version", "1.36.1", "--values", str(PHASE05),
            "--values", str(PHASE06),
        )
        observability = helm(
            "template", "cn5g-observability", str(OBS_CHART),
            "--namespace", "cn5g-observability", "--kube-version", "1.36.1",
        )
        if core.returncode != 0:
            raise AssertionError(core.stderr)
        if observability.returncode != 0:
            raise AssertionError(observability.stderr)
        cls.core_rendered = core.stdout
        cls.obs_rendered = observability.stdout
        cls.core = [item for item in yaml.safe_load_all(core.stdout) if item]
        cls.obs = [item for item in yaml.safe_load_all(observability.stdout) if item]
        cls.lifecycle = LIFECYCLE.read_text(encoding="utf-8")
        cls.versions = VERSIONS.read_text(encoding="utf-8")

    def object_named(self, objects: list[dict], kind: str, name: str) -> dict:
        return next(
            item for item in objects
            if item["kind"] == kind and item["metadata"]["name"] == name
        )

    def test_both_charts_lint_strictly_and_render_deterministically(self):
        core_lint = helm(
            "lint", str(CORE_CHART), "--strict", "--values", str(PHASE05),
            "--values", str(PHASE06),
        )
        obs_lint = helm("lint", str(OBS_CHART), "--strict")
        self.assertEqual(core_lint.returncode, 0, core_lint.stdout + core_lint.stderr)
        self.assertEqual(obs_lint.returncode, 0, obs_lint.stdout + obs_lint.stderr)
        repeat = helm(
            "template", "cn5g-observability", str(OBS_CHART),
            "--namespace", "cn5g-observability", "--kube-version", "1.36.1",
        )
        self.assertEqual(repeat.returncode, 0, repeat.stderr)
        self.assertEqual(self.obs_rendered, repeat.stdout)

    def test_all_external_images_are_version_and_digest_pinned(self):
        values = yaml.safe_load((OBS_CHART / "values.yaml").read_text(encoding="utf-8"))
        for name, image in values["images"].items():
            self.assertNotEqual(image["tag"], "latest", name)
            if name != "alertExercise":
                self.assertRegex(image["digest"], r"^sha256:[0-9a-f]{64}$")
                self.assertIn(f"{image['repository']}:{image['tag']}@{image['digest']}", self.obs_rendered)
        self.assertEqual(self.versions.count("_IMAGE_DIGEST='sha256:"), 6)

    def test_ue_probe_is_bounded_least_privileged_and_secret_free(self):
        ue = self.object_named(self.core, "StatefulSet", "cn5g-ue")
        containers = {
            item["name"]: item for item in ue["spec"]["template"]["spec"]["containers"]
        }
        self.assertEqual(set(containers), {"ue", "user-plane-metrics"})
        probe = containers["user-plane-metrics"]
        self.assertEqual(probe["ports"][0]["containerPort"], 9101)
        self.assertEqual(probe["securityContext"]["capabilities"]["drop"], ["ALL"])
        self.assertFalse(probe["securityContext"]["allowPrivilegeEscalation"])
        self.assertFalse(probe["securityContext"]["privileged"])
        self.assertEqual(probe["securityContext"]["runAsUser"], 65532)
        config = self.object_named(self.core, "ConfigMap", "cn5g-ue-probe")["data"]["probe.py"]
        compile(config, "probe.py", "exec")
        self.assertIn('ORDINAL in (0, 1, 2)', config)
        self.assertIn('ORDINAL in (3, 4)', config)
        self.assertIn('source_address=(source, 0)', config)
        self.assertNotIn("imsi", config.lower())
        self.assertNotRegex(config, r"10\.(60|61)\.0\.[0-9]+")
        self.assertIn('ordinal="{ORDINAL}",dnn="{DNN}"', config)

    def test_stack_is_separate_bounded_and_persistent_where_required(self):
        kinds = [item["kind"] for item in self.obs]
        self.assertEqual(kinds.count("StatefulSet"), 2)
        self.assertEqual(kinds.count("Deployment"), 5)
        self.assertEqual(kinds.count("PersistentVolumeClaim"), 0)
        for component in ("prometheus", "loki"):
            workload = self.object_named(
                self.obs, "StatefulSet", f"cn5g-observability-{component}"
            )
            claim = workload["spec"]["volumeClaimTemplates"][0]
            self.assertEqual(claim["spec"]["resources"]["requests"]["storage"], "2Gi")
            self.assertEqual(
                claim["metadata"]["labels"]["helm.sh/chart"],
                "cn5g-observability-0.1.0",
            )
            self.assertEqual(
                workload["metadata"]["labels"]["helm.sh/chart"],
                "cn5g-observability-0.2.0",
            )
        prometheus = self.object_named(
            self.obs, "StatefulSet", "cn5g-observability-prometheus"
        )["spec"]["template"]["spec"]["containers"][0]
        self.assertIn("--storage.tsdb.retention.time=24h", prometheus["args"])
        self.assertIn("--storage.tsdb.retention.size=1GB", prometheus["args"])

    def test_kube_state_metrics_uses_versioned_health_endpoint_contract(self):
        deployment = self.object_named(
            self.obs, "Deployment", "cn5g-observability-kube-state-metrics"
        )
        container = deployment["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(
            container["startupProbe"]["httpGet"],
            {"path": "/healthz", "port": "metrics"},
        )
        self.assertEqual(
            container["readinessProbe"]["httpGet"],
            {"path": "/readyz", "port": "telemetry"},
        )
        self.assertEqual(
            container["livenessProbe"]["httpGet"],
            {"path": "/livez", "port": "metrics"},
        )

    def test_security_boundary_has_no_privileged_or_host_mounted_workloads(self):
        for obj in self.obs:
            if obj["kind"] not in ("Deployment", "StatefulSet"):
                continue
            spec = obj["spec"]["template"]["spec"]
            for volume in spec.get("volumes", []):
                self.assertNotIn("hostPath", volume, obj["metadata"]["name"])
            for container in spec.get("containers", []):
                security = container.get("securityContext", {})
                self.assertFalse(security.get("privileged", False))
                self.assertFalse(security.get("allowPrivilegeEscalation", True))
                self.assertEqual(security.get("capabilities", {}).get("drop"), ["ALL"])
        tokens = {
            obj["metadata"]["name"]: obj["spec"]["template"]["spec"].get(
                "automountServiceAccountToken"
            )
            for obj in self.obs if obj["kind"] in ("Deployment", "StatefulSet")
        }
        self.assertTrue(tokens["cn5g-observability-prometheus"])
        self.assertTrue(tokens["cn5g-observability-kube-state-metrics"])
        self.assertTrue(tokens["cn5g-observability-alloy"])
        self.assertFalse(tokens["cn5g-observability-grafana"])
        self.assertFalse(tokens["cn5g-observability-loki"])
        self.assertFalse(tokens["cn5g-observability-phase07-results"])

    def test_prometheus_covers_platform_telecom_and_bounded_probe_metrics(self):
        config = self.object_named(
            self.obs, "ConfigMap", "cn5g-observability-prometheus-config"
        )["data"]
        scrape = config["prometheus.yml"]
        for job in (
            "open5gs-amf", "open5gs-pcf", "open5gs-smf", "open5gs-upf",
            "cn5g-ue-user-plane", "kube-state-metrics", "kubernetes-node",
            "kubernetes-cadvisor", "alert-exercise", "phase07-reviewed-results",
        ):
            self.assertIn(f"job_name: {job}", scrape)
        self.assertIn("fallback_scrape_protocol: PrometheusText0.0.4", scrape)
        alerts = yaml.safe_load(config["alerts.yaml"])
        rules = alerts["groups"][0]["rules"]
        names = {rule["alert"] for rule in rules}
        self.assertGreaterEqual(len(names), 4)
        for expected in (
            "Cn5gPrometheusTargetDown", "Cn5gWorkloadUnavailable",
            "Cn5gRegisteredUeMismatch", "Cn5gUserPlaneProbeFailed",
        ):
            self.assertIn(expected, names)
        self.assertEqual(config["alerts.yaml"].count("cn5g_observability_alert_exercise"), 3)

    def test_grafana_and_loki_are_fully_provisioned_from_git(self):
        dashboard_paths = sorted((OBS_CHART / "files" / "dashboards").glob("*.json"))
        self.assertEqual(len(dashboard_paths), 5)
        uids = set()
        titles = set()
        for path in dashboard_paths:
            dashboard = json.loads(path.read_text(encoding="utf-8"))
            uids.add(dashboard["uid"])
            titles.add(dashboard["title"])
            self.assertIn("cn5g", dashboard["tags"])
            if dashboard["uid"] == "cn5g-performance":
                self.assertIn("phase-07", dashboard["tags"])
            else:
                self.assertIn("phase-06", dashboard["tags"])
            self.assertFalse(dashboard["editable"])
            self.assertEqual(dashboard["refresh"], "30s")
            self.assertGreaterEqual(len(dashboard["panels"]), 10)
            self.assertEqual(len(dashboard["links"]), 5)
            self.assertEqual(dashboard["panels"][0]["type"], "text")
            serialized = json.dumps(dashboard).lower()
            self.assertNotIn("imsi", serialized)
            self.assertNotIn("supi", serialized)
            for panel in dashboard["panels"]:
                self.assertTrue(panel.get("title"))
                if panel["type"] != "text":
                    self.assertTrue(panel.get("description"), panel["title"])
                for target in panel.get("targets", []):
                    if panel.get("datasource", {}).get("type") == "loki":
                        self.assertLessEqual(target.get("maxLines", 500), 500)
        self.assertEqual(len(uids), 5)
        self.assertEqual(titles, {
            "CN5G Service Overview",
            "CN5G Control, Sessions, UEs, And DNNs",
            "CN5G Kubernetes Resources",
            "CN5G Logs And Troubleshooting",
            "CN5G Performance And Capacity Experiments",
        })
        grafana = self.object_named(
            self.obs, "ConfigMap", "cn5g-observability-grafana-provisioning"
        )["data"]
        self.assertIn("uid: prometheus", grafana["datasources.yaml"])
        self.assertIn("uid: loki", grafana["datasources.yaml"])
        self.assertIn("maxLines: 500", grafana["datasources.yaml"])
        loki = self.object_named(
            self.obs, "ConfigMap", "cn5g-observability-loki-config"
        )["data"]["loki.yaml"]
        self.assertIn("retention_period: 24h", loki)
        self.assertIn("reporting_enabled: false", loki)

    def test_stage_a_dashboards_cover_the_accepted_operational_contract(self):
        dashboards = {
            json.loads(path.read_text(encoding="utf-8"))["uid"]:
                json.loads(path.read_text(encoding="utf-8"))
            for path in (OBS_CHART / "files" / "dashboards").glob("*.json")
        }
        required_panels = {
            "cn5g-platform": {
                "Core workload readiness", "Telemetry targets", "Active alerts",
                "Registered UEs", "PFCP sessions", "User-plane paths",
                "Network-function health matrix",
                "Memory pressure relative to limits", "CPU relative to requests",
                "Last OOM terminations", "Recent warnings and errors by component",
            },
            "cn5g-5g-service": {
                "Per-UE operational contract", "DNN comparison",
                "Per-UE user-plane state", "Probe duration", "UE TUN packet rate",
            },
            "cn5g-kubernetes": {
                "Workload replica contract", "Memory / limit", "CPU / request",
                "CPU / limit", "Working-set memory",
                "Required Prometheus targets", "Prometheus scrape duration",
            },
            "cn5g-logs": {
                "Warning and error rate by component", "Selected core logs",
                "Registration, authentication, and NAS security signals",
                "PFCP, PDU-session, and GTP-U signals", "Kubernetes Events",
                "Observability pipeline logs",
            },
        }
        for uid, panel_titles in required_panels.items():
            observed = {panel["title"] for panel in dashboards[uid]["panels"]}
            self.assertTrue(panel_titles <= observed, uid)
        variables = {
            uid: {item["name"] for item in dashboard["templating"]["list"]}
            for uid, dashboard in dashboards.items()
        }
        self.assertEqual(variables["cn5g-5g-service"], {"ue_ordinal", "dnn"})
        self.assertEqual(variables["cn5g-kubernetes"], {"namespace", "component"})
        self.assertEqual(variables["cn5g-logs"], {"component", "severity"})
        service_json = json.dumps(dashboards["cn5g-5g-service"])
        self.assertIn('ordinal=~\\"$ue_ordinal\\"', service_json)
        self.assertIn('dnn=~\\"$dnn\\"', service_json)
        self.assertIn("Cross-DNN", service_json)
        resource_json = json.dumps(dashboards["cn5g-kubernetes"])
        self.assertIn("kube_pod_container_resource_limits", resource_json)
        self.assertIn("kube_pod_container_resource_requests", resource_json)
        self.assertIn("scrape_duration_seconds", resource_json)

    def test_grafana_runtime_is_hardened_for_interactive_dashboard_use(self):
        deployment = self.object_named(
            self.obs, "Deployment", "cn5g-observability-grafana"
        )
        container = deployment["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(container["resources"]["requests"]["memory"], "192Mi")
        self.assertEqual(container["resources"]["limits"]["memory"], "768Mi")
        env = {item["name"]: item["value"] for item in container["env"]}
        self.assertEqual(env["GF_PLUGINS_PREINSTALL_DISABLED"], "true")
        for setting in (
            "GF_ANALYTICS_REPORTING_ENABLED",
            "GF_ANALYTICS_CHECK_FOR_UPDATES",
            "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES",
            "GF_PLUGINS_PREINSTALL_AUTO_UPDATE",
            "GF_PLUGINS_PLUGIN_ADMIN_ENABLED",
        ):
            self.assertEqual(env[setting], "false")
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(
            deployment["spec"]["template"]["metadata"]["annotations"]
            ["cn5g.io/config-revision"],
            "3",
        )

    def test_alloy_is_api_based_and_strictly_project_scoped(self):
        alloy = self.object_named(
            self.obs, "ConfigMap", "cn5g-observability-alloy-config"
        )["data"]["config.alloy"]
        self.assertIn('names = ["cn5g"]', alloy)
        self.assertIn('names = ["cn5g-observability"]', alloy)
        self.assertIn("loki.source.kubernetes", alloy)
        self.assertIn("loki.source.kubernetes_events", alloy)
        self.assertNotIn("/var/log", alloy)
        self.assertNotIn("promtail", alloy.lower())

    def test_lifecycle_is_syntax_valid_scoped_and_reversible(self):
        self.assertTrue(LIFECYCLE.stat().st_mode & 0o111)
        syntax = subprocess.run(
            ["bash", "-n", str(LIFECYCLE)], check=False,
            capture_output=True, text=True,
        )
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        for expected in (
            "phase06_preflight=pass", "server_side_phase06_dry_run=pass",
            "phase06_validation=pass", "phase06_alert_lifecycle=pass tested=3",
            "grafana_provisioning=pass", "metric_cardinality=bounded",
            "phase06_uninstall=pass", "phase06_destroy=pass",
            "--address 127.0.0.1", "phase05-lab.sh repair-sessions",
            "--rollback-on-failure", "alert-exercise|phase07-reviewed-results|open5gs-",
            "verify-grafana-soak", "grafana_soak_baseline=recorded",
            "grafana_interactive_soak=pass", "minimum_duration_seconds=1800",
            "runtime_plugin_installation=disabled",
            "rollback-hardening", "dashboard_hardening_rollback=pass",
            "telemetry_pvc_identity=preserved",
            "phase06_core_overlay=already-active upgrade=skipped",
            "Grafana soak state target is unsafe",
            'rm -f -- "$grafana_soak_state_file" "$hardening_state_file"',
            'count({__name__=~"cn5g_ue_.*"})',
            'count({__name__=~"cn5g_phase07_reviewed_.+"})',
            "phase07_reviewed_metric_validation=pass",
            "grafana_provisioning=pass datasources=2 dashboards=5",
            "--field-manager=helm",
            "--dry-run=server --hide-secret",
        ):
            self.assertIn(expected, self.lifecycle)
        self.assertNotIn("--force-conflicts", self.lifecycle)
        self.assertNotIn("--atomic", self.lifecycle)
        self.assertNotIn("/api/v1/series", self.lifecycle)
        for forbidden in (
            "docker system prune", "docker network prune", "docker volume prune",
            "kubectl delete namespace --all", "helm uninstall --all", "rm -rf /",
            "iptables -F", "nft flush", "systemctl stop",
        ):
            self.assertNotIn(forbidden, self.lifecycle)

    def test_public_phase06_artifacts_do_not_embed_local_identity_or_secrets(self):
        content = self.core_rendered + self.obs_rendered + self.lifecycle + self.versions
        self.assertNotIn("/home/", content)
        self.assertNotIn("fawaz@", content.lower())
        self.assertNotRegex(content, r"password:\s*[A-Za-z0-9]{16,}")
        secret_objects = [item for item in self.obs if item["kind"] == "Secret"]
        self.assertEqual(secret_objects, [])


if __name__ == "__main__":
    unittest.main()
