#!/usr/bin/env python3
"""Static safety and cross-component contract tests for the Compose reference baseline."""

from __future__ import annotations

import importlib.util
import ipaddress
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def load_subnet_module():
    path = ROOT / "tools" / "check_compose_subnets.py"
    spec = importlib.util.spec_from_file_location("check_compose_subnets", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ComposeReferenceStaticTests(unittest.TestCase):
    def test_private_material_is_not_allowed_into_build_context(self):
        dockerignore = (ROOT / ".dockerignore").read_text(encoding="utf-8")
        lines = {
            line.strip()
            for line in dockerignore.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        self.assertIn("**", lines)
        self.assertFalse(any("migration" in line for line in lines if line.startswith("!")))
        self.assertFalse(any("AGENTS.md" in line for line in lines if line.startswith("!")))
        self.assertFalse(any("artifacts" in line for line in lines if line.startswith("!")))
        self.assertIn("!containers/ueransim/rt_tables", lines)

    def test_compose_has_no_host_port_publication_or_privileged_mode(self):
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        self.assertNotIn("\n    ports:", compose)
        self.assertNotIn("privileged:", compose)
        self.assertIn("- NET_ADMIN", compose)
        self.assertIn("/dev/net/tun:/dev/net/tun", compose)

    def test_synthetic_identity_contract_matches(self):
        ue = (ROOT / "configs/compose/ueransim/ue.yaml").read_text(encoding="utf-8")
        subscriber = (
            ROOT / "configs/compose/mongodb/subscriber-init.js"
        ).read_text(encoding="utf-8")
        for value in (
            "999700000000001",
            "465B5CE8B199B49FAA5F0A2EE238A6BC",
            "E8ED289DEBA952E4283B54E88E6183CA",
            "internet",
        ):
            self.assertIn(value, ue)
            self.assertIn(value, subscriber)

    def test_network_contract_is_consistent(self):
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        smf = (ROOT / "configs/compose/open5gs/smf.yaml").read_text(encoding="utf-8")
        upf = (ROOT / "configs/compose/open5gs/upf.yaml").read_text(encoding="utf-8")
        endpoint = (
            ROOT / "containers/data-network/entrypoint.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("172.28.0.0/24", compose)
        self.assertIn("10.62.0.0/24", compose)
        self.assertIn("10.60.0.0/24", smf)
        self.assertIn("10.60.0.0/24", upf)
        self.assertIn("10.60.0.0/24 via 10.62.0.2", endpoint)
        self.assertIn("  dns:\n    - 8.8.8.8\n    - 8.8.4.4", smf)

    def test_open5gs_build_has_upstream_fetch_tool(self):
        dockerfile = (
            ROOT / "containers/open5gs/Dockerfile"
        ).read_text(encoding="utf-8")
        self.assertIn("        git \\\n", dockerfile)
        self.assertIn(" AS build\n", dockerfile)
        self.assertIn(" AS runtime\n", dockerfile)

    def test_open5gs_health_checks_listener_without_sbi_requests(self):
        healthcheck = (
            ROOT / "containers/open5gs/healthcheck.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('ss -H -t -l -n | grep -Fq "${address}:7777"', healthcheck)
        self.assertNotIn("curl ", healthcheck)

    def test_required_amf_registration_timer_is_explicit(self):
        amf = (
            ROOT / "configs/compose/open5gs/amf.yaml"
        ).read_text(encoding="utf-8")
        self.assertIn("  time:\n    t3512:\n      value: 540", amf)

    def test_mongodb_startup_and_init_volume_boundaries(self):
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        for capability in ("CHOWN", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"):
            self.assertIn(f"      - {capability}", compose)
        self.assertIn("    user: \"999:999\"", compose)
        self.assertIn("    entrypoint:\n      - mongosh", compose)
        self.assertIn("      - /data/db:uid=999,gid=999,mode=0700", compose)
        self.assertIn("      - /data/configdb:uid=999,gid=999,mode=0700", compose)

    def test_runtime_dependencies_and_identity_drop_are_explicit(self):
        dockerfile = (
            ROOT / "containers/open5gs/Dockerfile"
        ).read_text(encoding="utf-8")
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        endpoint_start = compose.index("  data-network:")
        endpoint_end = compose.index("\n  gnb:", endpoint_start)
        endpoint = compose[endpoint_start:endpoint_end]
        self.assertIn("        libidn12 \\\n", dockerfile)
        for capability in ("NET_ADMIN", "SETGID", "SETUID"):
            self.assertIn(f"      - {capability}", endpoint)

    def test_data_endpoint_invokes_busybox_http_server_explicitly(self):
        dockerfile = (
            ROOT / "containers/data-network/Dockerfile"
        ).read_text(encoding="utf-8")
        entrypoint = (
            ROOT / "containers/data-network/entrypoint.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("busybox-extras=1.37.0-r20", dockerfile)
        self.assertIn(
            "exec su-exec 65532:65532 /bin/busybox-extras httpd ", entrypoint
        )

    def test_ueransim_protocol_evidence_reaches_healthcheck_and_logs(self):
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        dockerfile = (
            ROOT / "containers/ueransim/Dockerfile"
        ).read_text(encoding="utf-8")
        entrypoint = (
            ROOT / "containers/ueransim/entrypoint.sh"
        ).read_text(encoding="utf-8")
        healthcheck = (
            ROOT / "containers/ueransim/healthcheck.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('log_file="/opt/ueransim/logs/$component.log"', entrypoint)
        self.assertIn('/usr/bin/tee "$3"', entrypoint)
        self.assertIn("COPY --chmod=0444 containers/ueransim/rt_tables", dockerfile)
        self.assertIn("      - /etc/iproute2:mode=0755", compose)
        self.assertIn(
            "cp /opt/ueransim/rt_tables /etc/iproute2/rt_tables",
            entrypoint,
        )
        self.assertIn("chmod 0644 /etc/iproute2/rt_tables", entrypoint)
        self.assertIn("NG Setup procedure is successful", healthcheck)
        self.assertIn("PDU Session establishment is successful", healthcheck)
        self.assertIn("Connection setup for PDU session.*is successful", healthcheck)
        self.assertIn("lookup rt_uesimtun0", healthcheck)
        self.assertIn("default dev uesimtun0", healthcheck)

    def test_subnet_overlap_detector(self):
        module = load_subnet_module()
        candidates = (ipaddress.ip_network("172.28.0.0/24"),)
        self.assertEqual(module.find_conflicts(candidates, []), [])
        conflicts = module.find_conflicts(
            candidates,
            [(ipaddress.ip_network("172.28.0.0/16"), "existing test network")],
        )
        self.assertEqual(len(conflicts), 1)
        self.assertIn("overlaps", conflicts[0])

    def test_runtime_validation_records_bidirectional_tunnel_counters(self):
        validator = (
            ROOT / "scripts/validate-compose-reference.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("/sys/class/net/ogstun/statistics/rx_packets", validator)
        self.assertIn("/sys/class/net/ogstun/statistics/tx_packets", validator)
        self.assertIn('if [ "$upf_rx_delta" -le 0 ]', validator)
        self.assertIn('|| [ "$upf_tx_delta" -le 0 ]', validator)
        self.assertIn("bidirectional_tunnel_counters=pass", validator)

    def test_lifecycle_avoids_broad_prune_commands(self):
        scripts = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (ROOT / "scripts").glob("*.sh")
        )
        self.assertNotIn("docker system prune", scripts)
        self.assertNotIn("docker volume prune", scripts)
        self.assertNotIn("docker network prune", scripts)

    def test_build_preflight_protects_host_and_disk(self):
        lifecycle = (ROOT / "scripts/compose-reference.sh").read_text(encoding="utf-8")
        self.assertIn("host_reference_services=active", lifecycle)
        self.assertIn("host_ran_or_simulation_processes=none", lifecycle)
        self.assertIn("minimum_kib=$((12 * 1024 * 1024))", lifecycle)
        self.assertIn("project_image_tag_conflicts=none", lifecycle)
        self.assertIn("owner_url", lifecycle)
        self.assertIn("owner_source", lifecycle)
        self.assertIn('label=com.docker.compose.project="$project"', lifecycle)
        self.assertIn('"/proc/$container_pid/ns/pid"', lifecycle)
        self.assertIn('"/proc/$process_pid/ns/pid"', lifecycle)
        self.assertIn('grep -Fqx "$process_namespace"', lifecycle)

    def test_project_images_have_project_ownership_url(self):
        expected = (
            'org.opencontainers.image.url="https://github.com/'
            'abdelrahman-fawaz18/cloud-native-5g-core-platform"'
        )
        for path in (
            ROOT / "containers/open5gs/Dockerfile",
            ROOT / "containers/ueransim/Dockerfile",
            ROOT / "containers/data-network/Dockerfile",
        ):
            self.assertIn(expected, path.read_text(encoding="utf-8"), str(path))

    def test_each_project_image_has_one_canonical_compose_build(self):
        compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
        self.assertEqual(compose.count("dockerfile: containers/open5gs/Dockerfile"), 1)
        self.assertEqual(compose.count("dockerfile: containers/ueransim/Dockerfile"), 1)
        self.assertEqual(compose.count("dockerfile: containers/data-network/Dockerfile"), 1)

    def test_image_verification_is_read_only_and_scoped(self):
        lifecycle = (ROOT / "scripts/compose-reference.sh").read_text(encoding="utf-8")
        self.assertIn("verify-images", lifecycle)
        self.assertIn("image_verification=pass", lifecycle)
        self.assertIn("project_containers=none", lifecycle)
        self.assertIn("project_networks=none", lifecycle)
        self.assertIn("project_volumes=none", lifecycle)

    def test_down_verification_preserves_only_named_database_volumes(self):
        lifecycle = (ROOT / "scripts/compose-reference.sh").read_text(encoding="utf-8")
        self.assertIn("verify-down", lifecycle)
        self.assertIn("project container remains after down", lifecycle)
        self.assertIn("project network remains after down", lifecycle)
        self.assertIn("cn5g-compose_mongodb-config", lifecycle)
        self.assertIn("cn5g-compose_mongodb-data", lifecycle)
        self.assertIn("scoped_down_verification=pass", lifecycle)

    def test_recreation_test_uses_and_removes_only_synthetic_evidence(self):
        lifecycle = (ROOT / "scripts/compose-reference.sh").read_text(encoding="utf-8")
        self.assertIn("prepare-persistence", lifecycle)
        self.assertIn("verify-persistence", lifecycle)
        self.assertIn("compose_reference-compose-recreation", lifecycle)
        self.assertIn("synthetic-persistence-evidence", lifecycle)
        self.assertIn("db.cn5g_lifecycle_evidence.drop()", lifecycle)
        self.assertIn("persistence_verification=pass", lifecycle)


if __name__ == "__main__":
    unittest.main()
