#!/usr/bin/env python3
"""Static safety and coverage tests for Phase 4 runtime validation."""

from __future__ import annotations

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "validate-kubernetes.sh"


class Phase04ValidationStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = SCRIPT.read_text(encoding="utf-8")

    def test_validator_is_executable_valid_bash(self):
        self.assertTrue(SCRIPT.stat().st_mode & 0o111)
        result = subprocess.run(
            ["bash", "-n", str(SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_validator_uses_only_the_project_cluster_scope(self):
        self.assertIn("artifacts/kubernetes/cn5g.kubeconfig", self.script)
        self.assertIn("CN5G_KUBERNETES_NAMESPACE", self.script)
        self.assertIn("CN5G_HELM_RELEASE_NAME", self.script)
        self.assertNotIn("~/.kube", self.script)
        self.assertNotIn("/home/", self.script)
        self.assertNotIn("NodePort", self.script)

    def test_control_plane_protocol_evidence_is_required(self):
        for marker in (
            "SCTP connection established",
            "NG Setup procedure is successful",
            "Authentication Request received",
            "Security Mode Command received",
            "Initial Registration is successful",
            "PDU Session establishment is successful",
            "PFCP associated",
            "[Added] Number of UPF-Sessions is now 1",
            "gtp_connect()",
        ):
            self.assertIn(marker, self.script)

    def test_real_user_plane_is_bound_to_the_ue_tun(self):
        self.assertIn("--interface uesimtun0", self.script)
        self.assertIn("ping -I uesimtun0", self.script)
        self.assertIn("cn5g-data-network-ok", self.script)
        self.assertIn("/sys/class/net/uesimtun0/statistics/rx_packets", self.script)
        self.assertIn("/sys/class/net/uesimtun0/statistics/tx_packets", self.script)
        self.assertIn("/sys/class/net/ogstun/statistics/rx_packets", self.script)
        self.assertIn("/sys/class/net/ogstun/statistics/tx_packets", self.script)
        self.assertIn("bidirectional_tunnel_counters=pass", self.script)
        self.assertIn("gtpu_user_plane=pass", self.script)

    def test_n6_route_and_capabilities_are_exactly_verified(self):
        self.assertIn("CN5G_N6_RETURN_SUBNET", self.script)
        self.assertIn("CN5G_N6_RETURN_PROTOCOL", self.script)
        self.assertIn("CN5G_N6_RETURN_METRIC", self.script)
        self.assertIn("kind_node_return_route=", self.script)
        self.assertIn('upf_cap != "0000000000001000"', self.script)
        self.assertIn('ue_cap != "0000000000003000"', self.script)
        self.assertIn('data_cap != "0000000000000000"', self.script)
        self.assertIn("capability_minimization=pass", self.script)

    def test_validator_does_not_mutate_or_expose_sensitive_state(self):
        for forbidden in (
            "route add",
            "route replace",
            "route del",
            "kubectl delete",
            "helm uninstall",
            "get secret",
            "base64 --decode",
            "docker system prune",
            "privileged",
        ):
            self.assertNotIn(forbidden, self.script)


if __name__ == "__main__":
    unittest.main()
