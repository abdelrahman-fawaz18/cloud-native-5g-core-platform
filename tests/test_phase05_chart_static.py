#!/usr/bin/env python3
"""Static rendering and security tests for the Phase 5 Helm topology."""

from __future__ import annotations

from collections import Counter
import json
from pathlib import Path
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts" / "cn5g"
OVERLAY = CHART / "values-phase05.yaml"
PLAN = ROOT / "configs" / "kubernetes" / "phase-05" / "subscriber-plan.json"


def helm(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["helm", *arguments], cwd=ROOT, check=False, capture_output=True, text=True
    )


class Phase05ChartStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = helm(
            "template", "cn5g", str(CHART), "--namespace", "cn5g",
            "--kube-version", "1.36.1", "--values", str(OVERLAY),
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        cls.rendered = result.stdout
        cls.objects = [item for item in yaml.safe_load_all(result.stdout) if item]
        cls.values = yaml.safe_load((CHART / "values.yaml").read_text(encoding="utf-8"))
        cls.plan = json.loads(PLAN.read_text(encoding="utf-8"))

    def objects_of_kind(self, kind: str) -> list[dict]:
        return [obj for obj in self.objects if obj["kind"] == kind]

    def object_named(self, kind: str, name: str) -> dict:
        return next(
            obj for obj in self.objects
            if obj["kind"] == kind and obj["metadata"]["name"] == name
        )

    def test_phase05_overlay_lints_strictly_and_renders_deterministically(self):
        lint = helm("lint", str(CHART), "--strict", "--values", str(OVERLAY))
        self.assertEqual(lint.returncode, 0, lint.stdout + lint.stderr)
        repeat = helm(
            "template", "cn5g", str(CHART), "--namespace", "cn5g",
            "--kube-version", "1.36.1", "--values", str(OVERLAY),
        )
        self.assertEqual(repeat.returncode, 0, repeat.stderr)
        self.assertEqual(self.rendered, repeat.stdout)

    def test_phase05_object_model_has_five_stable_ue_identities(self):
        counts = Counter(obj["kind"] for obj in self.objects)
        self.assertEqual(counts["Deployment"], 13)
        self.assertEqual(counts["StatefulSet"], 2)
        self.assertEqual(counts["Service"], 16)
        ue = self.object_named("StatefulSet", "cn5g-ue")
        self.assertEqual(ue["spec"]["replicas"], 5)
        self.assertEqual(ue["spec"]["serviceName"], "cn5g-ue")
        self.assertEqual(ue["spec"]["podManagementPolicy"], "Parallel")
        self.assertNotIn("volumeClaimTemplates", ue["spec"])
        self.assertEqual(self.object_named("Service", "cn5g-ue")["spec"]["clusterIP"], "None")
        self.assertFalse(any(
            obj["kind"] == "Deployment" and obj["metadata"]["name"] == "cn5g-ue"
            for obj in self.objects
        ))

    def test_ordinal_selects_exact_matching_secret_files(self):
        ue = self.object_named("StatefulSet", "cn5g-ue")
        init = {item["name"]: item for item in ue["spec"]["template"]["spec"]["initContainers"]}
        wait_script = init["wait-for-subscriber"]["args"][0]
        render_script = init["render-config"]["args"][0]
        for script in (wait_script, render_script):
            self.assertIn("${POD_NAME##*-}", script)
            self.assertIn("cn5g-ue-[0-4]", script)
            self.assertIn("fieldPath: metadata.name", yaml.safe_dump(init))
        self.assertIn('"/secret/imsi-${ordinal}"', wait_script)
        self.assertIn('ue-${ordinal}.yaml', render_script)
        secret = next(
            volume["secret"] for volume in ue["spec"]["template"]["spec"]["volumes"]
            if volume["name"] == "subscriber-secret"
        )
        self.assertEqual(secret["secretName"], "cn5g-subscribers-phase05")
        self.assertNotIn("items", secret)
        runtime_mounts = {
            mount["name"]
            for mount in ue["spec"]["template"]["spec"]["containers"][0]["volumeMounts"]
        }
        self.assertNotIn("subscriber-secret", runtime_mounts)

    def test_phase05_readiness_accepts_both_managed_ue_pools(self):
        ue = self.object_named("StatefulSet", "cn5g-ue")
        container = ue["spec"]["template"]["spec"]["containers"][0]
        command = container["readinessProbe"]["exec"]["command"]
        self.assertEqual(command[:2], ["/bin/sh", "-ec"])
        readiness = command[2]
        self.assertIn("10.60.0.*/*|10.61.0.*/*", readiness)
        self.assertIn("lookup rt_uesimtun0", readiness)
        self.assertIn("^default dev uesimtun0", readiness)

    def test_two_dnn_contracts_match_the_public_plan(self):
        sessions = self.values["phase05"]["sessions"]
        self.assertEqual(
            [{key: session[key] for key in ("name", "pool", "gateway", "tunDevice", "endpoint")} for session in sessions],
            self.plan["dnns"],
        )
        config = self.object_named("ConfigMap", "cn5g-open5gs-config")["data"]
        for session in sessions:
            self.assertIn(f"subnet: {session['pool']}", config["smf.yaml"])
            self.assertIn(f"dnn: {session['name']}", config["smf.yaml"])
            self.assertIn(f"dev: {session['tunDevice']}", config["upf.yaml"])
        self.assertIn("dnn: [internet, enterprise]", config["smf.yaml"])

    def test_pfcp_uses_direct_upf_endpoint_discovery(self):
        service = self.object_named("Service", "cn5g-upf-pfcp")
        self.assertEqual(service["spec"]["clusterIP"], "None")
        self.assertEqual(
            service["spec"]["selector"]["app.kubernetes.io/component"], "upf"
        )
        self.assertEqual(service["spec"]["ports"], [{
            "name": "n4-pfcp", "protocol": "UDP", "port": 8805,
            "targetPort": "n4-pfcp",
        }])
        config = self.object_named("ConfigMap", "cn5g-open5gs-config")["data"]
        self.assertIn("address: cn5g-upf-pfcp", config["smf.yaml"])

    def test_two_headless_endpoints_return_distinct_identity_content(self):
        for name in ("internet", "enterprise"):
            component = f"data-{name}"
            service = self.object_named("Service", f"cn5g-{component}")
            self.assertEqual(service["spec"]["clusterIP"], "None")
            deployment = self.object_named("Deployment", f"cn5g-{component}")
            init = deployment["spec"]["template"]["spec"]["initContainers"][0]
            self.assertIn(f"cn5g-dnn={name}", init["args"][0])

    def test_upf_owns_two_tuns_and_source_policy_is_fail_closed(self):
        upf = self.object_named("Deployment", "cn5g-upf")
        spec = upf["spec"]["template"]["spec"]
        init = next(item for item in spec["initContainers"] if item["name"] == "configure-dnn-network")
        script = init["args"][0]
        for expected in (
            "ogstun", "ogstun2", "10.60.0.1/24", "10.61.0.1/24",
            "table 1060", "table 1061", "unreachable default",
            "from 10.60.0.0/24", "from 10.61.0.0/24",
        ):
            self.assertIn(expected, script)
        for table in (1060, 1061):
            self.assertIn(
                f"ip route flush table {table} 2>/dev/null || true", script
            )
        self.assertEqual(init["securityContext"]["capabilities"]["add"], ["NET_ADMIN"])
        self.assertFalse(init["securityContext"]["allowPrivilegeEscalation"])
        self.assertFalse(init["securityContext"].get("privileged", False))

    def test_all_rendered_phase05_shell_programs_have_valid_posix_syntax(self):
        checked = 0
        for obj in self.objects:
            if obj["kind"] not in ("Deployment", "StatefulSet", "Job"):
                continue
            pod_spec = obj["spec"].get("template", {}).get("spec", {})
            containers = pod_spec.get("initContainers", []) + pod_spec.get("containers", [])
            for container in containers:
                if container.get("command") != ["/bin/sh", "-ec"]:
                    continue
                for argument in container.get("args", []):
                    result = subprocess.run(
                        ["/bin/sh", "-n", "-c", argument], check=False,
                        capture_output=True, text=True,
                    )
                    self.assertEqual(
                        result.returncode, 0,
                        f"{obj['kind']}/{obj['metadata']['name']} "
                        f"container {container['name']}: {result.stderr}",
                    )
                    checked += 1
        self.assertGreaterEqual(checked, 8)

    def test_phase05_secret_is_preexisting_and_authentication_values_are_absent(self):
        self.assertEqual(self.objects_of_kind("Secret"), [])
        job = self.objects_of_kind("Job")[0]
        volumes = job["spec"]["template"]["spec"]["volumes"]
        secret = next(volume["secret"] for volume in volumes if volume["name"] == "subscriber-secret")
        self.assertEqual(secret["secretName"], "cn5g-subscribers-phase05")
        self.assertIn("subscriber-init.js", self.rendered)
        self.assertNotRegex(self.rendered, r"[0-9A-F]{32}")

    def test_phase04_default_remains_available_as_controlled_rollback(self):
        result = helm(
            "template", "cn5g", str(CHART), "--namespace", "cn5g",
            "--kube-version", "1.36.1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        objects = [item for item in yaml.safe_load_all(result.stdout) if item]
        ue = next(obj for obj in objects if obj["kind"] == "Deployment" and obj["metadata"]["name"] == "cn5g-ue")
        self.assertEqual(ue["spec"]["replicas"], 1)
        self.assertFalse(any(obj["kind"] == "StatefulSet" and obj["metadata"]["name"] == "cn5g-ue" for obj in objects))
        self.assertIn("secretName: cn5g-subscriber", result.stdout)
        self.assertFalse(any(
            obj["kind"] == "Service" and obj["metadata"]["name"] == "cn5g-upf-pfcp"
            for obj in objects
        ))
        config = next(
            obj for obj in objects
            if obj["kind"] == "ConfigMap" and obj["metadata"]["name"] == "cn5g-open5gs-config"
        )["data"]
        self.assertIn("address: cn5g-upf", config["smf.yaml"])
        self.assertNotIn("address: cn5g-upf-pfcp", config["smf.yaml"])

    def test_schema_rejects_topology_drift(self):
        invalid = (
            "phase05.ueReplicas=4",
            "phase05.sessions[0].pool=10.99.0.0/24",
            "phase05.sessions[1].name=unmanaged",
        )
        for value in invalid:
            with self.subTest(value=value):
                result = helm(
                    "template", "cn5g", str(CHART), "--values", str(OVERLAY),
                    "--set-string", value,
                )
                self.assertNotEqual(result.returncode, 0)

    def test_negative_test_manifests_are_scoped_and_least_privileged(self):
        invalid = yaml.safe_load(
            (ROOT / "configs/kubernetes/phase-05/invalid-ue-pod.yaml")
            .read_text(encoding="utf-8")
        )
        reprovision = yaml.safe_load(
            (ROOT / "configs/kubernetes/phase-05/reprovision-job.yaml")
            .read_text(encoding="utf-8")
        )
        for obj in (invalid, reprovision):
            self.assertEqual(obj["metadata"]["namespace"], "cn5g")
            self.assertEqual(
                obj["metadata"]["labels"]["app.kubernetes.io/managed-by"],
                "cn5g-phase05-lab",
            )
            pod_spec = (
                obj["spec"]["template"]["spec"]
                if obj["kind"] == "Job"
                else obj["spec"]
            )
            self.assertFalse(pod_spec.get("automountServiceAccountToken", True))
        invalid_ue = invalid["spec"]["containers"][0]
        self.assertFalse(invalid_ue["securityContext"]["privileged"])
        self.assertEqual(
            invalid_ue["securityContext"]["capabilities"]["add"],
            ["NET_ADMIN", "NET_RAW"],
        )
        reprovision_container = reprovision["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(
            reprovision_container["securityContext"]["capabilities"]["drop"],
            ["ALL"],
        )
        self.assertEqual(
            reprovision_container["resources"],
            {
                "requests": {"cpu": "10m", "memory": "64Mi"},
                "limits": {"cpu": "250m", "memory": "256Mi"},
            },
        )


if __name__ == "__main__":
    unittest.main()
