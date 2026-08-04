#!/usr/bin/env python3
"""Static safety tests for the initial Phase 4 Helm lifecycle helper."""

from __future__ import annotations

from pathlib import Path
import json
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
        self.assertIn(
            "for required_command in docker kind kubectl helm jq sha256sum tar",
            self.script,
        )

    def test_image_load_requires_accepted_local_identities(self):
        self.assertIn("OPEN5GS_LOCAL_IMAGE_ID", self.script)
        self.assertIn("UERANSIM_LOCAL_IMAGE_ID", self.script)
        self.assertIn("DATA_NETWORK_LOCAL_IMAGE_ID", self.script)
        self.assertIn('observed_id != "$expected_id"', self.script)
        self.assertIn("kind load docker-image", self.script)
        self.assertIn("crictl inspecti", self.script)
        self.assertIn("jq -er '.status.id'", self.script)
        self.assertIn('observed_id != "$expected_id"', self.script)
        self.assertIn('docker image save "$image"', self.script)
        self.assertIn("tar -xOf - manifest.json", self.script)
        self.assertIn(".RepoTags // []", self.script)
        self.assertIn(".[0].Config", self.script)
        self.assertIn('runtime_config_id "$OPEN5GS_LOCAL_IMAGE"', self.script)
        self.assertIn(
            'runtime_config_id "$mongodb_load_reference"', self.script
        )
        self.assertIn(
            'verify_node_image "$OPEN5GS_LOCAL_IMAGE" "$open5gs_runtime_id" || return 1',
            self.script,
        )
        self.assertIn(
            "node_image_import=skipped-already-present-and-accepted",
            self.script,
        )
        self.assertIn("node_image_import=completed", self.script)
        self.assertIn("mongodb_load_reference=${MONGODB_IMAGE%@sha256:*}", self.script)
        self.assertIn("mongodb_repository=${mongodb_load_reference%:*}", self.script)
        self.assertIn(
            'mongodb_expected_repo_digest="${mongodb_repository}@${MONGODB_IMAGE##*@}"',
            self.script,
        )
        self.assertIn("mongodb_repo_digests", self.script)
        self.assertIn(
            'mongodb_repo_digests != *"$mongodb_expected_repo_digest"*',
            self.script,
        )
        self.assertIn('docker image tag "$MONGODB_IMAGE"', self.script)
        self.assertIn('if [[ $tag_id != "$digest_id" ]]', self.script)
        self.assertIn("refusing to overwrite conflicting MongoDB tag", self.script)
        self.assertIn("stage_mongodb_load_reference", self.script)
        self.assertIn(
            'verify_node_image "$mongodb_load_reference" "$mongodb_runtime_id" || return 1',
            self.script,
        )
        self.assertIn('"$DATA_NETWORK_LOCAL_IMAGE" "$mongodb_load_reference"', self.script)

    def test_mongodb_repo_digest_normalization_removes_the_tag(self):
        manifest = (ROOT / "versions" / "phase-02.env").read_text(encoding="utf-8")
        match = re.search(r"^MONGODB_IMAGE='([^']+)'$", manifest, flags=re.M)
        self.assertIsNotNone(match)
        configured_reference = match.group(1)
        tagged_reference, digest = configured_reference.rsplit("@", 1)
        repository = tagged_reference.rsplit(":", 1)[0]
        self.assertEqual(
            f"{repository}@{digest}",
            "mongo@sha256:0b9ff6be307c4860f66d9555cd951c9fa13fdb6536d9dd808c137dcdc6d888a5",
        )

    def test_archive_parser_selects_tagged_runtime_config_not_attestation(self):
        runtime_config = "e" * 64
        archive_manifest = [
            {
                "Config": f"blobs/sha256/{runtime_config}",
                "RepoTags": ["cn5g/open5gs:2.7.7"],
            },
            {
                "Config": f"blobs/sha256/{'a' * 64}",
                "RepoTags": None,
            },
        ]
        jq_filter = """
          [.[] | select(((.RepoTags // []) | length) > 0)] |
          if length == 1 then .[0].Config
          else error("expected exactly one tagged image manifest")
          end
        """
        result = subprocess.run(
            ["jq", "-er", jq_filter],
            input=json.dumps(archive_manifest),
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"blobs/sha256/{runtime_config}")

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

    def test_failed_install_recovery_is_confirmed_and_unbound_only(self):
        self.assertIn(
            'action == "recover-failed-install" && $confirmation != "--confirm"',
            self.script,
        )
        self.assertIn('release_status != "failed"', self.script)
        self.assertIn('pvc_phase != "Pending"', self.script)
        self.assertIn("-n $pvc_volume", self.script)
        self.assertIn('pvc_class != "local-path"', self.script)
        self.assertIn('pvc_instance != "cn5g"', self.script)
        self.assertIn('pvc_component != "mongodb"', self.script)
        self.assertIn('delete pvc "$pvc_name"', self.script)
        self.assertIn("--ignore-not-found --output json", self.script)
        self.assertNotIn("list --all", self.script)
        self.assertIn("state=already-absent", self.script)
        self.assertIn("for attempt in $(seq 1 60)", self.script)
        self.assertIn("failed_install_recovery=pass", self.script)

    def test_failed_release_repair_preserves_bound_mongodb_storage(self):
        self.assertIn("repair-failed-release", self.script)
        self.assertIn('release_status != "failed"', self.script)
        self.assertIn('pvc_phase != "Bound"', self.script)
        self.assertIn('pvc_class != "standard"', self.script)
        self.assertIn('repaired_pvc_uid != "$pvc_uid"', self.script)
        self.assertIn('repaired_pvc_volume != "$pvc_volume"', self.script)
        self.assertIn('next_revision=$((release_version + 1))', self.script)
        self.assertIn('rollout_token="repair-r${next_revision}"', self.script)
        self.assertEqual(
            self.script.count(
                '--reuse-values --set-string global.ranRolloutToken="$rollout_token"'
            ),
            2,
        )
        self.assertIn("server_side_upgrade_dry_run=pass", self.script)
        self.assertIn("phase04_failed_release_repair=pass", self.script)

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
