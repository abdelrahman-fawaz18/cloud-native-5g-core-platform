#!/usr/bin/env python3
"""Run the bounded, resumable Phase 7 concurrency experiment."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
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


class CampaignError(RuntimeError):
    """A fail-closed experiment error."""


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def utc_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def run(command: list[str], *, timeout: int = 120, check: bool = True) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command, text=True, capture_output=True, timeout=timeout, check=False
    )
    if check and completed.returncode:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise CampaignError(f"command failed ({completed.returncode}): {' '.join(command)}: {detail}")
    return completed


class MatrixRunner:
    def __init__(self, args: argparse.Namespace) -> None:
        self.root = args.project_root.resolve()
        self.kubeconfig = args.kubeconfig.resolve()
        self.namespace = args.namespace
        self.obs_namespace = args.observability_namespace
        self.experiment_path = args.experiment.resolve()
        self.raw_root = args.raw_root.resolve()
        self.state_path = args.state_file.resolve()
        self.experiment = json.loads(self.experiment_path.read_text(encoding="utf-8"))
        self.experiment_sha = hashlib.sha256(self.experiment_path.read_bytes()).hexdigest()
        self.uid = int(os.environ["SUDO_UID"])
        self.gid = int(os.environ["SUDO_GID"])
        self.kubectl_base = ["kubectl", "--kubeconfig", str(self.kubeconfig)]
        self.prometheus_url = "http://127.0.0.1:19097"
        self.forward: subprocess.Popen[str] | None = None
        self.campaign_dir: Path | None = None

    def kubectl(self, *arguments: str, namespace: str | None = None,
                timeout: int = 120, check: bool = True) -> subprocess.CompletedProcess[str]:
        command = self.kubectl_base + ["--namespace", namespace or self.namespace, *arguments]
        return run(command, timeout=timeout, check=check)

    def kubectl_json(self, *arguments: str, namespace: str | None = None,
                     timeout: int = 120) -> Any:
        completed = self.kubectl(*arguments, "--output", "json", namespace=namespace, timeout=timeout)
        return json.loads(completed.stdout)

    def host_abort_gate(self) -> dict[str, int]:
        available_kib = 0
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            if line.startswith("MemAvailable:"):
                available_kib = int(line.split()[1])
                break
        docker_free_kib = shutil.disk_usage("/var/lib/docker").free // 1024
        available_mib = available_kib // 1024
        docker_free_mib = docker_free_kib // 1024
        print(f"host_available_memory_mib={available_mib} abort_floor_mib=3072", flush=True)
        print(f"docker_free_space_mib={docker_free_mib} abort_floor_mib=6144", flush=True)
        if available_mib < 3072:
            raise CampaignError("available host memory is below the 3072 MiB abort floor")
        if docker_free_mib < 6144:
            raise CampaignError("Docker free space is below the 6144 MiB abort floor")
        return {"host_available_memory_mib": available_mib, "docker_free_space_mib": docker_free_mib}

    def wait_for_ues(self, expected: int, timeout_seconds: int = 600) -> None:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            item = self.kubectl_json("get", "statefulset", "cn5g-ue")
            spec = item["spec"].get("replicas", 0)
            status = item.get("status", {})
            converged = (
                spec == expected
                and status.get("observedGeneration", 0) >= item["metadata"]["generation"]
                and status.get("replicas", 0) == expected
                and status.get("currentReplicas", 0) == expected
                and status.get("updatedReplicas", 0) == expected
                and status.get("readyReplicas", 0) == expected
                and status.get("currentRevision") == status.get("updateRevision")
            )
            if converged:
                print(f"phase07_ue_statefulset=converged replicas={expected}", flush=True)
                return
            time.sleep(2)
        raise CampaignError(f"UE StatefulSet did not converge to {expected} replicas")

    def scale_ues(self, replicas: int) -> None:
        self.kubectl("scale", "statefulset", "cn5g-ue", f"--replicas={replicas}")
        self.wait_for_ues(replicas)

    def restore_five(self) -> None:
        self.scale_ues(5)

    def stream_command(self, command: list[str], log_path: Path) -> None:
        with log_path.open("w", encoding="utf-8") as log:
            process = subprocess.Popen(
                command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
            )
            assert process.stdout is not None
            for line in process.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                log.write(line)
                log.flush()
            return_code = process.wait()
        if return_code:
            raise CampaignError(
                f"session reset command failed ({return_code}); inspect {log_path}"
            )

    def reset_condition_state(self, evidence_dir: Path, label: str) -> None:
        log_path = evidence_dir / "session-reset.log"
        print(f"phase07_condition_reset=started condition={label}", flush=True)
        # A DNN Deployment restart changes its Pod address. The UPF resolves
        # that address while starting and installs it as the only permitted
        # /32 in the corresponding fail-closed policy table. Restart the DNN
        # servers first, then rebuild the session chain so tables 1060/1061
        # contain the current endpoints rather than stale Pod addresses.
        for component in ("data-internet", "data-enterprise"):
            self.kubectl("rollout", "restart", f"deployment/cn5g-{component}")
            self.kubectl(
                "rollout", "status", f"deployment/cn5g-{component}", "--timeout=300s",
                timeout=330,
            )
        self.stream_command(
            [str(self.root / "scripts/phase05-lab.sh"), "repair-sessions"], log_path
        )
        self.chown_tree(evidence_dir)
        print(
            f"phase07_condition_reset=pass condition={label} "
            "session_chain=clean benchmark_servers=clean",
            flush=True,
        )

    def endpoint_ip(self, dnn: str) -> str:
        data = self.kubectl_json(
            "get", "endpointslice", "--selector",
            f"kubernetes.io/service-name=cn5g-data-{dnn}",
        )
        for item in data.get("items", []):
            for endpoint in item.get("endpoints", []):
                if endpoint.get("conditions", {}).get("ready", True):
                    addresses = endpoint.get("addresses", [])
                    if addresses:
                        return addresses[0]
        raise CampaignError(f"no Ready endpoint exists for DNN {dnn}")

    def ue_ip(self, ordinal: int) -> str:
        completed = self.kubectl(
            "exec", f"cn5g-ue-{ordinal}", "-c", "benchmark-client", "--",
            "ip", "-o", "-4", "address", "show", "dev", "uesimtun0",
        )
        fields = completed.stdout.split()
        if len(fields) < 4:
            raise CampaignError(f"UE {ordinal} has no uesimtun0 IPv4 address")
        return fields[3].split("/", 1)[0]

    def enforce_route(self, ordinal: int, ue_ip: str, endpoint_ip: str) -> tuple[str, str]:
        route = self.kubectl(
            "exec", f"cn5g-ue-{ordinal}", "-c", "benchmark-client", "--",
            "ip", "-4", "route", "get", endpoint_ip, "from", ue_ip,
        ).stdout.strip()
        policy = self.kubectl(
            "exec", f"cn5g-ue-{ordinal}", "-c", "benchmark-client", "--",
            "ip", "-4", "rule", "show",
        ).stdout.strip()
        if f"from {ue_ip} dev uesimtun0 table 1000" not in route:
            raise CampaignError(f"UE {ordinal} benchmark route bypasses uesimtun0")
        if f"from {ue_ip} lookup 1000" not in policy:
            raise CampaignError(f"UE {ordinal} source-policy rule is absent")
        return route, policy

    def pod_runtime_snapshot(self) -> dict[str, Any]:
        data = self.kubectl_json(
            "get", "pods", "--selector", "app.kubernetes.io/instance=cn5g"
        )
        snapshot: dict[str, Any] = {}
        for pod in data.get("items", []):
            if pod.get("status", {}).get("phase") != "Running":
                continue
            pod_name = pod["metadata"]["name"]
            for status in pod.get("status", {}).get("containerStatuses", []):
                key = f"{pod_name}/{status['name']}"
                last_reason = (
                    status.get("lastState", {}).get("terminated", {}).get("reason", "")
                )
                current_reason = (
                    status.get("state", {}).get("terminated", {}).get("reason", "")
                )
                snapshot[key] = {
                    "restart_count": status.get("restartCount", 0),
                    "last_termination_reason": last_reason,
                    "current_termination_reason": current_reason,
                    "ready": status.get("ready", False),
                }
        return snapshot

    @staticmethod
    def compare_runtime(before: dict[str, Any], after: dict[str, Any]) -> None:
        if set(before) != set(after):
            raise CampaignError("Pod/container identity changed during a measurement condition")
        for key in before:
            if after[key]["restart_count"] != before[key]["restart_count"]:
                raise CampaignError(f"container restart count changed during measurement: {key}")
            if "OOMKilled" in (
                after[key]["last_termination_reason"], after[key]["current_termination_reason"]
            ):
                raise CampaignError(f"OOM kill evidence is present: {key}")
            if not after[key]["ready"]:
                raise CampaignError(f"container became NotReady during measurement: {key}")

    def start_prometheus_forward(self) -> None:
        log_path = self.campaign_dir / "prometheus-port-forward.log"  # type: ignore[operator]
        log_handle = log_path.open("w", encoding="utf-8")
        command = self.kubectl_base + [
            "--namespace", self.obs_namespace, "port-forward", "--address", "127.0.0.1",
            "service/cn5g-observability-prometheus", "19097:9090",
        ]
        self.forward = subprocess.Popen(command, stdout=log_handle, stderr=subprocess.STDOUT, text=True)
        log_handle.close()
        for _ in range(30):
            if self.forward.poll() is not None:
                raise CampaignError(f"Prometheus port-forward exited; inspect {log_path}")
            try:
                with urlopen(f"{self.prometheus_url}/-/ready", timeout=2) as response:
                    if response.status == 200:
                        print("phase07_prometheus_forward=ready", flush=True)
                        return
            except OSError:
                pass
            time.sleep(1)
        raise CampaignError("Prometheus port-forward did not become ready")

    def stop_prometheus_forward(self) -> None:
        if self.forward is None or self.forward.poll() is not None:
            return
        self.forward.send_signal(signal.SIGTERM)
        try:
            self.forward.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.forward.kill()
            self.forward.wait(timeout=5)

    def prometheus_query_range(self, query: str, start: float, end: float) -> Any:
        parameters = urlencode({"query": query, "start": f"{start:.3f}", "end": f"{end:.3f}", "step": "5s"})
        with urlopen(f"{self.prometheus_url}/api/v1/query_range?{parameters}", timeout=30) as response:
            result = json.load(response)
        if result.get("status") != "success":
            raise CampaignError(f"Prometheus range query failed: {query}")
        return result

    def collect_prometheus(self, directory: Path, start: float, end: float) -> None:
        queries = {
            "cpu": 'sum by (pod,container) (rate(container_cpu_usage_seconds_total{namespace="cn5g",container=~"amf|smf|upf|gnb|ue|data-network|benchmark-client|benchmark-server"}[1m]))',
            "memory": 'sum by (pod,container) (container_memory_working_set_bytes{namespace="cn5g",container=~"amf|smf|upf|gnb|ue|data-network|benchmark-client|benchmark-server"})',
            "restarts": 'sum by (pod,container) (kube_pod_container_status_restarts_total{namespace="cn5g"})',
            "network_receive": 'sum by (pod) (rate(container_network_receive_bytes_total{namespace="cn5g",pod=~"cn5g-(ue|amf|smf|upf|gnb|data-internet|data-enterprise).*"}[1m]))',
            "network_transmit": 'sum by (pod) (rate(container_network_transmit_bytes_total{namespace="cn5g",pod=~"cn5g-(ue|amf|smf|upf|gnb|data-internet|data-enterprise).*"}[1m]))',
            "amf_sessions": "max(amf_session)",
            "pfcp_sessions": "max(pfcp_sessions_active)",
        }
        query_dir = directory / "prometheus"
        query_dir.mkdir(parents=True, exist_ok=True)
        write_json(query_dir / "queries.json", queries)
        for name, query in queries.items():
            result = self.prometheus_query_range(query, start, end)
            if not result.get("data", {}).get("result"):
                raise CampaignError(f"Prometheus returned no samples for required query: {name}")
            write_json(query_dir / f"{name}.json", result)

    def concurrent_commands(self, jobs: dict[int, list[str]], directory: Path,
                            timeout: int) -> dict[int, subprocess.CompletedProcess[str]]:
        results: dict[int, subprocess.CompletedProcess[str]] = {}
        with ThreadPoolExecutor(max_workers=len(jobs)) as executor:
            futures = {executor.submit(run, command, timeout=timeout, check=False): ordinal
                       for ordinal, command in jobs.items()}
            for future in as_completed(futures):
                ordinal = futures[future]
                try:
                    completed = future.result()
                except Exception as error:  # timeout and execution errors are retained
                    (directory / f"ue-{ordinal}.stderr.txt").write_text(str(error) + "\n", encoding="utf-8")
                    raise CampaignError(f"concurrent traffic command failed for UE {ordinal}: {error}") from error
                (directory / f"ue-{ordinal}.stdout").write_text(completed.stdout, encoding="utf-8")
                (directory / f"ue-{ordinal}.stderr.txt").write_text(completed.stderr, encoding="utf-8")
                results[ordinal] = completed
        failures = [ordinal for ordinal, completed in results.items() if completed.returncode]
        if failures:
            raise CampaignError(f"traffic commands failed for UE ordinals {failures}")
        return results

    def traffic_command(self, ordinal: int, endpoint: str, ue_ip: str,
                        port: int, mode: str) -> list[str]:
        command = self.kubectl_base + [
            "--namespace", self.namespace, "exec", f"cn5g-ue-{ordinal}",
            "-c", "benchmark-client", "--", "iperf3", "--client", endpoint,
            "--port", str(port), "--bind", ue_ip,
            "--omit", str(self.experiment["controls"]["warm_up_seconds"]),
            "--time", str(self.experiment["controls"]["measurement_seconds"]),
        ]
        if mode == "tcp-reverse":
            rate = self.experiment["traffic"]["tcp"][
                "reverse_offered_rate_per_ue_bits_per_second"
            ]
            command.extend(["--reverse", "--bitrate", str(rate)])
        elif mode == "udp":
            rate = self.experiment["traffic"]["udp"]["offered_rate_per_ue_bits_per_second"]
            command.extend(["--udp", "--bitrate", str(rate)])
        command.append("--json")
        return command

    @staticmethod
    def validate_iperf(directory: Path, level: int, udp: bool) -> None:
        for ordinal in range(level):
            data = json.loads((directory / f"ue-{ordinal}.stdout").read_text(encoding="utf-8"))
            if data.get("error"):
                raise CampaignError(f"iperf3 reported an error for UE {ordinal}: {data['error']}")
            if udp:
                if data.get("end", {}).get("sum", {}).get("bits_per_second", 0) <= 0:
                    raise CampaignError(f"UDP delivered no traffic for UE {ordinal}")
            elif data.get("end", {}).get("sum_received", {}).get("bits_per_second", 0) <= 0:
                raise CampaignError(f"TCP delivered no traffic for UE {ordinal}")

    def run_traffic_stage(self, name: str, attempt: Path, identities: dict[int, dict[str, Any]]) -> dict[str, Any]:
        stage_dir = attempt / name
        stage_dir.mkdir(parents=True, exist_ok=True)
        jobs = {
            ordinal: self.traffic_command(
                ordinal, identity["endpoint_ip"], identity["ue_ip"], identity["port"], name
            )
            for ordinal, identity in identities.items()
        }
        started = time.time()
        results = self.concurrent_commands(jobs, stage_dir, timeout=90)
        finished = time.time()
        self.validate_iperf(stage_dir, len(identities), name == "udp")
        return {
            "started_epoch": started,
            "finished_epoch": finished,
            "return_codes": {str(key): item.returncode for key, item in results.items()},
        }

    def capture_ue_logs(self, directory: Path, level: int) -> None:
        log_dir = directory / "ue-logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        for ordinal in range(level):
            completed = self.kubectl(
                "logs", f"cn5g-ue-{ordinal}", "-c", "ue", "--timestamps=true",
                timeout=60,
            )
            path = log_dir / f"ue-{ordinal}.log"
            path.write_text(completed.stdout, encoding="utf-8")
            if "Initial Registration is successful" not in completed.stdout:
                raise CampaignError(f"UE {ordinal} registration success evidence is absent")
            if "PDU Session establishment is successful" not in completed.stdout:
                raise CampaignError(f"UE {ordinal} PDU-session success evidence is absent")

    def next_attempt(self, condition: Path) -> Path:
        existing = sorted(condition.glob("attempt-*"))
        attempt = condition / f"attempt-{len(existing) + 1:03d}"
        attempt.mkdir(parents=True, exist_ok=False)
        os.chmod(attempt, 0o700)
        return attempt

    def run_condition(self, repetition: int, level: int) -> None:
        assert self.campaign_dir is not None
        condition = self.campaign_dir / f"repetition-{repetition}" / f"level-{level}"
        accepted = condition / "accepted.json"
        if accepted.exists():
            print(f"phase07_condition=skipped-already-pass repetition={repetition} level={level}", flush=True)
            return
        condition.mkdir(parents=True, exist_ok=True)
        attempt = self.next_attempt(condition)
        manifest: dict[str, Any] = {
            "schema_version": 1,
            "repetition": repetition,
            "ue_level": level,
            "status": "running",
            "started": utc_iso(),
            "experiment_sha256": self.experiment_sha,
        }
        write_json(attempt / "manifest.json", manifest)
        print(f"phase07_condition=started repetition={repetition} level={level} attempt={attempt.name}", flush=True)
        error: Exception | None = None
        try:
            manifest["host_before"] = self.host_abort_gate()
            self.reset_condition_state(attempt, f"repetition-{repetition}-level-{level}")
            self.scale_ues(0)
            scale_started = time.time()
            self.scale_ues(level)
            scale_finished = time.time()
            manifest["scale_window"] = {
                "started_epoch": scale_started, "finished_epoch": scale_finished
            }
            self.capture_ue_logs(attempt, level)
            identities: dict[int, dict[str, Any]] = {}
            dnn_map = self.experiment["topology"]["dnn_by_ordinal"]
            port_map = self.experiment["controls"]["iperf_server_port_by_ordinal"]
            endpoint_cache: dict[str, str] = {}
            route_dir = attempt / "routes"
            route_dir.mkdir()
            for ordinal in range(level):
                dnn = dnn_map[str(ordinal)]
                if dnn not in endpoint_cache:
                    endpoint_cache[dnn] = self.endpoint_ip(dnn)
                address = self.ue_ip(ordinal)
                route, policy = self.enforce_route(ordinal, address, endpoint_cache[dnn])
                (route_dir / f"ue-{ordinal}-route.txt").write_text(route + "\n", encoding="utf-8")
                (route_dir / f"ue-{ordinal}-policy-rule.txt").write_text(policy + "\n", encoding="utf-8")
                identities[ordinal] = {
                    "pod": f"cn5g-ue-{ordinal}", "dnn": dnn, "ue_ip": address,
                    "endpoint_ip": endpoint_cache[dnn], "port": port_map[str(ordinal)],
                }
            manifest["identities"] = {str(key): value for key, value in identities.items()}
            before = self.pod_runtime_snapshot()
            write_json(attempt / "runtime-before.json", before)
            traffic_start = time.time()
            icmp_dir = attempt / "icmp"
            icmp_dir.mkdir()
            icmp_jobs = {
                ordinal: self.kubectl_base + [
                    "--namespace", self.namespace, "exec", f"cn5g-ue-{ordinal}",
                    "-c", "ue", "--", "ping", "-I", "uesimtun0", "-c",
                    str(self.experiment["traffic"]["icmp"]["packets_per_ue"]), "-i",
                    str(self.experiment["traffic"]["icmp"]["interval_seconds"]), "-W", "2",
                    identity["endpoint_ip"],
                ]
                for ordinal, identity in identities.items()
            }
            self.concurrent_commands(icmp_jobs, icmp_dir, timeout=45)
            for ordinal in range(level):
                text = (icmp_dir / f"ue-{ordinal}.stdout").read_text(encoding="utf-8")
                if ", 0% packet loss" not in text:
                    raise CampaignError(f"ICMP packet loss is non-zero for UE {ordinal}")
            manifest["traffic_windows"] = {}
            for stage in ("tcp-forward", "tcp-reverse", "udp"):
                manifest["traffic_windows"][stage] = self.run_traffic_stage(stage, attempt, identities)
            traffic_end = time.time()
            after = self.pod_runtime_snapshot()
            write_json(attempt / "runtime-after.json", after)
            self.compare_runtime(before, after)
            self.collect_prometheus(attempt, traffic_start, traffic_end)
            manifest["measurement_window"] = {
                "started_epoch": traffic_start, "finished_epoch": traffic_end
            }
            manifest["host_after"] = self.host_abort_gate()
        except Exception as caught:
            error = caught
            manifest["error"] = str(caught)
        finally:
            try:
                self.restore_five()
                manifest["five_ue_restoration"] = "pass"
            except Exception as restore_error:
                manifest["five_ue_restoration"] = "fail"
                manifest["restoration_error"] = str(restore_error)
                if error is None:
                    error = restore_error
            manifest["finished"] = utc_iso()
            manifest["status"] = "pass" if error is None else "fail"
            write_json(attempt / "manifest.json", manifest)
            self.chown_tree(attempt)
        if error is not None:
            print(f"phase07_condition=fail repetition={repetition} level={level} raw_evidence={attempt}", file=sys.stderr, flush=True)
            raise CampaignError(str(error)) from error
        write_json(accepted, {"status": "pass", "attempt": attempt.name, "accepted_at": utc_iso()})
        self.chown_tree(condition)
        print(f"phase07_condition=pass repetition={repetition} level={level} raw_evidence={attempt}", flush=True)
        time.sleep(self.experiment["controls"]["cool_down_seconds"])

    def collect_idle_baseline(self) -> None:
        assert self.campaign_dir is not None
        baseline = self.campaign_dir / "idle-baseline"
        accepted = baseline / "accepted.json"
        if accepted.exists():
            print("phase07_idle_baseline=skipped-already-pass", flush=True)
            return
        baseline.mkdir(parents=True, exist_ok=True)
        self.host_abort_gate()
        self.reset_condition_state(baseline, "idle-baseline")
        self.restore_five()
        duration = self.experiment["controls"]["idle_baseline_seconds"]
        started = time.time()
        print(f"phase07_idle_baseline=observing seconds={duration}", flush=True)
        time.sleep(duration)
        finished = time.time()
        self.collect_prometheus(baseline, started, finished)
        write_json(accepted, {
            "status": "pass", "duration_seconds": duration,
            "started_epoch": started, "finished_epoch": finished,
        })
        self.chown_tree(baseline)
        print("phase07_idle_baseline=pass", flush=True)

    def successful_pilot_exists(self) -> bool:
        image_state = json.loads(
            (self.root / "artifacts/kubernetes/phase-07-image.json").read_text(encoding="utf-8")
        )
        release = run([
            "helm", "--kubeconfig", str(self.kubeconfig), "--namespace", self.namespace,
            "status", "cn5g", "--output", "json",
        ])
        release_revision = json.loads(release.stdout)["version"]
        for manifest in self.raw_root.glob("*-pilot/manifest.json"):
            try:
                data = json.loads(manifest.read_text(encoding="utf-8"))
                if (
                    data.get("result") == "pass"
                    and data.get("experiment_sha256") == self.experiment_sha
                    and data.get("benchmark_image_id") == image_state["image_id"]
                    and data.get("helm_revision") == release_revision
                ):
                    return True
            except (OSError, json.JSONDecodeError):
                continue
        return False

    def campaign_state(self) -> dict[str, Any]:
        image_state_path = self.root / "artifacts/kubernetes/phase-07-image.json"
        image_state = json.loads(image_state_path.read_text(encoding="utf-8"))
        release = run([
            "helm", "--kubeconfig", str(self.kubeconfig), "--namespace", self.namespace,
            "status", "cn5g", "--output", "json",
        ])
        release_revision = json.loads(release.stdout)["version"]
        if self.state_path.exists():
            state = json.loads(self.state_path.read_text(encoding="utf-8"))
            if state.get("benchmark_image_id") != image_state["image_id"]:
                raise CampaignError("benchmark image changed since the resumable campaign began")
            if state.get("helm_revision") != release_revision:
                raise CampaignError("Helm release revision changed since the resumable campaign began")
            if state.get("experiment_sha256") == self.experiment_sha:
                return state
            state["status"] = "abandoned_after_methodology_correction"
            state["abandoned_at"] = utc_iso()
            state["replacement_experiment_sha256"] = self.experiment_sha
            write_json(self.state_path, state)
            archive = self.state_path.with_name(
                f"phase-07-campaign-{state['campaign_id']}-abandoned.json"
            )
            self.state_path.replace(archive)
            os.chown(archive, self.uid, self.gid)
            old_raw = self.raw_root / state["campaign_id"]
            if old_raw.exists():
                self.chown_tree(old_raw)
            print(
                f"phase07_prior_campaign=preserved-abandoned campaign={state['campaign_id']} "
                f"state={archive}",
                flush=True,
            )
        campaign_id = f"{utc_stamp()}-matrix"
        state = {
            "schema_version": 1, "campaign_id": campaign_id,
            "experiment_sha256": self.experiment_sha,
            "benchmark_image_id": image_state["image_id"],
            "helm_revision": release_revision, "created_at": utc_iso(),
            "status": "in_progress",
        }
        write_json(self.state_path, state)
        os.chown(self.state_path, self.uid, self.gid)
        return state

    def chown_tree(self, path: Path) -> None:
        for root, directories, files in os.walk(path):
            os.chown(root, self.uid, self.gid)
            for name in directories:
                os.chown(Path(root) / name, self.uid, self.gid)
            for name in files:
                os.chown(Path(root) / name, self.uid, self.gid)

    def execute(self) -> None:
        if not self.successful_pilot_exists():
            raise CampaignError("no successful Phase 7 pilot evidence exists")
        state = self.campaign_state()
        self.campaign_dir = self.raw_root / state["campaign_id"]
        self.campaign_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.campaign_dir, 0o700)
        os.chown(self.campaign_dir, self.uid, self.gid)
        print(f"phase07_campaign={state['campaign_id']} mode=resumable", flush=True)
        try:
            self.start_prometheus_forward()
            self.collect_idle_baseline()
            for repetition in range(1, self.experiment["controls"]["repetitions"] + 1):
                for level in self.experiment["topology"]["ue_levels"]:
                    self.run_condition(repetition, level)
            self.restore_five()
            state["status"] = "raw_complete"
            state["completed_at"] = utc_iso()
            write_json(self.state_path, state)
            os.chown(self.state_path, self.uid, self.gid)
            self.chown_tree(self.campaign_dir)
            print(f"phase07_matrix=raw-complete campaign={state['campaign_id']} raw_evidence={self.campaign_dir}", flush=True)
        finally:
            self.stop_prometheus_forward()
            try:
                self.restore_five()
            except Exception as restore_error:
                print(f"error: final five-UE restoration failed: {restore_error}", file=sys.stderr, flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--kubeconfig", type=Path, required=True)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--observability-namespace", required=True)
    parser.add_argument("--experiment", type=Path, required=True)
    parser.add_argument("--raw-root", type=Path, required=True)
    parser.add_argument("--state-file", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    try:
        MatrixRunner(parse_args()).execute()
    except (CampaignError, OSError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        print(f"error: Phase 7 matrix stopped safely: {error}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
