#!/usr/bin/env python3
"""Static safety and version-contract tests for Phase 3 feasibility tooling."""

from __future__ import annotations

import ipaddress
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip("'\"")
    return values


class Phase03StaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = parse_env(ROOT / "versions" / "phase-03.env")
        cls.installer = (
            ROOT / "scripts" / "install-kubernetes-tools.sh"
        ).read_text(encoding="utf-8")
        cls.lifecycle = (
            ROOT / "scripts" / "kind-feasibility.sh"
        ).read_text(encoding="utf-8")
        cls.cluster_config = (
            ROOT / "configs" / "kind" / "phase-03.yaml"
        ).read_text(encoding="utf-8")
        cls.subnet_checker = (
            ROOT / "tools" / "check_kind_subnets.py"
        ).read_text(encoding="utf-8")
        cls.probe_script = (
            ROOT / "scripts" / "kind-probes.sh"
        ).read_text(encoding="utf-8")
        cls.probe_dockerfile = (
            ROOT / "containers" / "feasibility-probe" / "Dockerfile"
        ).read_text(encoding="utf-8")
        cls.transport_manifest = (
            ROOT
            / "configs"
            / "kubernetes"
            / "phase-03"
            / "01-transport-probes.yaml"
        ).read_text(encoding="utf-8")
        cls.tun_manifest = (
            ROOT
            / "configs"
            / "kubernetes"
            / "phase-03"
            / "02-tun-capability-probes.yaml"
        ).read_text(encoding="utf-8")
        cls.n6_manifest = (
            ROOT
            / "configs"
            / "kubernetes"
            / "phase-03"
            / "03-n6-routing-probes.yaml"
        ).read_text(encoding="utf-8")

    def test_binary_inputs_are_exact_and_integrity_checked(self):
        self.assertEqual(self.manifest["KIND_VERSION"], "0.32.0")
        self.assertEqual(self.manifest["KUBERNETES_VERSION"], "1.36.1")
        self.assertEqual(self.manifest["PHASE_03_STATUS"], "accepted")
        for key in (
            "KIND_LINUX_AMD64_SHA256",
            "KUBECTL_LINUX_AMD64_SHA256",
        ):
            self.assertRegex(self.manifest[key], r"^[0-9a-f]{64}$")
        self.assertIn("sha256sum --check --status", self.installer)
        self.assertIn("curl --fail --location", self.installer)

    def test_node_image_is_version_and_digest_pinned(self):
        node_image = self.manifest["KIND_NODE_IMAGE"]
        self.assertRegex(
            node_image,
            r"^kindest/node:v1\.36\.1@sha256:[0-9a-f]{64}$",
        )
        self.assertNotIn("latest", node_image)

    def test_cluster_ownership_names_are_explicit(self):
        self.assertEqual(self.manifest["KIND_CLUSTER_NAME"], "cn5g")
        self.assertEqual(self.manifest["KIND_CONTEXT_NAME"], "kind-cn5g")
        self.assertEqual(
            self.manifest["KIND_FEASIBILITY_NAMESPACE"],
            "cn5g-feasibility",
        )
        self.assertEqual(
            self.manifest["KIND_API_SERVER_ADDRESS"], "127.0.0.1"
        )
        self.assertEqual(self.manifest["KIND_DOCKER_NETWORK_NAME"], "kind")
        self.assertEqual(
            self.manifest["KIND_DOCKER_IPV4_SUBNET"], "172.18.0.0/16"
        )
        self.assertEqual(
            self.manifest["KIND_DOCKER_IPV6_SUBNET"],
            "fc00:f853:ccd:e793::/64",
        )

    def test_cluster_subnets_do_not_overlap_phase02_ranges(self):
        phase03 = [
            ipaddress.ip_network(self.manifest["KIND_POD_SUBNET"]),
            ipaddress.ip_network(self.manifest["KIND_SERVICE_SUBNET"]),
        ]
        phase02 = [
            ipaddress.ip_network(network)
            for network in ("172.28.0.0/24", "10.60.0.0/24", "10.62.0.0/24")
        ]
        for candidate in phase03:
            for existing in phase02:
                self.assertFalse(candidate.overlaps(existing))

    def test_installer_has_no_cluster_or_service_side_effects(self):
        forbidden = (
            "kind create cluster",
            "kubectl apply",
            "systemctl enable",
            "systemctl start",
            "usermod",
            "docker group",
            "apt-get",
        )
        body = re.sub(r"cat <<'EOF'.*?\nEOF", "", self.installer, flags=re.S)
        for fragment in forbidden:
            self.assertNotIn(fragment, body)

    def test_installer_refuses_unrecognized_existing_binaries(self):
        self.assertIn("refusing to replace unrecognized", self.installer)
        self.assertIn("unmanaged path", self.installer)
        self.assertIn("present-and-pinned", self.installer)

    def test_cluster_config_is_single_node_and_loopback_scoped(self):
        self.assertIn('apiServerAddress: "127.0.0.1"', self.cluster_config)
        self.assertIn('podSubnet: "10.244.0.0/16"', self.cluster_config)
        self.assertIn('serviceSubnet: "10.96.0.0/16"', self.cluster_config)
        self.assertIn('kubeProxyMode: "iptables"', self.cluster_config)
        self.assertEqual(self.cluster_config.count("role: control-plane"), 1)
        for forbidden in ("extraPortMappings", "extraMounts", "hostNetwork"):
            self.assertNotIn(forbidden, self.cluster_config)

    def test_cluster_lifecycle_uses_exact_owned_targets(self):
        self.assertIn('--name "$KIND_CLUSTER_NAME"', self.lifecycle)
        self.assertIn('--image "$KIND_NODE_IMAGE"', self.lifecycle)
        self.assertIn('--config "$config_file"', self.lifecycle)
        self.assertIn('--kubeconfig "$kubeconfig"', self.lifecycle)
        self.assertIn("artifacts/kubernetes", self.lifecycle)
        self.assertIn("create namespace", self.lifecycle)
        self.assertIn('"$KIND_FEASIBILITY_NAMESPACE"', self.lifecycle)
        self.assertIn(
            "pods --all --all-namespaces --timeout=180s", self.lifecycle
        )
        self.assertIn('confirmation != "--confirm"', self.lifecycle)
        self.assertIn("cn5g-control-plane", self.lifecycle)

    def test_delete_allows_only_ran_processes_owned_by_exact_kind_node(self):
        self.assertIn("verify_ran_process_ownership", self.lifecycle)
        self.assertIn("docker-${owned_node_id}.scope/", self.lifecycle)
        self.assertIn("project_kind_ran_processes=owned", self.lifecycle)
        self.assertIn("unrelated host process is already running", self.lifecycle)

    def test_cluster_lifecycle_avoids_broad_or_implicit_cleanup(self):
        body = re.sub(r"cat <<'EOF'.*?\nEOF", "", self.lifecycle, flags=re.S)
        for forbidden in (
            "docker system prune",
            "docker image prune",
            "docker network prune",
            "docker volume prune",
            "docker rm",
            "docker image rm",
            "$HOME",
            "~/.kube",
        ):
            self.assertNotIn(forbidden, body)
        self.assertIn('rm -f -- "$kubeconfig"', body)
        self.assertIn(
            'docker network rm "$KIND_DOCKER_NETWORK_NAME"', body
        )
        self.assertIn('container_count != "0"', body)
        self.assertIn('label_count != "0"', body)
        self.assertIn("refusing to remove unrecognized or non-empty", body)

    def test_phase03_public_scripts_do_not_embed_a_home_path(self):
        for content in (self.installer, self.lifecycle, self.probe_script):
            self.assertNotIn("/home/", content)

    def test_subnet_checker_reads_routes_and_docker_networks(self):
        self.assertIn('run("ip", "-4", "route", "show")', self.subnet_checker)
        self.assertIn(
            'run("docker", "network", "ls", "--quiet")',
            self.subnet_checker,
        )
        self.assertIn("candidate.overlaps(current)", self.subnet_checker)
        self.assertIn("kind_subnet_check=pass", self.subnet_checker)

    def test_probe_image_reuses_exact_phase02_runtime(self):
        base = self.manifest["UERANSIM_BASE_IMAGE"]
        self.assertRegex(
            base,
            r"^cn5g/ueransim:3\.2\.8@sha256:[0-9a-f]{64}$",
        )
        self.assertIn("ARG UERANSIM_BASE_IMAGE=", self.probe_dockerfile)
        self.assertIn("FROM ${UERANSIM_BASE_IMAGE}", self.probe_dockerfile)
        self.assertLess(
            self.probe_dockerfile.index("ARG UERANSIM_BASE_IMAGE="),
            self.probe_dockerfile.index("FROM ubuntu:24.04@sha256:"),
        )
        self.assertIn("USER 65532:65532", self.probe_dockerfile)
        self.assertIn(
            'org.opencontainers.image.licenses="NOASSERTION"',
            self.probe_dockerfile,
        )
        self.assertNotIn(
            'org.opencontainers.image.licenses="Apache-2.0"',
            self.probe_dockerfile,
        )
        self.assertRegex(
            self.manifest["KIND_FEASIBILITY_PROBE_IMAGE_ID"],
            r"^sha256:[0-9a-f]{64}$",
        )

    def test_probe_image_lifecycle_is_scoped(self):
        self.assertIn("kind load docker-image", self.probe_script)
        self.assertIn('--name "$KIND_CLUSTER_NAME"', self.probe_script)
        self.assertIn("crictl inspecti", self.probe_script)
        self.assertIn("KIND_FEASIBILITY_PROBE_IMAGE_ID", self.probe_script)
        self.assertIn("rebuild-image-candidate", self.probe_script)
        self.assertIn("identity-review-required", self.probe_script)
        self.assertIn("refusing to replace probe tag", self.probe_script)
        body = re.sub(r"cat <<'EOF'.*?\nEOF", "", self.probe_script, flags=re.S)
        for forbidden in (
            "docker system prune",
            "docker image prune",
            "docker image rm",
            "docker push",
            "systemctl enable",
            "systemctl start",
        ):
            self.assertNotIn(forbidden, body)

    def test_stream_ack_is_one_transport_message(self):
        probe_source = (
            ROOT / "containers" / "feasibility-probe" / "probe.c"
        ).read_text(encoding="utf-8")
        self.assertIn(
            'snprintf(response, sizeof(response),\n'
            '                                           "ack:%s", buffer)',
            probe_source,
        )
        self.assertIn(
            "send_all(client, response, (size_t)response_length)",
            probe_source,
        )
        self.assertNotIn('send_all(client, "ack:", 4)', probe_source)

    def test_transport_manifest_covers_required_transports(self):
        for fragment in (
            "protocol: TCP",
            "protocol: UDP",
            "protocol: SCTP",
            "port: 38412",
            "port: 8805",
            "port: 2152",
        ):
            self.assertIn(fragment, self.transport_manifest)

    def test_transport_probes_are_unprivileged_and_cluster_internal(self):
        self.assertIn("type: ClusterIP", self.transport_manifest)
        self.assertIn('drop: ["ALL"]', self.transport_manifest)
        self.assertIn("runAsNonRoot: true", self.transport_manifest)
        self.assertIn("allowPrivilegeEscalation: false", self.transport_manifest)
        self.assertIn("readOnlyRootFilesystem: true", self.transport_manifest)
        self.assertIn("automountServiceAccountToken: false", self.transport_manifest)
        for forbidden in (
            "privileged: true",
            "hostNetwork: true",
            "hostPort:",
            "type: NodePort",
            "type: LoadBalancer",
            "NET_ADMIN",
            "NET_RAW",
        ):
            self.assertNotIn(forbidden, self.transport_manifest)

    def test_tun_manifest_has_negative_and_minimum_positive_controls(self):
        self.assertIn("name: tun-denied", self.tun_manifest)
        self.assertIn("name: tun-allowed", self.tun_manifest)
        self.assertIn("path: /dev/net/tun", self.tun_manifest)
        self.assertIn("type: CharDevice", self.tun_manifest)
        self.assertIn('add: ["NET_ADMIN"]', self.tun_manifest)
        self.assertGreaterEqual(self.tun_manifest.count('drop: ["ALL"]'), 2)
        self.assertGreaterEqual(
            self.tun_manifest.count("allowPrivilegeEscalation: false"), 2
        )
        self.assertGreaterEqual(self.tun_manifest.count("privileged: false"), 2)
        for forbidden in (
            "privileged: true",
            "hostNetwork: true",
            "hostPort:",
            "NET_RAW",
        ):
            self.assertNotIn(forbidden, self.tun_manifest)

    def test_n6_manifest_models_routed_return_path_and_mtu(self):
        for fragment in (
            "10.60.0.1/24",
            "10.60.0.2/24",
            "cn5gue0",
            "cn5gupf0",
            "mtu 1400",
            "/proc/sys/net/ipv4/ip_forward",
        ):
            self.assertIn(fragment, self.n6_manifest)

    def test_n6_security_exceptions_are_narrow(self):
        self.assertIn('add: ["NET_ADMIN"]', self.n6_manifest)
        self.assertIn('add: ["NET_RAW"]', self.n6_manifest)
        self.assertEqual(self.n6_manifest.count("hostNetwork: true"), 1)
        self.assertNotIn("privileged: true", self.n6_manifest)
        self.assertNotIn("hostPort:", self.n6_manifest)
        self.assertNotIn("type: NodePort", self.n6_manifest)
        self.assertNotIn("type: LoadBalancer", self.n6_manifest)
        self.assertNotIn("sysctls:", self.n6_manifest)
        self.assertGreaterEqual(self.n6_manifest.count('drop: ["ALL"]'), 5)
        self.assertEqual(self.n6_manifest.count('add: ["NET_ADMIN"]'), 2)
        self.assertIn("runAsNonRoot: true", self.n6_manifest)

    def test_n6_node_return_route_is_scoped_and_reversible(self):
        for fragment in (
            "n6_return_subnet=10.60.0.0/24",
            "n6_return_protocol=186",
            "n6_return_metric=36060",
            "n6_router_node_interface",
            'ip -4 route show "$n6_router_ip/32"',
            'ip -N -4 route show "$n6_return_subnet"',
            'dev "$n6_router_node_interface" onlink',
            'ip -4 route add "$n6_return_subnet"',
            'ip -4 route del "$n6_return_subnet"',
            "refusing to overwrite existing kind node route",
            "refusing to remove unrecognized kind node route",
        ):
            self.assertIn(fragment, self.probe_script)


if __name__ == "__main__":
    unittest.main()
