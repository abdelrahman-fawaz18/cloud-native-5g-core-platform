#!/usr/bin/env python3
"""Static safety tests for the single-UE Helm lifecycle helper."""

from __future__ import annotations

from pathlib import Path
import json
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "single-ue-lifecycle.sh"


class SingleUeProfileLifecycleStaticTests(unittest.TestCase):
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

    def test_nrf_profile_count_parser_returns_one_strict_value(self):
        function = re.search(
            r"^nrf_collection_count\(\) \{\n.*?^\}",
            self.script,
            flags=re.M | re.S,
        )
        self.assertIsNotNone(function)
        harness = function.group(0) + '\nnrf_collection_count "$1"\n'
        cases = (
            ('{"_links":{"totalItemCount":9}}', "9\n"),
            ('{"_links":{}}', "0\n"),
            ('{"_links":{"totalItemCount":"9"}}', "0\n"),
            ('{"_links":{"totalItemCount":9}}}', "0\n"),
            ("", "0\n"),
        )
        for payload, expected in cases:
            with self.subTest(payload=payload):
                result = subprocess.run(
                    ["bash", "-c", harness, "nrf-count-test", payload],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_lifecycle_uses_repository_kubeconfig_and_exact_identity(self):
        self.assertIn("artifacts/kubernetes/cn5g.kubeconfig", self.script)
        self.assertIn('CN5G_HELM_RELEASE_NAME != "cn5g"', self.script)
        self.assertIn('CN5G_KUBERNETES_NAMESPACE != "cn5g"', self.script)
        self.assertIn('--name "$KIND_CLUSTER_NAME"', self.script)
        self.assertIn('--namespace "$CN5G_KUBERNETES_NAMESPACE"', self.script)
        self.assertNotIn("$HOME", self.body)
        self.assertNotIn("~/.kube", self.body)
        for command in ("docker", "kind", "kubectl", "helm", "jq", "sha256sum", "tar"):
            self.assertIn(command, self.script)

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
        manifest = (ROOT / "versions" / "compose-runtime.env").read_text(encoding="utf-8")
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
        self.assertIn("single_ue_install=pass", self.script)

    def test_failed_install_recovery_is_confirmed_and_unbound_only(self):
        self.assertIn(
            'action == "recover-failed-install" || $action == "uninstall"',
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
        repair_body = self.script.split("repair_failed_release() {", 1)[1]
        repair_body = repair_body.split("\n}\n\ncase", 1)[0]
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
        self.assertIn("helm_upgrade_submission=pass", self.script)
        self.assertNotIn("--wait=watcher", repair_body)
        self.assertIn('deployed-ue-unavailable', repair_body)
        self.assertIn("stable_sbi_advertisements=pass", self.script)
        self.assertIn("nrf_stable_service_profiles=pass", self.script)
        self.assertIn("nrf_collection_count", self.script)
        self.assertIn('count=$(nrf_collection_count "${collection:-}")', self.script)
        self.assertNotIn('${collection:-{}}', self.script)
        self.assertIn("ensure_service_discovery_convergence", self.script)
        self.assertIn("nrf_profile_count=%s state=incomplete", self.script)
        self.assertIn("service_discovery_recovery=pass", self.script)
        self.assertIn("restart_project_deployment nrf", self.script)
        self.assertIn("restart_project_deployment scp", self.script)
        self.assertIn("restart_project_deployment amf", self.script)
        self.assertIn("restart_project_deployment gnb", self.script)
        self.assertIn("restart_project_deployment ue", self.script)
        self.assertIn("verify_ue_protocol_state", self.script)
        self.assertIn("reconcile_5g_session_chain", self.script)
        self.assertIn("wait_for_upf_protocol_state", self.script)
        self.assertIn("session_chain_reconciliation=pass", self.script)
        self.assertIn("UPF state is keyed to the current SMF PFCP peer", self.script)
        session_chain = re.search(
            r"reconcile_5g_session_chain\(\) \{(.*?)\n\}",
            self.script,
            flags=re.S,
        ).group(1)
        ordered_steps = (
            "restart_project_deployment upf",
            "restart_project_deployment smf",
            "verify_nrf_profiles",
            "restart_project_deployment gnb",
            "restart_project_deployment ue",
            "verify_ue_protocol_state",
            "wait_for_upf_protocol_state",
        )
        positions = [session_chain.index(step) for step in ordered_steps]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("helm_release_status=deployed", self.script)
        self.assertIn("single_ue_failed_release_repair=pass", self.script)

    def test_preflight_reuses_accepted_cluster_safety_and_static_gates(self):
        self.assertIn('cluster-lifecycle.sh" preflight', self.script)
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
            "sudo ip route",
            "ip route replace",
            "systemctl stop",
            "systemctl disable",
            "apt-get",
            "privileged: true",
        ):
            self.assertNotIn(forbidden, self.body)

    def test_single_ue_lifecycle_actions_are_scoped_and_stateful(self):
        for action in (
            "validate", "observe-resources", "test-persistence", "upgrade", "rollback",
            "uninstall", "verify-reinstall",
        ):
            self.assertIn(action, self.script)
        self.assertIn("artifacts/kubernetes/single-ue-upgrade.state", self.script)
        self.assertIn("artifacts/kubernetes/single-ue-uninstall.state", self.script)
        self.assertIn("CN5G_N6_RETURN_PROTOCOL", self.script)
        self.assertIn("CN5G_N6_RETURN_METRIC", self.script)
        self.assertIn('docker exec "$node_container" ip -4 route add', self.script)
        self.assertIn('docker exec "$node_container" ip -4 route del', self.script)
        self.assertIn("refusing to replace an unrecognized kind-node route", self.script)
        self.assertIn("refusing to remove an unrecognized kind-node route", self.script)
        self.assertNotIn("ip netns", self.script)

    def test_resource_observation_is_read_only_and_compares_contracts(self):
        self.assertIn("component_cgroup_sample", self.script)
        self.assertIn("component_resource_contract", self.script)
        self.assertIn("observe_runtime_resources", self.script)
        self.assertIn("/sys/fs/cgroup/cpu.stat", self.script)
        self.assertIn("/sys/fs/cgroup/memory.current", self.script)
        self.assertIn("/sys/fs/cgroup/memory.peak", self.script)
        self.assertIn("resource_observation_window_seconds=10", self.script)
        self.assertIn("cpu_average_millicores", self.script)
        self.assertIn("request_cpu=", self.script)
        self.assertIn("limit_memory=", self.script)
        self.assertIn(
            "resource_observation=pass scope=single-ue-steady-state",
            self.script,
        )

    def test_validation_repairs_only_stale_upf_session_evidence(self):
        self.assertIn(
            "run_kubernetes_validation_with_session_repair", self.script
        )
        self.assertIn(
            "error: UPF PFCP/GTP-U session evidence is incomplete",
            self.script,
        )
        self.assertIn(
            "single_ue_session_evidence=stale repair=targeted-session-chain-reconciliation",
            self.script,
        )
        self.assertIn("single_ue_session_evidence_repair=pass", self.script)

    def test_persistence_upgrade_rollback_and_uninstall_have_identity_gates(self):
        self.assertIn("cn5g_single_ue_evidence", self.script)
        self.assertIn("mongodb_pod_recreation_persistence=pass", self.script)
        self.assertIn("single_ue_upgrade=pass", self.script)
        self.assertIn("single_ue_rollback=pass", self.script)
        self.assertIn("single_ue_uninstall=pass", self.script)
        self.assertIn("helm_reinstall_persistence=pass", self.script)
        self.assertIn('helm rollback "$CN5G_HELM_RELEASE_NAME"', self.script)
        self.assertIn('helm uninstall "$CN5G_HELM_RELEASE_NAME"', self.script)
        self.assertIn("mongodb_pvc_identity=preserved", self.script)
        self.assertIn("mongodb_pvc=retained-bound", self.script)
        self.assertIn("subscriber_secret=retained-project-owned", self.script)
        self.assertIn("remove_completed_historical_subscriber_jobs", self.script)
        self.assertIn("historical_subscriber_jobs_removed=", self.script)
        self.assertIn("completed Helm ownership contract", self.script)
        self.assertIn('meta.helm.sh/release-name', self.script)
        self.assertIn('meta.helm.sh/release-namespace', self.script)
        self.assertIn("scoped_uninstall_resume=pre-release-removal", self.script)
        self.assertIn("scoped_uninstall_resume=post-release-removal", self.script)
        self.assertIn("saved uninstall state does not match retained resources", self.script)
        self.assertIn('converge_deployed_release "$installed_revision"', self.script)
        self.assertIn("controlled_upgrade_resume=failed-revision-", self.script)
        self.assertIn("controlled_upgrade_resume=pre-apply-retry", self.script)
        self.assertIn("controlled_upgrade_resume=post-apply-validation", self.script)
        self.assertIn("replace_lifecycle_state", self.script)
        self.assertIn("migrate_recreate_strategies", self.script)
        self.assertIn('"op":"remove","path":"/spec/strategy/rollingUpdate"', self.script)
        self.assertIn('"op":"replace","path":"/spec/strategy/type","value":"Recreate"', self.script)
        self.assertIn("strategy_migration=rolling-update-to-recreate", self.script)
        self.assertIn("deployment_strategy_migration=pass", self.script)
        self.assertIn('--dry-run=server --output json', self.script)
        self.assertIn("server-side strategy migration preview failed", self.script)
        self.assertIn("migrate_rolling_update_strategies", self.script)
        self.assertIn("rollback_strategy_migration=pass", self.script)
        self.assertIn("rollback_strategy=recreate-to-rolling-update", self.script)
        self.assertIn("server-side rollback strategy preview failed", self.script)
        self.assertIn("server_side_rollback_dry_run=pass", self.script)
        self.assertIn("--dry-run=server >/dev/null", self.script)
        self.assertIn("expected_rollback_revision", self.script)
        self.assertIn("controlled_rollback_resume=pre-apply", self.script)
        self.assertIn(
            "controlled_rollback_resume=post-apply-validation", self.script
        )
        self.assertIn("controlled_rollback_resume=failed-revision-", self.script)
        self.assertIn('converge_deployed_release "$baseline_revision"', self.script)

    def test_public_script_does_not_embed_local_identity(self):
        self.assertNotIn("/home/", self.script)
        self.assertNotIn("fawaz", self.script.lower())


if __name__ == "__main__":
    unittest.main()
