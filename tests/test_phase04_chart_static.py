#!/usr/bin/env python3
"""Static rendering, schema, and security tests for the Phase 4 Helm chart."""

from __future__ import annotations

from pathlib import Path
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts" / "cn5g"


def helm(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["helm", *arguments],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )


class Phase04ChartStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        first = helm(
            "template",
            "cn5g",
            str(CHART),
            "--namespace",
            "cn5g",
            "--kube-version",
            "1.36.1",
        )
        if first.returncode != 0:
            raise AssertionError(first.stderr)
        second = helm(
            "template",
            "cn5g",
            str(CHART),
            "--namespace",
            "cn5g",
            "--kube-version",
            "1.36.1",
        )
        if second.returncode != 0:
            raise AssertionError(second.stderr)
        cls.rendered = first.stdout
        cls.second_render = second.stdout
        cls.values = yaml.safe_load(
            (CHART / "values.yaml").read_text(encoding="utf-8")
        )
        cls.objects = [
            document
            for document in yaml.safe_load_all(cls.rendered)
            if document is not None
        ]

    def objects_of_kind(self, kind: str) -> list[dict]:
        return [obj for obj in self.objects if obj["kind"] == kind]

    def pod_specs(self) -> list[tuple[str, dict]]:
        specs: list[tuple[str, dict]] = []
        for obj in self.objects:
            if obj["kind"] in ("Deployment", "StatefulSet", "Job"):
                specs.append((obj["metadata"]["name"], obj["spec"]["template"]["spec"]))
        return specs

    def test_chart_lints_strictly(self):
        result = helm("lint", str(CHART), "--strict")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_default_render_is_deterministic(self):
        self.assertEqual(self.rendered, self.second_render)

    def test_expected_workload_model_is_rendered(self):
        self.assertEqual(len(self.objects_of_kind("Deployment")), 13)
        self.assertEqual(len(self.objects_of_kind("StatefulSet")), 1)
        self.assertEqual(len(self.objects_of_kind("Job")), 1)
        self.assertEqual(len(self.objects_of_kind("Service")), 13)
        self.assertEqual(len(self.objects_of_kind("ConfigMap")), 2)
        self.assertEqual(len(self.objects_of_kind("ServiceAccount")), 1)
        components = {
            deployment["metadata"]["labels"]["app.kubernetes.io/component"]
            for deployment in self.objects_of_kind("Deployment")
        }
        self.assertEqual(
            components,
            {
                "nrf", "scp", "amf", "ausf", "udm", "udr", "pcf",
                "nssf", "smf", "upf", "gnb", "ue", "data-network",
            },
        )

    def test_single_replica_open5gs_components_use_recreate_strategy(self):
        expected = {
            "nrf", "scp", "amf", "ausf", "udm", "udr", "pcf",
            "nssf", "smf", "upf",
        }
        observed = {
            deployment["metadata"]["labels"]["app.kubernetes.io/component"]
            for deployment in self.objects_of_kind("Deployment")
            if deployment.get("spec", {}).get("strategy", {}).get("type")
            == "Recreate"
        }
        self.assertTrue(expected.issubset(observed))
        for deployment in self.objects_of_kind("Deployment"):
            strategy = deployment.get("spec", {}).get("strategy", {})
            if strategy.get("type") == "Recreate":
                self.assertIsNone(strategy.get("rollingUpdate"))

    def test_schema_rejects_invalid_operational_values(self):
        invalid_sets = (
            ("--set-string", "subscriberSecret.existingSecret="),
            ("--set-string", "images.open5gs.tag=latest"),
            ("--set", "global.ueMtu=1601"),
            ("--set-string", "global.plmn.mcc=99"),
        )
        for flag, value in invalid_sets:
            with self.subTest(value=value):
                result = helm("template", "cn5g", str(CHART), flag, value)
                self.assertNotEqual(result.returncode, 0)

    def test_images_are_immutable_or_locally_identity_gated(self):
        values = yaml.safe_load((CHART / "values.yaml").read_text(encoding="utf-8"))
        for name in ("open5gs", "ueransim", "dataNetwork"):
            image = values["images"][name]
            self.assertNotEqual(image["tag"], "latest")
            self.assertEqual(image["pullPolicy"], "Never")
            self.assertRegex(image["expectedImageID"], r"^sha256:[0-9a-f]{64}$")
        mongodb = values["images"]["mongodb"]
        self.assertRegex(mongodb["digest"], r"^sha256:[0-9a-f]{64}$")
        self.assertEqual(mongodb["pullPolicy"], "Never")
        self.assertEqual(mongodb["expectedImageID"], mongodb["digest"])
        self.assertIn("image: mongo:8.0.28-noble", self.rendered)
        self.assertNotIn("image: mongo:8.0.28-noble@", self.rendered)
        self.assertNotIn(":latest", self.rendered)

    def test_secret_values_are_not_rendered_or_managed_by_chart(self):
        self.assertEqual(self.objects_of_kind("Secret"), [])
        for forbidden in (
            "supi:",
            "opc:",
            "key: '",
            "homeNetworkPublicKey:",
        ):
            self.assertNotIn(forbidden, self.rendered)
        self.assertIn("secretName: cn5g-subscriber", self.rendered)

    def test_workloads_have_no_api_credentials_or_rbac_grants(self):
        for _, spec in self.pod_specs():
            self.assertFalse(spec["automountServiceAccountToken"])
            self.assertEqual(spec["serviceAccountName"], "cn5g-workload")
        for kind in ("Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding"):
            self.assertEqual(self.objects_of_kind(kind), [])

    def test_all_containers_have_resources_and_restricted_contexts(self):
        for workload, spec in self.pod_specs():
            self.assertEqual(spec["securityContext"]["seccompProfile"]["type"], "RuntimeDefault")
            for container in spec.get("initContainers", []) + spec["containers"]:
                with self.subTest(workload=workload, container=container["name"]):
                    context = container["securityContext"]
                    self.assertFalse(context["allowPrivilegeEscalation"])
                    self.assertTrue(context["readOnlyRootFilesystem"])
                    self.assertIn("ALL", context["capabilities"]["drop"])
                    self.assertFalse(context.get("privileged", False))
                    self.assertIn("requests", container["resources"])
                    self.assertIn("limits", container["resources"])

    def test_resource_requests_match_phase04_observation(self):
        self.assertEqual(
            self.values["mongodb"]["resources"]["requests"],
            {"cpu": "200m", "memory": "256Mi"},
        )
        self.assertEqual(
            self.values["open5gs"]["resources"]["requests"],
            {"cpu": "25m", "memory": "64Mi"},
        )
        self.assertEqual(
            self.values["dataNetwork"]["resources"]["requests"],
            {"cpu": "10m", "memory": "16Mi"},
        )

    def test_network_capabilities_are_limited_to_upf_and_ue(self):
        observed: dict[str, set[str]] = {}
        for workload, spec in self.pod_specs():
            for container in spec.get("initContainers", []) + spec["containers"]:
                additions = set(container["securityContext"]["capabilities"].get("add", []))
                network_additions = additions.intersection({"NET_ADMIN", "NET_RAW"})
                if network_additions:
                    observed[workload] = network_additions
        self.assertEqual(observed["cn5g-upf"], {"NET_ADMIN"})
        self.assertEqual(observed["cn5g-ue"], {"NET_ADMIN", "NET_RAW"})
        self.assertEqual(set(observed), {"cn5g-upf", "cn5g-ue"})

    def test_tun_mounts_are_scoped_and_privileged_mode_is_absent(self):
        tun_mounts = 0
        for workload, spec in self.pod_specs():
            self.assertNotIn("hostNetwork", spec, workload)
            for volume in spec.get("volumes", []):
                if volume.get("hostPath", {}).get("path") == "/dev/net/tun":
                    self.assertEqual(volume["hostPath"]["type"], "CharDevice")
                    tun_mounts += 1
        self.assertEqual(tun_mounts, 2)
        self.assertNotIn("privileged: true", self.rendered)

    def test_services_are_cluster_internal_and_cover_5g_transports(self):
        services = self.objects_of_kind("Service")
        for service in services:
            self.assertNotIn(service["spec"].get("type"), ("NodePort", "LoadBalancer"))
        ports = {
            (port["port"], port["protocol"])
            for service in services
            for port in service["spec"]["ports"]
        }
        self.assertIn((38412, "SCTP"), ports)
        self.assertIn((8805, "UDP"), ports)
        self.assertIn((2152, "UDP"), ports)

    def test_dynamic_pod_address_rendering_replaces_compose_ips(self):
        configmaps = self.objects_of_kind("ConfigMap")
        config_text = "\n".join(
            value for obj in configmaps for value in obj.get("data", {}).values()
        )
        self.assertIn("__POD_IP__", config_text)
        self.assertIn("__AMF_IP__", config_text)
        self.assertNotIn("172.28.0.", config_text)
        self.assertNotIn("10.62.0.", config_text)

    def test_database_consumers_reference_the_mongodb_service(self):
        open5gs_config = next(
            obj
            for obj in self.objects_of_kind("ConfigMap")
            if obj["metadata"]["name"] == "cn5g-open5gs-config"
        )["data"]
        expected_uri = "db_uri: mongodb://cn5g-mongodb:27017/open5gs"
        for component in ("udm.yaml", "udr.yaml", "pcf.yaml"):
            self.assertIn(expected_uri, open5gs_config[component], component)

    def test_sbi_network_functions_advertise_stable_service_fqdns(self):
        open5gs_config = next(
            obj
            for obj in self.objects_of_kind("ConfigMap")
            if obj["metadata"]["name"] == "cn5g-open5gs-config"
        )["data"]
        for component in (
            "nrf", "scp", "amf", "ausf", "udm", "udr", "pcf", "nssf", "smf"
        ):
            config = open5gs_config[f"{component}.yaml"]
            self.assertIn("address: __POD_IP__", config, component)
            self.assertIn(
                f"advertise: cn5g-{component}.cn5g.svc.cluster.local",
                config,
                component,
            )

    def test_mongodb_has_one_persistent_data_claim(self):
        statefulset = self.objects_of_kind("StatefulSet")[0]
        claims = statefulset["spec"]["volumeClaimTemplates"]
        self.assertEqual(len(claims), 1)
        self.assertEqual(claims[0]["metadata"]["name"], "mongodb-data")
        self.assertEqual(claims[0]["spec"]["storageClassName"], "standard")
        self.assertEqual(claims[0]["spec"]["accessModes"], ["ReadWriteOnce"])

    def test_mongodb_liveness_checks_database_health_without_signaling_pid_one(self):
        statefulset = self.objects_of_kind("StatefulSet")[0]
        mongodb = statefulset["spec"]["template"]["spec"]["containers"][0]
        command = mongodb["livenessProbe"]["exec"]["command"]
        self.assertIn("mongosh", command[-1])
        self.assertIn("adminCommand({ping:1})", command[-1])
        self.assertNotIn("kill -0 1", command[-1])

    def test_ueransim_renderers_use_single_contiguous_sed_commands(self):
        deployments = {
            obj["metadata"]["name"]: obj
            for obj in self.objects_of_kind("Deployment")
        }
        for name in ("cn5g-gnb", "cn5g-ue"):
            script = deployments[name]["spec"]["template"]["spec"][
                "initContainers"
            ][-1]["args"][0]
            lines = script.splitlines()
            continued_arguments = [
                index
                for index, line in enumerate(lines)
                if line.lstrip().startswith(("-e ", "/config-source/", "/secret/"))
            ]
            self.assertTrue(continued_arguments)
            for index in continued_arguments:
                self.assertGreater(index, 0)
                self.assertTrue(lines[index - 1].rstrip().endswith("\\"))

    def test_ran_rollout_is_scoped_and_gnb_detects_a_lost_amf_association(self):
        deployments = {
            obj["metadata"]["name"]: obj
            for obj in self.objects_of_kind("Deployment")
        }
        for name in ("cn5g-gnb", "cn5g-ue"):
            annotations = deployments[name]["spec"]["template"]["metadata"][
                "annotations"
            ]
            self.assertEqual(annotations["cn5g.io/rollout-token"], "baseline")
        gnb = deployments["cn5g-gnb"]["spec"]["template"]["spec"][
            "containers"
        ][0]
        for probe_name in ("readinessProbe", "livenessProbe"):
            command = gnb[probe_name]["exec"]["command"][-1]
            self.assertIn("NG Setup procedure is successful", command)
            self.assertIn("Association terminated for AMF", command)
            self.assertIn("tail -n 1", command)

    def test_rendered_shell_commands_pass_posix_shell_syntax(self):
        checked = 0
        for obj in self.objects:
            if obj["kind"] not in ("Deployment", "StatefulSet", "Job"):
                continue
            pod_spec = obj["spec"].get("template", {}).get("spec", {})
            containers = pod_spec.get("initContainers", []) + pod_spec.get(
                "containers", []
            )
            for container in containers:
                if container.get("command") != ["/bin/sh", "-ec"]:
                    continue
                for argument in container.get("args", []):
                    result = subprocess.run(
                        ["/bin/sh", "-n", "-c", argument],
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(
                        result.returncode,
                        0,
                        f"{obj['kind']}/{obj['metadata']['name']} "
                        f"container {container['name']}: {result.stderr}",
                    )
                    checked += 1
        self.assertGreaterEqual(checked, 6)

    def test_upf_avoids_forbidden_pod_sysctl_and_checks_forwarding(self):
        upf = next(
            obj
            for obj in self.objects_of_kind("Deployment")
            if obj["metadata"]["name"] == "cn5g-upf"
        )
        pod_spec = upf["spec"]["template"]["spec"]
        self.assertNotIn("sysctls", pod_spec["securityContext"])
        container = pod_spec["containers"][0]
        self.assertIn("/proc/sys/net/ipv4/ip_forward", container["args"][0])
        self.assertIn("exec open5gs-entrypoint upf", container["args"][0])

    def test_long_running_containers_have_distinct_three_stage_probes(self):
        checked = 0
        for obj in self.objects:
            if obj["kind"] not in ("Deployment", "StatefulSet"):
                continue
            for container in obj["spec"]["template"]["spec"]["containers"]:
                startup = container["startupProbe"]
                readiness = container["readinessProbe"]
                liveness = container["livenessProbe"]
                self.assertNotEqual(startup, readiness)
                self.assertNotEqual(readiness, liveness)
                self.assertNotEqual(startup, liveness)
                checked += 1
        self.assertEqual(checked, 14)


if __name__ == "__main__":
    unittest.main()
