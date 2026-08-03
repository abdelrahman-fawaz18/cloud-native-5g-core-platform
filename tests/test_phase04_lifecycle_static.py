#!/usr/bin/env python3
"""Static safety tests for the initial Phase 4 Helm lifecycle helper."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "helm-lab.sh"


class Phase04LifecycleStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = SCRIPT.read_text(encoding="utf-8")
        cls.body = re.sub(r"cat <<'EOF'.*?\nEOF", "", cls.script, flags=re.S)

    def test_script_is_valid_bash(self):
        result = subprocess.run(
            ["bash", "-n", str(SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_lifecycle_uses_repository_kubeconfig_and_exact_identity(self):
        self.assertIn("artifacts/kubernetes/cn5g.kubeconfig", self.script)
        self.assertIn('CN5G_HELM_RELEASE_NAME != "cn5g"', self.script)
        self.assertIn('CN5G_KUBERNETES_NAMESPACE != "cn5g"', self.script)
        self.assertIn('--name "$KIND_CLUSTER_NAME"', self.script)
        self.assertIn('--namespace "$CN5G_KUBERNETES_NAMESPACE"', self.script)
        self.assertNotIn("$HOME", self.body)
        self.assertNotIn("~/.kube", self.body)

    def test_image_load_requires_accepted_local_identities(self):
        self.assertIn("OPEN5GS_LOCAL_IMAGE_ID", self.script)
        self.assertIn("UERANSIM_LOCAL_IMAGE_ID", self.script)
        self.assertIn("DATA_NETWORK_LOCAL_IMAGE_ID", self.script)
        self.assertIn('observed_id != "$expected_id"', self.script)
        self.assertIn("kind load docker-image", self.script)
        self.assertIn("crictl inspecti", self.script)

    def test_secret_is_file_backed_and_values_are_never_requested(self):
        self.assertIn("--from-file=ue.yaml=", self.script)
        self.assertIn("--from-file=subscriber-init.js=", self.script)
        self.assertIn("--from-file=imsi=", self.script)
        self.assertNotIn("--from-literal", self.script)
        self.assertNotIn("kubectl create secret docker-registry", self.script)
        self.assertNotIn("get secret -o yaml", self.script)
        self.assertNotIn("get secret -o json", self.script)
        self.assertIn("base64 --decode", self.script)
        self.assertIn("sha256sum", self.script)

    def test_install_has_server_validation_and_wait_gates(self):
        self.assertIn("--dry-run=server --hide-secret", self.script)
        self.assertIn("--wait=watcher", self.script)
        self.assertIn("--wait-for-jobs", self.script)
        self.assertIn("--timeout=8m", self.script)
        self.assertIn("phase04_install=pass", self.script)

    def test_preflight_reuses_accepted_cluster_safety_and_static_gates(self):
        self.assertIn('kind-feasibility.sh" preflight', self.script)
        self.assertIn('install-helm.sh" --check', self.script)
        self.assertIn('generate-subscriber-secret.sh" --check', self.script)
        self.assertIn('helm lint "$chart" --strict', self.script)
        self.assertIn("cmp --silent", self.script)

    def test_no_broad_cleanup_host_route_or_service_mutation(self):
        for forbidden in (
            "docker system prune",
            "docker image prune",
            "docker network prune",
            "docker volume prune",
            "iptables",
            "nft ",
            "ip route add",
            "ip route replace",
            "systemctl stop",
            "systemctl disable",
            "apt-get",
            "privileged: true",
        ):
            self.assertNotIn(forbidden, self.body)

    def test_public_script_does_not_embed_local_identity(self):
        self.assertNotIn("/home/", self.script)
        self.assertNotIn("fawaz", self.script.lower())


if __name__ == "__main__":
    unittest.main()
