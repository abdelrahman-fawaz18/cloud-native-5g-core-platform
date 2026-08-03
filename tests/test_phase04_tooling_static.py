#!/usr/bin/env python3
"""Static safety and version-contract tests for Phase 4 Helm tooling."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
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


class Phase04ToolingStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = parse_env(ROOT / "versions" / "phase-04.env")
        cls.installer_path = ROOT / "scripts" / "install-helm.sh"
        cls.installer = cls.installer_path.read_text(encoding="utf-8")

    def test_helm_inputs_are_exact_and_integrity_checked(self):
        self.assertEqual(self.manifest["HELM_VERSION"], "4.2.0")
        self.assertEqual(self.manifest["HELM_GIT_COMMIT"], "0646808")
        self.assertEqual(self.manifest["PHASE_04_STATUS"], "candidate")
        for key in (
            "HELM_LINUX_AMD64_ARCHIVE_SHA256",
            "HELM_LINUX_AMD64_BINARY_SHA256",
        ):
            self.assertRegex(self.manifest[key], r"^[0-9a-f]{64}$")
        self.assertEqual(
            self.manifest["HELM_DOWNLOAD_URL"],
            "https://get.helm.sh/helm-v4.2.0-linux-amd64.tar.gz",
        )
        self.assertNotIn("latest", self.manifest["HELM_DOWNLOAD_URL"])
        self.assertIn("sha256sum --check --status", self.installer)

    def test_release_ownership_names_are_explicit(self):
        self.assertEqual(self.manifest["CN5G_HELM_RELEASE_NAME"], "cn5g")
        self.assertEqual(self.manifest["CN5G_KUBERNETES_NAMESPACE"], "cn5g")
        self.assertRegex(
            self.manifest["CN5G_CHART_VERSION"], r"^\d+\.\d+\.\d+$"
        )

    def test_installer_is_valid_bash(self):
        result = subprocess.run(
            ["bash", "-n", str(self.installer_path)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_installer_refuses_unrecognized_existing_binaries(self):
        self.assertIn("refusing to replace unrecognized", self.installer)
        self.assertIn("unmanaged path", self.installer)
        self.assertIn("present-and-pinned", self.installer)
        self.assertIn("HELM_LINUX_AMD64_BINARY_SHA256", self.installer)

    def test_installer_has_no_cluster_service_or_package_side_effects(self):
        body = re.sub(r"cat <<'EOF'.*?\nEOF", "", self.installer, flags=re.S)
        for forbidden in (
            "kind create cluster",
            "kubectl",
            "helm install",
            "helm upgrade",
            "systemctl enable",
            "systemctl start",
            "apt-get",
            "usermod",
            "iptables",
            "ip route",
        ):
            self.assertNotIn(forbidden, body)

    def test_installer_uses_scoped_temporary_extraction(self):
        self.assertIn("temporary_dir=$(mktemp -d)", self.installer)
        self.assertIn('rm -rf -- "$temporary_dir"', self.installer)
        self.assertIn("linux-amd64/helm", self.installer)
        self.assertIn("--no-same-owner", self.installer)
        self.assertIn("-o root -g root -m 0755", self.installer)

    def test_public_tooling_does_not_embed_local_identity(self):
        for content in (self.installer, (ROOT / "versions" / "phase-04.env").read_text()):
            self.assertNotIn("/home/", content)
            self.assertNotIn("fawaz", content.lower())


if __name__ == "__main__":
    unittest.main()
