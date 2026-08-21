#!/usr/bin/env python3
"""Static safety and acceptance tests for the platform runtime helpers."""

from __future__ import annotations

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
LIFECYCLE = ROOT / "scripts" / "platform-lifecycle.sh"
VALIDATOR = ROOT / "scripts" / "validate-platform.sh"


class MultiUePlatformLifecycleStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lifecycle = LIFECYCLE.read_text(encoding="utf-8")
        cls.validator = VALIDATOR.read_text(encoding="utf-8")

    def test_scripts_are_executable_and_valid_bash(self):
        for script in (LIFECYCLE, VALIDATOR):
            with self.subTest(script=script.name):
                self.assertTrue(script.stat().st_mode & 0o111)
                result = subprocess.run(
                    ["bash", "-n", str(script)], check=False,
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_lifecycle_is_exactly_scoped_and_avoids_broad_cleanup(self):
        self.assertIn("cn5g-subscribers", self.lifecycle)
        self.assertIn("platform-upgrade.state", self.lifecycle)
        self.assertIn('node_container="${KIND_CLUSTER_NAME}-control-plane"', self.lifecycle)
        for forbidden in (
            "docker system prune", "docker network prune", "docker volume prune",
            "kubectl delete namespace", "helm uninstall", "ip route flush table main",
            "iptables -F", "nft flush", "systemctl stop", "systemctl disable",
        ):
            self.assertNotIn(forbidden, self.lifecycle)

    def test_preflight_enforces_resources_and_reproducible_inputs(self):
        for expected in (
            "6 * 1024 * 1024", "512 * 1024", "platform_resource_budget=pass",
            '"$generator" --validate-plan', '"$generator" --check',
            'helm lint "$chart" --strict --values "$profile"',
            "deterministic_platform_chart_render=pass",
        ):
            self.assertIn(expected, self.lifecycle)
        self.assertIn("(.platform.enabled // false)", self.lifecycle)
        self.assertIn("printf -v render_cleanup", self.lifecycle)
        self.assertIn('trap "$render_cleanup" EXIT', self.lifecycle)
        self.assertIn("trap - EXIT", self.lifecycle)

    def test_secret_is_file_backed_hash_verified_and_seed_is_excluded(self):
        self.assertIn('create secret generic "$secret_name"', self.lifecycle)
        self.assertIn("platform_secret_files", self.lifecycle)
        self.assertIn("sha256sum", self.lifecycle)
        self.assertIn("base64 --decode", self.lifecycle)
        self.assertNotIn("--from-literal", self.lifecycle)
        self.assertNotIn("derivation-seed.hex", self.lifecycle)
        self.assertNotIn("kubectl get secret -o yaml", self.lifecycle)

    def test_deployment_to_statefulset_transition_is_controlled(self):
        self.assertIn('scale "deployment/${release}-ue" --replicas=0', self.lifecycle)
        self.assertIn('scale "statefulset/${release}-ue" --replicas=0', self.lifecycle)
        self.assertIn("server_side_platform_upgrade_dry_run=pass", self.lifecycle)
        self.assertIn("--values \"$profile\"", self.lifecycle)
        self.assertIn("BASE_REVISION", self.lifecycle)
        self.assertIn("mongodb_pvc_identity=preserved", self.lifecycle)
        self.assertIn("controlled_platform_upgrade_resume=pre-apply", self.lifecycle)
        self.assertIn(
            "controlled_platform_upgrade_resume=post-apply-convergence",
            self.lifecycle,
        )
        self.assertIn("deployed|failed|pending-upgrade", self.lifecycle)
        self.assertIn("helm_platform_upgrade_submission=pass", self.lifecycle)
        self.assertIn("wait_for_platform_foundation", self.lifecycle)
        self.assertIn("platform_foundation_readiness=pass", self.lifecycle)
        self.assertIn("verify_ue_statefulset_ownership", self.lifecycle)
        self.assertIn("platform_ue_statefulset=quiesced", self.lifecycle)
        self.assertIn("platform_nrf_profile_convergence=pass count=9", self.lifecycle)
        self.assertIn('if [[ -n $collection ]]', self.lifecycle)
        self.assertIn('<<<"$collection"', self.lifecycle)
        self.assertNotIn('${collection:-{}}', self.lifecycle)
        self.assertIn(
            "nrf scp udr udm ausf pcf nssf upf smf amf gnb", self.lifecycle
        )
        restart_body = self.lifecycle.split("restart_session_chain()", 1)[1].split(
            "write_state()", 1
        )[0]
        self.assertLess(
            restart_body.index("scale_platform_ues 0"),
            restart_body.index("for component in"),
        )
        self.assertLess(
            restart_body.index("wait_for_platform_nrf_profiles"),
            restart_body.index("scale_platform_ues 5"),
        )
        upgrade_body = self.lifecycle.split("controlled_upgrade()", 1)[1].split(
            "verify_invalid_resource_ownership()", 1
        )[0]
        self.assertNotIn("--wait=watcher", upgrade_body)
        self.assertLess(
            upgrade_body.index("scale_platform_ues 0"),
            upgrade_body.index('wait_for_platform_foundation "$new_revision"'),
        )
        self.assertLess(
            upgrade_body.index('wait_for_platform_foundation "$new_revision"'),
            upgrade_body.index("restart_session_chain"),
        )

    def test_two_node_routes_are_owned_and_reversible(self):
        for expected in (
            '"10.60.0.0/24:46060"', '"10.61.0.0/24:46061"',
            "proto 186", "recognized_return_route", "refusing to replace",
            "remove_enterprise_return_route",
        ):
            self.assertIn(expected, self.lifecycle)
        self.assertNotIn("ip -4 route flush", self.lifecycle)

    def test_session_repair_is_scoped_and_does_not_create_a_helm_revision(self):
        self.assertIn("repair-sessions", self.lifecycle)
        repair_body = self.lifecycle.split("repair_platform_sessions()", 1)[1].split(
            "write_state()", 1
        )[0]
        self.assertIn("verify_release_deployed", repair_body)
        self.assertIn('release_platform_enabled) != "true"', repair_body)
        self.assertIn("verify_secret", repair_body)
        self.assertIn("restart_session_chain", repair_body)
        self.assertIn("reconcile_return_routes", repair_body)
        self.assertIn('"$validator"', repair_body)
        self.assertNotIn("helm upgrade", repair_body)
        self.assertNotIn("helm rollback", repair_body)
        self.assertIn("platform_session_repair=pass", repair_body)

    def test_rollback_removes_only_platform_managed_records(self):
        self.assertIn('deleteMany({"cn5g_managed.topology":"multi-ue"})', self.lifecycle)
        self.assertIn("expected four platform-only records", self.lifecycle)
        self.assertIn("expected one restored single-UE profile subscriber", self.lifecycle)
        self.assertIn("managed === 0 && total === 1", self.lifecycle)
        self.assertIn("state=already-clean", self.lifecycle)
        self.assertIn("current_subscriber_job_name", self.lifecycle)
        self.assertIn("controlled_platform_rollback_resume=post-apply", self.lifecycle)
        self.assertIn('description != "Rollback to ${BASE_REVISION}"', self.lifecycle)
        self.assertNotIn('job/${release}-subscriber-init-r${rollback_revision}', self.lifecycle)
        self.assertIn('"$script_dir/single-ue-lifecycle.sh" validate', self.lifecycle)
        self.assertNotIn("db.dropDatabase", self.lifecycle)
        self.assertNotIn("deleteMany({})", self.lifecycle)

    def test_stale_state_reset_preserves_old_cluster_lineage(self):
        for expected in (
            "reset-stale-state --confirm",
            "stale-state reset requires the deployed single-UE profile topology",
            "rollback state belongs to the current PVC and is not stale",
            "refusing stale-state reset with a matching Helm revision",
            'mv -- "$state_file" "$archive"',
            "platform_stale_state=archived",
        ):
            self.assertIn(expected, self.lifecycle)

    def test_reprovision_waiter_detects_success_failure_and_timeout(self):
        self.assertIn("wait_for_reprovision_job", self.lifecycle)
        self.assertIn("reprovision_job_completion=pass", self.lifecycle)
        self.assertIn("reprovision Job failed", self.lifecycle)
        self.assertIn("reprovision Job did not finish within 240 seconds", self.lifecycle)
        reprovision_body = self.lifecycle.split("reprovision_experiment_body()", 1)[1].split(
            "test_reprovision()", 1
        )[0]
        self.assertNotIn("wait --for=condition=Complete", reprovision_body)

    def test_resource_observation_covers_each_ue_and_both_dnn_endpoints(self):
        for expected in (
            "observe-resources", "platform_cgroup_sample",
            "platform_resource_contract", "/sys/fs/cgroup/cpu.stat",
            "/sys/fs/cgroup/memory.current", "/sys/fs/cgroup/memory.peak",
            "data-internet data-enterprise", "for ordinal in 0 1 2 3 4",
            "resource_observation_window_seconds=10",
            "resource_observation=pass scope=five-ue-two-dnn-steady-state",
        ):
            self.assertIn(expected, self.lifecycle)
        observation_body = self.lifecycle.split("observe_platform_resources()", 1)[1].split(
            "cleanup_platform_subscribers()", 1
        )[0]
        self.assertNotIn("rollout restart", observation_body)
        self.assertNotIn("scale ", observation_body)

    def test_validator_proves_five_per_ue_results_and_dnn_isolation(self):
        for expected in (
            "concurrent_ue_pods=5", "subscriber_records=pass count=5",
            "per_ue_results_begin", "for ordinal in 0 1 2 3 4",
            "Initial Registration is successful",
            "PDU Session establishment is successful",
            "ue_address_uniqueness=pass count=5",
            "fseid_uniqueness=pass up=5 cp=5",
            "stable_sbi_advertisements=pass",
            "nrf_stable_service_profiles=pass count=9",
            "pfcp_control_plane_health=pass",
            "upf_dnn_policy_routing=pass tables=1060,1061",
            "kind_node_dual_return_routes=pass",
            "cross_dnn_isolation=pass", "platform_validation=pass",
        ):
            self.assertIn(expected, self.validator)
        self.assertIn("10.60.0.*\\/24", self.validator)
        self.assertIn("10.61.0.*\\/24", self.validator)
        self.assertIn('ip -4 route get "$intended_ip" from "$ue_ip"', self.validator)
        self.assertIn("table rt_uesimtun0", self.validator)
        self.assertIn("/etc/ueransim/ue.yaml", self.validator)
        self.assertIn("runtime_imsi", self.validator)
        self.assertIn("runtime_dnn", self.validator)
        self.assertNotIn("/secret/imsi-", self.validator)
        self.assertNotIn("/secret/dnn-", self.validator)
        self.assertIn("Cannot find PFCP-Node", self.validator)
        self.assertIn("No PFCP session modification response", self.validator)

    def test_fseid_validation_uses_current_sessions_not_historical_log_rows(self):
        self.assertIn("latest_fseid_rows=", self.validator)
        self.assertIn("latest[$4] = $0", self.validator)
        self.assertIn('for ue_ip in "${observed_addresses[@]}"', self.validator)
        self.assertIn("current UPF session evidence is ambiguous", self.validator)
        self.assertIn('<<<"$latest_fseid_rows"', self.validator)

    def test_validator_checks_all_effective_capability_boundaries(self):
        self.assertIn("0000000000001000", self.validator)
        self.assertIn("0000000000003000", self.validator)
        self.assertIn("0000000000000000", self.validator)
        self.assertIn("data-internet data-enterprise", self.validator)
        self.assertNotIn("privileged=true", self.validator)

    def test_invalid_ue_test_is_non_provisioning_and_self_cleaning(self):
        for expected in (
            "test-invalid-ue", "999700000000099",
            "invalid_ue_registration=denied",
            "invalid_ue_database_side_effects=none",
            "valid_ue_readiness_during_negative_test=pass count=5",
            "cleanup_invalid_ue", '"$validator" || return 1',
        ):
            self.assertIn(expected, self.lifecycle)
        self.assertNotIn("insertOne", self.lifecycle)
        self.assertNotIn("updateOne", self.lifecycle)

    def test_public_helpers_do_not_embed_local_identity(self):
        content = self.lifecycle + self.validator
        self.assertNotIn("/home/", content)
        self.assertNotIn("fawaz", content.lower())


if __name__ == "__main__":
    unittest.main()
