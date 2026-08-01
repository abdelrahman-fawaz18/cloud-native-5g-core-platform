#!/usr/bin/env python3
"""Static safety and cross-component contract tests for the Phase 2 baseline."""

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


class Phase02StaticTests(unittest.TestCase):
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

    def test_lifecycle_avoids_broad_prune_commands(self):
        scripts = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (ROOT / "scripts").glob("*.sh")
        )
        self.assertNotIn("docker system prune", scripts)
        self.assertNotIn("docker volume prune", scripts)
        self.assertNotIn("docker network prune", scripts)


if __name__ == "__main__":
    unittest.main()

