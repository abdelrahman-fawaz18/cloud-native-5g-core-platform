#!/usr/bin/env python3
"""Run the controlled, resumable Phase 8 recovery experiments."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
from typing import Any
from urllib.parse import urlencode
from urllib.request import urlopen


class RecoveryError(RuntimeError):
    """A fail-closed Phase 8 experiment error."""


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def utc_iso(timestamp: float | None = None) -> str:
    value = datetime.fromtimestamp(timestamp or time.time(), timezone.utc)
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def run(
    command: list[str], *, timeout: int = 120, check: bool = True,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command, text=True, capture_output=True, timeout=timeout, check=False
    )
    if check and completed.returncode:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RecoveryError(
            f"command failed ({completed.returncode}): {' '.join(command)}: {detail}"
        )
    return completed


class RecoveryRunner:
    def __init__(self, args: argparse.Namespace) -> None:
        self.root = args.project_root.resolve()
        self.kubeconfig = args.kubeconfig.resolve()
        self.namespace = args.namespace
        self.obs_namespace = args.observability_namespace
        self.experiment_path = args.experiment.resolve()
        self.raw_root = args.raw_root.resolve()
        self.state_path = args.state_file.resolve()
        self.mode = args.mode
        self.component = args.component
        self.experiment = json.loads(self.experiment_path.read_text(encoding="utf-8"))
        self.experiment_sha = hashlib.sha256(self.experiment_path.read_bytes()).hexdigest()
        self.uid = int(os.environ["SUDO_UID"])
        self.gid = int(os.environ["SUDO_GID"])
        self.kubectl_base = ["kubectl", "--kubeconfig", str(self.kubeconfig)]
        self.prometheus_url = "http://127.0.0.1:19098"
        self.loki_url = "http://127.0.0.1:13101"
        self.forwards: list[subprocess.Popen[str]] = []
        self.fault_injected = False
        self.baseline_restored = False
        self.current_evidence: Path | None = None

    def kubectl(
        self, *arguments: str, namespace: str | None = None,
        timeout: int = 120, check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return run(
            self.kubectl_base
            + ["--namespace", namespace or self.namespace, *arguments],
            timeout=timeout,
            check=check,
        )

    def kubectl_json(
        self, *arguments: str, namespace: str | None = None, timeout: int = 120,
    ) -> Any:
        completed = self.kubectl(
            *arguments, "--output", "json", namespace=namespace, timeout=timeout
        )
        return json.loads(completed.stdout)

    def helm_revision(self) -> int:
        output = run([
            "helm", "--kubeconfig", str(self.kubeconfig), "--namespace", self.namespace,
            "status", "cn5g", "--output", "json",
        ])
        return int(json.loads(output.stdout)["version"])

    def host_abort_gate(self) -> dict[str, int]:
        available_kib = 0
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            if line.startswith("MemAvailable:"):
                available_kib = int(line.split()[1])
                break
        available_mib = available_kib // 1024
        docker_free_mib = shutil.disk_usage("/var/lib/docker").free // 1024 // 1024
        limits = self.experiment["abort_thresholds"]
        print(
            f"host_available_memory_mib={available_mib} "
            f"abort_floor_mib={limits['host_available_memory_mib']}", flush=True,
        )
        print(
            f"docker_free_space_mib={docker_free_mib} "
            f"abort_floor_mib={limits['docker_free_space_mib']}", flush=True,
        )
        if available_mib < limits["host_available_memory_mib"]:
            raise RecoveryError("available host memory is below the abort floor")
        if docker_free_mib < limits["docker_free_space_mib"]:
            raise RecoveryError("Docker free space is below the abort floor")
        return {
            "host_available_memory_mib": available_mib,
            "docker_free_space_mib": docker_free_mib,
        }

    def workload_snapshot(self, component: str) -> dict[str, Any]:
        contract = self.experiment["faults"][component]
        deployment = self.kubectl_json("get", "deployment", contract["workload_name"])
        if deployment["spec"].get("replicas") != 1:
            raise RecoveryError(f"{component} Deployment does not have exactly one replica")
        pods = self.kubectl_json("get", "pods", "--selector", contract["selector"])
        if len(pods.get("items", [])) != 1:
            raise RecoveryError(f"{component} selector did not resolve exactly one Pod")
        pod = pods["items"][0]
        ready = any(
            item.get("type") == "Ready" and item.get("status") == "True"
            for item in pod.get("status", {}).get("conditions", [])
        )
        available = deployment.get("status", {}).get("availableReplicas", 0)
        if not ready or available != 1:
            raise RecoveryError(f"{component} is not a healthy one-replica baseline")
        return {
            "deployment": contract["workload_name"],
            "pod_name": pod["metadata"]["name"],
            "pod_uid": pod["metadata"]["uid"],
            "pod_ip": pod.get("status", {}).get("podIP"),
            "ready": ready,
            "available_replicas": available,
        }

    def mongodb_pvc_identity(self) -> dict[str, str]:
        pvc = self.kubectl_json("get", "pvc", "mongodb-data-cn5g-mongodb-0")
        return {
            "uid": pvc["metadata"]["uid"],
            "volume": pvc["spec"]["volumeName"],
        }

    def start_forward(
        self, *, service: str, mapping: str, ready_url: str, log_path: Path,
    ) -> None:
        handle = log_path.open("w", encoding="utf-8")
        command = self.kubectl_base + [
            "--namespace", self.obs_namespace, "port-forward", "--address", "127.0.0.1",
            f"service/{service}", mapping,
        ]
        process = subprocess.Popen(
            command, stdout=handle, stderr=subprocess.STDOUT, text=True
        )
        handle.close()
        self.forwards.append(process)
        for _ in range(30):
            if process.poll() is not None:
                raise RecoveryError(f"port-forward exited; inspect {log_path}")
            try:
                with urlopen(ready_url, timeout=2) as response:
                    if response.status == 200:
                        return
            except OSError:
                pass
            time.sleep(1)
        raise RecoveryError(f"port-forward did not become ready: {service}")

    def start_observability_forwards(self, evidence: Path) -> None:
        self.start_forward(
            service="cn5g-observability-prometheus", mapping="19098:9090",
            ready_url=f"{self.prometheus_url}/-/ready",
            log_path=evidence / "prometheus-port-forward.log",
        )
        self.start_forward(
            service="cn5g-observability-loki", mapping="13101:3100",
            ready_url=f"{self.loki_url}/ready",
            log_path=evidence / "loki-port-forward.log",
        )
        print("phase08_observability_forwards=ready", flush=True)

    def stop_forwards(self) -> None:
        for process in self.forwards:
            if process.poll() is not None:
                continue
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        self.forwards.clear()

    def prometheus_api_query(self, query: str) -> list[dict[str, Any]]:
        parameters = urlencode({"query": query})
        with urlopen(f"{self.prometheus_url}/api/v1/query?{parameters}", timeout=10) as response:
            payload = json.load(response)
        if payload.get("status") != "success":
            raise RecoveryError(f"Prometheus instant query failed: {query}")
        return payload.get("data", {}).get("result", [])

    def prometheus_query(
        self, query: str, *, source_timestamp_query: str,
    ) -> dict[str, Any]:
        results = self.prometheus_api_query(query)
        if not results:
            return {"present": False, "value": None, "sample_timestamp": None}
        value = results[0]["value"][1]
        timestamp_results = self.prometheus_api_query(source_timestamp_query)
        if not timestamp_results:
            return {"present": True, "value": float(value), "sample_timestamp": None}
        # timestamp(metric) returns the source sample time as the sample value.
        # The outer HTTP vector timestamp is only the query evaluation time and
        # must never be used to establish post-fault freshness.
        source_timestamp = timestamp_results[0]["value"][1]
        return {
            "present": True,
            "value": float(value),
            "sample_timestamp": float(source_timestamp),
        }

    def prometheus_range(self, query: str, start: float, end: float) -> dict[str, Any]:
        step = self.experiment["evidence"]["prometheus_step_seconds"]
        parameters = urlencode({
            "query": query, "start": f"{start:.3f}", "end": f"{end:.3f}",
            "step": str(step),
        })
        with urlopen(
            f"{self.prometheus_url}/api/v1/query_range?{parameters}", timeout=30
        ) as response:
            payload = json.load(response)
        if payload.get("status") != "success":
            raise RecoveryError(f"Prometheus range query failed: {query}")
        return payload

    def loki_range(self, start: float, end: float) -> dict[str, Any]:
        query = '{namespace="cn5g",component=~"amf|smf|upf|gnb|ue"}'
        parameters = urlencode({
            "query": query,
            "start": str(int(start * 1_000_000_000)),
            "end": str(int(end * 1_000_000_000)),
            "limit": "500",
            "direction": "forward",
        })
        with urlopen(f"{self.loki_url}/loki/api/v1/query_range?{parameters}", timeout=30) as response:
            payload = json.load(response)
        if payload.get("status") != "success":
            raise RecoveryError("Loki range query failed")
        return payload

    def current_state(self, component: str, old_uid: str, fault_time: float) -> dict[str, Any]:
        contract = self.experiment["faults"][component]
        deployment = self.kubectl_json("get", "deployment", contract["workload_name"])
        pods = self.kubectl_json("get", "pods", "--selector", contract["selector"])
        selected = []
        for pod in pods.get("items", []):
            ready = any(
                item.get("type") == "Ready" and item.get("status") == "True"
                for item in pod.get("status", {}).get("conditions", [])
            )
            selected.append({
                "name": pod["metadata"]["name"],
                "uid": pod["metadata"]["uid"],
                "ready": ready,
                "phase": pod.get("status", {}).get("phase"),
                "deleting": "deletionTimestamp" in pod["metadata"],
            })
        job = contract["prometheus_job"]
        up = self.prometheus_query(
            f'up{{job="{job}"}}',
            source_timestamp_query=f'max(timestamp(up{{job="{job}"}}))',
        )
        amf = self.prometheus_query(
            'max(amf_session{job="open5gs-amf"})',
            source_timestamp_query='max(timestamp(amf_session{job="open5gs-amf"}))',
        )
        pfcp = self.prometheus_query(
            'max(pfcp_sessions_active{job="open5gs-smf"})',
            source_timestamp_query='max(timestamp(pfcp_sessions_active{job="open5gs-smf"}))',
        )
        smf_peer = self.prometheus_query(
            'max(pfcp_peers_active{job="open5gs-smf"})',
            source_timestamp_query='max(timestamp(pfcp_peers_active{job="open5gs-smf"}))',
        )
        upf_peer = self.prometheus_query(
            'max(pfcp_peers_active{job="open5gs-upf"})',
            source_timestamp_query='max(timestamp(pfcp_peers_active{job="open5gs-upf"}))',
        )
        user_plane = self.prometheus_query(
            "sum(cn5g_ue_user_plane_probe_success)",
            source_timestamp_query="min(timestamp(cn5g_ue_user_plane_probe_success))",
        )
        new_ready = any(
            pod["uid"] != old_uid and pod["ready"] and not pod["deleting"]
            for pod in selected
        )
        fresh_up = (
            up["present"] and up["value"] == 1
            and up["sample_timestamp"] is not None
            and up["sample_timestamp"] >= fault_time
        )
        def fresh_value(sample: dict[str, Any], expected: float) -> bool:
            return bool(
                sample["present"] and sample["value"] == expected
                and sample["sample_timestamp"] is not None
                and sample["sample_timestamp"] >= fault_time
            )

        signal_values = {
            "replacement_ready": new_ready,
            "prometheus_target_up": fresh_up,
            "amf_sessions_five": fresh_value(amf, 5),
            "smf_pfcp_peer_one": fresh_value(smf_peer, 1),
            "upf_pfcp_peer_one": fresh_value(upf_peer, 1),
            "pfcp_sessions_five": fresh_value(pfcp, 5),
            "user_plane_paths_five": fresh_value(user_plane, 5),
        }
        required = contract["service_recovery_signals"]
        return {
            "timestamp": utc_iso(),
            "epoch": time.time(),
            "deployment_available_replicas": deployment.get("status", {}).get("availableReplicas", 0),
            "deployment_updated_replicas": deployment.get("status", {}).get("updatedReplicas", 0),
            "pods": selected,
            "old_pod_present": any(pod["uid"] == old_uid for pod in selected),
            "prometheus": {
                "target_up": up, "amf_sessions": amf,
                "pfcp_sessions": pfcp, "smf_pfcp_peer": smf_peer,
                "upf_pfcp_peer": upf_peer, "user_plane_paths": user_plane,
            },
            "signals": signal_values,
            "service_recovered": all(signal_values[name] for name in required),
        }

    def collect_range_evidence(
        self, evidence: Path, component: str, start: float, end: float,
    ) -> None:
        contract = self.experiment["faults"][component]
        queries = {
            "target_up": f'up{{job="{contract["prometheus_job"]}"}}',
            "deployment_available": (
                'kube_deployment_status_replicas_available{namespace="cn5g",'
                f'deployment="{contract["workload_name"]}"}}'
            ),
            "amf_sessions": 'max(amf_session{job="open5gs-amf"})',
            "pfcp_sessions": 'max(pfcp_sessions_active{job="open5gs-smf"})',
            "smf_pfcp_peer": 'max(pfcp_peers_active{job="open5gs-smf"})',
            "upf_pfcp_peer": 'max(pfcp_peers_active{job="open5gs-upf"})',
            "user_plane_paths": "sum(cn5g_ue_user_plane_probe_success)",
            "alerts": 'sum(ALERTS{alertstate="firing",service=~"cn5g.*"}) or vector(0)',
        }
        prom_dir = evidence / "prometheus"
        prom_dir.mkdir(mode=0o700, exist_ok=True)
        write_json(prom_dir / "queries.json", queries)
        for name, query in queries.items():
            write_json(prom_dir / f"{name}.json", self.prometheus_range(query, start, end))
        write_json(evidence / "loki.json", self.loki_range(start, end))
        events = self.kubectl_json("get", "events", "--sort-by=.metadata.creationTimestamp")
        write_json(evidence / "kubernetes-events.json", events)
        write_json(
            evidence / "final-pods.json",
            self.kubectl_json("get", "pods", "--selector", "app.kubernetes.io/instance=cn5g"),
        )

    def stream_process_with_samples(
        self, command: list[str], log_path: Path, component: str,
        old_uid: str, fault_time: float, timeline: list[dict[str, Any]],
    ) -> int:
        with log_path.open("w", encoding="utf-8") as handle:
            process = subprocess.Popen(
                command, stdout=handle, stderr=subprocess.STDOUT, text=True
            )
            while process.poll() is None:
                try:
                    timeline.append(self.current_state(component, old_uid, fault_time))
                except (RecoveryError, OSError, json.JSONDecodeError) as error:
                    timeline.append({
                        "timestamp": utc_iso(), "epoch": time.time(),
                        "sampling_error": str(error),
                    })
                time.sleep(self.experiment["controls"]["sample_interval_seconds"])
            return process.returncode

    def validate_to_log(self, script: str, action: str, path: Path) -> None:
        completed = run(
            [str(self.root / "scripts" / script), action], timeout=1800, check=False
        )
        path.write_text(completed.stdout + completed.stderr, encoding="utf-8")
        if completed.returncode:
            raise RecoveryError(f"{script} {action} failed; inspect {path}")

    def baseline_validation(self, evidence: Path) -> None:
        self.validate_to_log("phase05-lab.sh", "validate", evidence / "baseline-phase05.log")
        self.validate_to_log("phase06-lab.sh", "validate", evidence / "baseline-phase06.log")
        print("phase08_healthy_baseline=pass", flush=True)

    def restore_baseline(
        self, evidence: Path, component: str, old_uid: str,
        fault_time: float, timeline: list[dict[str, Any]],
    ) -> float:
        print(f"phase08_restoration=started component={component}", flush=True)
        return_code = self.stream_process_with_samples(
            [str(self.root / "scripts" / "phase05-lab.sh"), "repair-sessions"],
            evidence / "session-repair.log", component, old_uid, fault_time, timeline,
        )
        if return_code:
            raise RecoveryError("dependency-ordered session repair failed")
        self.validate_to_log("phase06-lab.sh", "validate", evidence / "restored-phase06.log")
        # Capture the validated post-repair state so an observed user-plane
        # failure always has a later recovered sample in the retained timeline.
        timeline.append(self.current_state(component, old_uid, fault_time))
        self.baseline_restored = True
        restored = time.time()
        print(f"phase08_baseline_restoration=pass component={component}", flush=True)
        return restored

    def chown_tree(self, path: Path) -> None:
        for item in [path, *path.rglob("*")]:
            os.chown(item, self.uid, self.gid, follow_symlinks=False)

    def run_attempt(self, component: str, evidence: Path, identity: dict[str, Any]) -> dict[str, Any]:
        evidence.mkdir(parents=True, mode=0o700, exist_ok=False)
        self.fault_injected = False
        self.baseline_restored = False
        self.current_evidence = evidence
        timeline: list[dict[str, Any]] = []
        start = time.time()
        self.host_abort_gate()
        self.baseline_validation(evidence)
        before = self.workload_snapshot(component)
        pvc_before = self.mongodb_pvc_identity()
        write_json(evidence / "fault-target-before.json", before)
        self.start_observability_forwards(evidence)
        # Capture one healthy point before the only intended fault.
        timeline.append(self.current_state(component, before["pod_uid"], start))
        fault_time = time.time()
        print(
            f"phase08_fault=injecting component={component} pod={before['pod_name']}",
            flush=True,
        )
        self.kubectl("delete", "pod", before["pod_name"], "--wait=false")
        self.fault_injected = True

        detection_time: float | None = None
        replacement_created_time: float | None = None
        replacement_ready_time: float | None = None
        automatic_service_recovery_time: float | None = None
        automatic_deadline = (
            time.monotonic()
            + self.experiment["controls"]["automatic_recovery_observation_seconds"]
        )
        replacement_deadline = (
            time.monotonic()
            + self.experiment["controls"]["replacement_ready_timeout_seconds"]
        )
        while time.monotonic() < replacement_deadline:
            state = self.current_state(component, before["pod_uid"], fault_time)
            timeline.append(state)
            now = state["epoch"]
            if detection_time is None and (
                not state["old_pod_present"]
                or state["deployment_available_replicas"] == 0
            ):
                detection_time = now
                print(f"phase08_detection=observed component={component}", flush=True)
            new_pods = [pod for pod in state["pods"] if pod["uid"] != before["pod_uid"]]
            if replacement_created_time is None and new_pods:
                replacement_created_time = now
            if replacement_ready_time is None and any(pod["ready"] for pod in new_pods):
                replacement_ready_time = now
                print(f"phase08_replacement=ready component={component}", flush=True)
            if state["service_recovered"] and time.monotonic() <= automatic_deadline:
                automatic_service_recovery_time = now
                print(f"phase08_automatic_service_recovery=observed component={component}", flush=True)
                break
            if time.monotonic() >= automatic_deadline and replacement_ready_time is not None:
                break
            time.sleep(self.experiment["controls"]["sample_interval_seconds"])

        if detection_time is None:
            raise RecoveryError("Kubernetes fault detection was not observed")
        if replacement_ready_time is None:
            raise RecoveryError("replacement Pod did not become Ready in the observation window")

        restoration_started = time.time()
        restored_time = self.restore_baseline(
            evidence, component, before["pod_uid"], fault_time, timeline
        )
        pvc_after = self.mongodb_pvc_identity()
        if pvc_after != pvc_before:
            raise RecoveryError("MongoDB PVC identity changed during a recovery attempt")
        final = self.workload_snapshot(component)
        end = time.time()
        self.collect_range_evidence(evidence, component, start, end)
        self.stop_forwards()
        write_json(evidence / "timeline.json", timeline)

        service_mode = "automatic" if automatic_service_recovery_time else "operator-assisted"
        service_recovery_time = automatic_service_recovery_time or restored_time
        manifest = {
            "schema_version": 1,
            "experiment_id": self.experiment["experiment_id"],
            "experiment_sha256": self.experiment_sha,
            "mode": self.mode,
            "component": component,
            "identity": identity,
            "helm_revision": self.helm_revision(),
            "result": "pass",
            "started_at": utc_iso(start),
            "fault_at": utc_iso(fault_time),
            "detected_at": utc_iso(detection_time),
            "replacement_created_at": utc_iso(replacement_created_time) if replacement_created_time else None,
            "replacement_ready_at": utc_iso(replacement_ready_time),
            "automatic_service_recovered_at": (
                utc_iso(automatic_service_recovery_time)
                if automatic_service_recovery_time else None
            ),
            "restoration_started_at": utc_iso(restoration_started),
            "baseline_restored_at": utc_iso(restored_time),
            "finished_at": utc_iso(end),
            "service_recovery_mode": service_mode,
            "timings_seconds": {
                "mttd": detection_time - fault_time,
                "replacement_ready": replacement_ready_time - fault_time,
                "automatic_service_recovery": (
                    automatic_service_recovery_time - fault_time
                    if automatic_service_recovery_time else None
                ),
                "operator_assisted_baseline_restoration": restored_time - fault_time,
                "mttr": service_recovery_time - fault_time,
            },
            "fault_target_before": before,
            "fault_target_after": final,
            "mongodb_pvc_before": pvc_before,
            "mongodb_pvc_after": pvc_after,
            "baseline_restored": True,
            "limitations": self.experiment["publication"]["required_limitations"],
        }
        write_json(evidence / "manifest.json", manifest)
        self.chown_tree(evidence)
        self.host_abort_gate()
        print(
            f"phase08_attempt=pass component={component} mode={service_mode} "
            f"mttd_seconds={manifest['timings_seconds']['mttd']:.3f} "
            f"mttr_seconds={manifest['timings_seconds']['mttr']:.3f}", flush=True,
        )
        return manifest

    def successful_pilot_exists(self, component: str, revision: int) -> bool:
        for path in sorted(self.raw_root.glob(f"*-pilot-{component}/manifest.json")):
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if (
                data.get("result") == "pass"
                and data.get("component") == component
                and data.get("experiment_sha256") == self.experiment_sha
                and data.get("helm_revision") == revision
                and data.get("baseline_restored") is True
            ):
                return True
        return False

    def run_pilot(self) -> None:
        component = self.component
        if component not in self.experiment["faults"]:
            raise RecoveryError(f"unsupported pilot component: {component}")
        revision = self.helm_revision()
        run_id = f"{utc_stamp()}-pilot-{component}"
        evidence = self.raw_root / run_id
        try:
            self.run_attempt(component, evidence, {"pilot": component})
        except BaseException as error:
            self.write_failure(evidence, component, error)
            raise
        print(f"phase08_pilot=pass component={component} raw_evidence={evidence}")

    def load_or_create_campaign(self, revision: int) -> dict[str, Any]:
        if self.state_path.exists():
            state = json.loads(self.state_path.read_text(encoding="utf-8"))
            if (
                state.get("experiment_sha256") == self.experiment_sha
                and state.get("helm_revision") == revision
                and state.get("status") == "running"
            ):
                print(f"phase08_campaign={state['campaign_id']} mode=resumed", flush=True)
                return state
            abandoned = self.state_path.with_name(
                f"phase-08-campaign-{state.get('campaign_id', 'unknown')}-abandoned.json"
            )
            self.state_path.replace(abandoned)
            print(
                f"phase08_prior_campaign=preserved-abandoned campaign={state.get('campaign_id', 'unknown')}",
                flush=True,
            )
        campaign_id = f"{utc_stamp()}-matrix"
        state = {
            "schema_version": 1,
            "campaign_id": campaign_id,
            "status": "running",
            "experiment_sha256": self.experiment_sha,
            "helm_revision": revision,
            "accepted": {},
            "created_at": utc_iso(),
        }
        write_json(self.state_path, state)
        print(f"phase08_campaign={campaign_id} mode=resumable", flush=True)
        return state

    def next_attempt_number(self, condition_dir: Path) -> int:
        numbers = []
        for path in condition_dir.glob("attempt-*"):
            try:
                numbers.append(int(path.name.split("-", 1)[1]))
            except ValueError:
                continue
        return max(numbers, default=0) + 1

    def run_matrix(self) -> None:
        revision = self.helm_revision()
        for component in self.experiment["controls"]["run_order"]:
            if not self.successful_pilot_exists(component, revision):
                raise RecoveryError(f"accepted {component} pilot evidence is absent")
        state = self.load_or_create_campaign(revision)
        campaign_dir = self.raw_root / state["campaign_id"]
        campaign_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
        repetitions = self.experiment["controls"]["repetitions"]
        for repetition in range(1, repetitions + 1):
            for component in self.experiment["controls"]["run_order"]:
                key = f"repetition-{repetition}/{component}"
                if key in state["accepted"]:
                    print(
                        f"phase08_condition=already-accepted repetition={repetition} component={component}",
                        flush=True,
                    )
                    continue
                condition_dir = campaign_dir / f"repetition-{repetition}" / component
                condition_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
                attempt_number = self.next_attempt_number(condition_dir)
                attempt_name = f"attempt-{attempt_number:03d}"
                evidence = condition_dir / attempt_name
                print(
                    f"phase08_condition=started repetition={repetition} "
                    f"component={component} attempt={attempt_name}", flush=True,
                )
                try:
                    self.run_attempt(
                        component, evidence,
                        {"repetition": repetition, "attempt": attempt_number},
                    )
                except BaseException as error:
                    self.write_failure(evidence, component, error)
                    raise
                accepted = evidence / "accepted.json"
                write_json(accepted, {
                    "result": "accepted", "component": component,
                    "repetition": repetition, "attempt": attempt_number,
                    "experiment_sha256": self.experiment_sha,
                })
                state["accepted"][key] = str(evidence.relative_to(campaign_dir))
                write_json(self.state_path, state)
                self.chown_tree(evidence)
                print(
                    f"phase08_condition=pass repetition={repetition} component={component} "
                    f"raw_evidence={evidence}", flush=True,
                )
                time.sleep(self.experiment["controls"]["cool_down_seconds"])
        state["status"] = "raw_complete"
        state["completed_at"] = utc_iso()
        write_json(self.state_path, state)
        self.chown_tree(campaign_dir)
        os.chown(self.state_path, self.uid, self.gid)
        print(f"phase08_matrix=pass campaign={state['campaign_id']} accepted=9", flush=True)

    def write_failure(self, evidence: Path, component: str, error: BaseException) -> None:
        if evidence.exists():
            write_json(evidence / "failure.json", {
                "result": "fail", "component": component,
                "timestamp": utc_iso(), "error": str(error),
                "baseline_restored": self.baseline_restored,
            })
            self.chown_tree(evidence)

    def emergency_restore(self) -> None:
        if not self.fault_injected or self.baseline_restored:
            return
        print("phase08_emergency_restoration=started", file=sys.stderr, flush=True)
        run(
            [str(self.root / "scripts" / "phase05-lab.sh"), "repair-sessions"],
            timeout=1800, check=False,
        )
        run(
            [str(self.root / "scripts" / "phase06-lab.sh"), "validate"],
            timeout=1800, check=False,
        )
        print("phase08_emergency_restoration=attempted", file=sys.stderr, flush=True)

    def execute(self) -> None:
        self.raw_root.mkdir(parents=True, mode=0o700, exist_ok=True)
        try:
            if self.mode == "pilot":
                self.run_pilot()
            else:
                self.run_matrix()
        finally:
            self.stop_forwards()
            self.emergency_restore()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--kubeconfig", type=Path, required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--observability-namespace", required=True)
    parser.add_argument("--experiment", type=Path, required=True)
    parser.add_argument("--raw-root", type=Path, required=True)
    parser.add_argument("--state-file", type=Path, required=True)
    parser.add_argument("--mode", choices=("pilot", "matrix"), required=True)
    parser.add_argument("--component", choices=("amf", "smf", "upf"))
    args = parser.parse_args()
    if args.mode == "pilot" and not args.component:
        parser.error("--component is required for pilot mode")
    if args.mode == "matrix" and args.component:
        parser.error("--component is not valid for matrix mode")
    return args


def main() -> int:
    os.umask(0o077)
    try:
        RecoveryRunner(parse_args()).execute()
    except (RecoveryError, OSError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        print(f"error: Phase 8 recovery runner stopped safely: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
