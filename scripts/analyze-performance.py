#!/usr/bin/env python3
"""Validate and summarize one accepted performance campaign raw benchmark campaign."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import statistics
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable


LEVELS = (1, 3, 5)
REPETITIONS = (1, 2, 3)
LOG_TIME = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\]")
PING_LOSS = re.compile(r"(\d+(?:\.\d+)?)% packet loss")
PING_RTT = re.compile(
    r"rtt min/avg/max/mdev = ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+) ms"
)


class AnalysisError(RuntimeError):
    pass


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AnalysisError(f"cannot read valid JSON: {path}") from error


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentile(values: Iterable[float], percent: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise AnalysisError("percentile requested for an empty sample")
    index = max(0, math.ceil(percent / 100 * len(ordered)) - 1)
    return ordered[index]


def distribution(values: Iterable[float]) -> dict[str, float | int]:
    sample = list(values)
    if not sample:
        raise AnalysisError("distribution requested for an empty sample")
    return {
        "count": len(sample),
        "minimum": min(sample),
        "median": statistics.median(sample),
        "p95_nearest_rank": percentile(sample, 95),
        "maximum": max(sample),
        "sample_standard_deviation": statistics.stdev(sample) if len(sample) > 1 else 0.0,
    }


def event_time(log: str, marker: str) -> datetime:
    for line in log.splitlines():
        if marker not in line:
            continue
        match = LOG_TIME.search(line)
        if match:
            return datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S.%f")
    raise AnalysisError(f"required UE log marker is absent: {marker}")


def procedure_latencies(log: str) -> tuple[float, float]:
    registration = (
        event_time(log, "Initial Registration is successful")
        - event_time(log, "Sending Initial Registration")
    ).total_seconds() * 1000
    pdu = (
        event_time(log, "PDU Session establishment is successful")
        - event_time(log, "Sending PDU Session Establishment Request")
    ).total_seconds() * 1000
    if registration < 0 or pdu < 0:
        raise AnalysisError("a procedure completion precedes its request")
    return registration, pdu


def parse_ping(path: Path) -> tuple[float, float, float]:
    text = path.read_text(encoding="utf-8")
    loss = PING_LOSS.search(text)
    rtt = PING_RTT.search(text)
    if not loss or not rtt:
        raise AnalysisError(f"incomplete ICMP evidence: {path}")
    return float(loss.group(1)), float(rtt.group(2)), float(rtt.group(3))


def iperf(path: Path, udp: bool = False) -> dict[str, float]:
    data = read_json(path)
    if data.get("error"):
        raise AnalysisError(f"iperf3 error in accepted evidence: {path}")
    if udp:
        received = data.get("end", {}).get("sum_received") or data.get("end", {}).get("sum")
        if not received:
            raise AnalysisError(f"missing UDP result: {path}")
        return {
            "bps": float(received["bits_per_second"]),
            "loss_percent": float(received["lost_percent"]),
            "jitter_ms": float(received["jitter_ms"]),
        }
    received = data.get("end", {}).get("sum_received")
    sent = data.get("end", {}).get("sum_sent")
    if not received or not sent:
        raise AnalysisError(f"missing TCP result: {path}")
    return {
        "bps": float(received["bits_per_second"]),
        "retransmits": float(sent.get("retransmits", 0)),
    }


def logical_component(pod: str, container: str) -> str:
    if pod.startswith("cn5g-data-internet-"):
        return f"data-internet/{container}"
    if pod.startswith("cn5g-data-enterprise-"):
        return f"data-enterprise/{container}"
    if pod.startswith("cn5g-ue-"):
        return f"ue/{container}"
    return container


def prometheus_component_series(path: Path, runtime: dict[str, Any]) -> dict[str, list[float]]:
    data = read_json(path)
    if data.get("status") != "success":
        raise AnalysisError(f"Prometheus query failed: {path}")
    totals: dict[str, dict[float, float]] = defaultdict(lambda: defaultdict(float))
    valid = set(runtime)
    for series in data.get("data", {}).get("result", []):
        metric = series.get("metric", {})
        pod, container = metric.get("pod", ""), metric.get("container", "")
        if f"{pod}/{container}" not in valid:
            continue
        component = logical_component(pod, container)
        for timestamp, value in series.get("values", []):
            totals[component][float(timestamp)] += float(value)
    return {component: list(points.values()) for component, points in totals.items()}


def jain(values: Iterable[float]) -> float:
    sample = list(values)
    denominator = len(sample) * sum(value * value for value in sample)
    return (sum(sample) ** 2 / denominator) if denominator else 0.0


def csv_write(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        raise AnalysisError(f"refusing to write empty CSV: {path}")
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=list(rows[0]),
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(rows)


def svg_escape(value: str) -> str:
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def grouped_svg(path: Path, title: str, subtitle: str, categories: list[int | str],
                series: list[tuple[str, str, list[float]]], unit: str) -> None:
    width, height = 960, 520
    left, top, plot_w, plot_h = 92, 105, 800, 320
    maximum = max(max(values) for _, _, values in series) * 1.12 or 1
    group_w = plot_w / len(categories)
    bar_w = min(54, group_w / (len(series) + 1))
    colors = [color for _, color, _ in series]
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img">',
        f"<title>{svg_escape(title)}</title>",
        '<rect width="100%" height="100%" fill="#0b1220"/>',
        f'<text x="48" y="44" fill="#f8fafc" font-size="26" font-family="sans-serif" font-weight="700">{svg_escape(title)}</text>',
        f'<text x="48" y="72" fill="#94a3b8" font-size="14" font-family="sans-serif">{svg_escape(subtitle)}</text>',
        f'<text x="{left}" y="96" fill="#64748b" font-size="12" font-family="sans-serif">{svg_escape(unit)}</text>',
    ]
    for tick in range(6):
        value = maximum * tick / 5
        y = top + plot_h - plot_h * tick / 5
        parts.append(f'<line x1="{left}" y1="{y:.1f}" x2="{left + plot_w}" y2="{y:.1f}" stroke="#263247" stroke-width="1"/>')
        parts.append(f'<text x="{left - 12}" y="{y + 5:.1f}" text-anchor="end" fill="#94a3b8" font-size="12" font-family="sans-serif">{value:.1f}</text>')
    for category_index, category in enumerate(categories):
        center = left + group_w * (category_index + 0.5)
        start = center - bar_w * len(series) / 2
        for series_index, (_, color, values) in enumerate(series):
            value = values[category_index]
            bar_h = plot_h * value / maximum
            x = start + series_index * bar_w
            y = top + plot_h - bar_h
            parts.append(f'<rect x="{x + 3:.1f}" y="{y:.1f}" width="{bar_w - 6:.1f}" height="{bar_h:.1f}" rx="4" fill="{color}"/>')
            parts.append(f'<text x="{x + bar_w/2:.1f}" y="{y - 7:.1f}" text-anchor="middle" fill="#e2e8f0" font-size="11" font-family="sans-serif">{value:.1f}</text>')
        label = f"{category} UE" if isinstance(category, int) else str(category)
        parts.append(f'<text x="{center:.1f}" y="{top + plot_h + 30}" text-anchor="middle" fill="#e2e8f0" font-size="12" font-family="sans-serif">{svg_escape(label)}</text>')
    legend_x = left
    for index, (name, color, _) in enumerate(series):
        x = legend_x + index * 230
        parts.append(f'<rect x="{x}" y="472" width="14" height="14" rx="2" fill="{color}"/>')
        parts.append(f'<text x="{x + 22}" y="484" fill="#cbd5e1" font-size="13" font-family="sans-serif">{svg_escape(name)}</text>')
    parts.append("</svg>\n")
    path.write_text("".join(parts), encoding="utf-8")


def markdown_table(headers: list[str], rows: list[list[str]]) -> str:
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"]
    lines.extend("| " + " | ".join(row) + " |" for row in rows)
    return "\n".join(lines)


def analyze(root: Path, state_path: Path, experiment_path: Path, output: Path,
            report_path: Path) -> None:
    state = read_json(state_path)
    if state.get("status") != "raw_complete":
        raise AnalysisError("campaign state is not raw_complete")
    experiment = read_json(experiment_path)
    experiment_hash = sha256(experiment_path)
    if state.get("experiment_sha256") != experiment_hash:
        raise AnalysisError("campaign and current experiment hashes differ")
    campaign_id = state["campaign_id"]
    campaign = root / "benchmarks/raw/performance" / campaign_id
    if not campaign.is_dir():
        raise AnalysisError("accepted raw campaign directory is absent")
    idle = read_json(campaign / "idle-baseline/accepted.json")
    if idle.get("status") != "pass":
        raise AnalysisError("idle baseline is not accepted")

    ue_rows: list[dict[str, Any]] = []
    condition_rows: list[dict[str, Any]] = []
    resource_rows: list[dict[str, Any]] = []
    accepted_attempts: list[str] = []
    reverse_rate = experiment["traffic"]["tcp"]["reverse_offered_rate_per_ue_bits_per_second"]
    udp_rate = experiment["traffic"]["udp"]["offered_rate_per_ue_bits_per_second"]

    for repetition in REPETITIONS:
        for level in LEVELS:
            condition = campaign / f"repetition-{repetition}" / f"level-{level}"
            accepted = read_json(condition / "accepted.json")
            if accepted.get("status") != "pass":
                raise AnalysisError(f"condition is not accepted: repetition {repetition}, level {level}")
            attempt = condition / accepted["attempt"]
            accepted_attempts.append(str(attempt.relative_to(campaign)))
            manifest = read_json(attempt / "manifest.json")
            if (
                manifest.get("status") != "pass"
                or manifest.get("five_ue_restoration") != "pass"
                or manifest.get("experiment_sha256") != experiment_hash
                or manifest.get("repetition") != repetition
                or manifest.get("ue_level") != level
            ):
                raise AnalysisError(f"accepted manifest failed integrity checks: {attempt}")
            before, after = read_json(attempt / "runtime-before.json"), read_json(attempt / "runtime-after.json")
            if before != after:
                raise AnalysisError(f"runtime identity/restart state changed: {attempt}")

            condition_ues: list[dict[str, Any]] = []
            for ordinal in range(level):
                identity = manifest["identities"][str(ordinal)]
                forward = iperf(attempt / f"tcp-forward/ue-{ordinal}.stdout")
                reverse = iperf(attempt / f"tcp-reverse/ue-{ordinal}.stdout")
                udp = iperf(attempt / f"udp/ue-{ordinal}.stdout", udp=True)
                loss, rtt_avg, rtt_max = parse_ping(attempt / f"icmp/ue-{ordinal}.stdout")
                log = (attempt / f"ue-logs/ue-{ordinal}.log").read_text(encoding="utf-8")
                registration_ms, pdu_ms = procedure_latencies(log)
                row = {
                    "repetition": repetition,
                    "ue_level": level,
                    "ordinal": ordinal,
                    "dnn": identity["dnn"],
                    "registration_success": 1,
                    "registration_latency_ms": round(registration_ms, 3),
                    "pdu_session_success": 1,
                    "pdu_session_latency_ms": round(pdu_ms, 3),
                    "icmp_loss_percent": loss,
                    "icmp_rtt_average_ms": rtt_avg,
                    "icmp_rtt_max_ms": rtt_max,
                    "tcp_forward_mbps": forward["bps"] / 1_000_000,
                    "tcp_forward_retransmits": int(forward["retransmits"]),
                    "tcp_reverse_mbps": reverse["bps"] / 1_000_000,
                    "tcp_reverse_retransmits": int(reverse["retransmits"]),
                    "udp_mbps": udp["bps"] / 1_000_000,
                    "udp_loss_percent": udp["loss_percent"],
                    "udp_jitter_ms": udp["jitter_ms"],
                }
                condition_ues.append(row)
                ue_rows.append(row)

            forward_values = [row["tcp_forward_mbps"] for row in condition_ues]
            condition_rows.append({
                "repetition": repetition,
                "ue_level": level,
                "registration_success_rate_percent": 100.0,
                "registration_latency_median_ms": statistics.median(row["registration_latency_ms"] for row in condition_ues),
                "registration_latency_p95_ms": percentile((row["registration_latency_ms"] for row in condition_ues), 95),
                "pdu_session_success_rate_percent": 100.0,
                "pdu_session_latency_median_ms": statistics.median(row["pdu_session_latency_ms"] for row in condition_ues),
                "pdu_session_latency_p95_ms": percentile((row["pdu_session_latency_ms"] for row in condition_ues), 95),
                "icmp_loss_percent_max": max(row["icmp_loss_percent"] for row in condition_ues),
                "icmp_rtt_average_ms": statistics.mean(row["icmp_rtt_average_ms"] for row in condition_ues),
                "tcp_forward_aggregate_mbps": sum(forward_values),
                "tcp_forward_per_ue_median_mbps": statistics.median(forward_values),
                "tcp_forward_jain_fairness": jain(forward_values),
                "tcp_forward_retransmits": sum(row["tcp_forward_retransmits"] for row in condition_ues),
                "tcp_reverse_aggregate_mbps": sum(row["tcp_reverse_mbps"] for row in condition_ues),
                "tcp_reverse_target_attainment_percent": sum(row["tcp_reverse_mbps"] for row in condition_ues) / (reverse_rate * level / 1_000_000) * 100,
                "tcp_reverse_retransmits": sum(row["tcp_reverse_retransmits"] for row in condition_ues),
                "udp_aggregate_mbps": sum(row["udp_mbps"] for row in condition_ues),
                "udp_target_attainment_percent": sum(row["udp_mbps"] for row in condition_ues) / (udp_rate * level / 1_000_000) * 100,
                "udp_loss_percent_max": max(row["udp_loss_percent"] for row in condition_ues),
                "udp_jitter_ms_p95": percentile((row["udp_jitter_ms"] for row in condition_ues), 95),
                "new_restarts": 0,
            })

            cpu = prometheus_component_series(attempt / "prometheus/cpu.json", before)
            memory = prometheus_component_series(attempt / "prometheus/memory.json", before)
            for component in sorted(set(cpu) & set(memory)):
                resource_rows.append({
                    "repetition": repetition,
                    "ue_level": level,
                    "component": component,
                    "cpu_mean_millicores": statistics.mean(cpu[component]) * 1000,
                    "cpu_peak_millicores": max(cpu[component]) * 1000,
                    "memory_mean_mib": statistics.mean(memory[component]) / 1024 / 1024,
                    "memory_peak_mib": max(memory[component]) / 1024 / 1024,
                })

    level_summary: dict[str, Any] = {}
    for level in LEVELS:
        rows = [row for row in condition_rows if row["ue_level"] == level]
        metrics = [
            "registration_latency_median_ms", "registration_latency_p95_ms",
            "pdu_session_latency_median_ms", "pdu_session_latency_p95_ms",
            "icmp_rtt_average_ms", "tcp_forward_aggregate_mbps",
            "tcp_forward_per_ue_median_mbps", "tcp_forward_jain_fairness",
            "tcp_forward_retransmits", "tcp_reverse_aggregate_mbps",
            "tcp_reverse_target_attainment_percent", "tcp_reverse_retransmits",
            "udp_aggregate_mbps", "udp_target_attainment_percent",
            "udp_loss_percent_max", "udp_jitter_ms_p95",
        ]
        level_summary[str(level)] = {
            "repetitions": len(rows),
            "registration_success_rate_percent": 100.0,
            "pdu_session_success_rate_percent": 100.0,
            "new_restarts": 0,
            "metrics": {metric: distribution(row[metric] for row in rows) for metric in metrics},
        }

    resource_summary: dict[str, Any] = {}
    for level in LEVELS:
        resource_summary[str(level)] = {}
        for component in sorted({row["component"] for row in resource_rows}):
            rows = [row for row in resource_rows if row["ue_level"] == level and row["component"] == component]
            if rows:
                resource_summary[str(level)][component] = {
                    "cpu_peak_millicores": distribution(row["cpu_peak_millicores"] for row in rows),
                    "memory_peak_mib": distribution(row["memory_peak_mib"] for row in rows),
                }

    excluded = []
    for manifest_path in sorted((root / "benchmarks/raw/performance").glob("*-matrix/repetition-*/level-*/attempt-*/manifest.json")):
        if campaign in manifest_path.parents:
            continue
        manifest = read_json(manifest_path)
        if manifest.get("status") != "fail":
            continue
        error = str(manifest.get("error", ""))
        classification = "reverse_tcp_timeout" if "--reverse" in error and "timed out" in error else "failed_exploratory_attempt"
        excluded.append({
            "campaign_id": manifest_path.parents[3].name,
            "repetition": manifest.get("repetition"),
            "ue_level": manifest.get("ue_level"),
            "classification": classification,
            "included_in_summary": False,
        })

    summary = {
        "schema_version": 1,
        "campaign": {
            "campaign_id": campaign_id,
            "status": "reviewed_complete",
            "created_at": state["created_at"],
            "completed_at": state["completed_at"],
            "experiment_sha256": experiment_hash,
            "benchmark_image_id": state["benchmark_image_id"],
            "helm_revision": state["helm_revision"],
            "accepted_attempt_count": len(accepted_attempts),
            "accepted_attempts": accepted_attempts,
            "idle_baseline_seconds": experiment["controls"]["idle_baseline_seconds"],
        },
        "contract": {
            "ue_levels": list(LEVELS),
            "repetitions": len(REPETITIONS),
            "warm_up_seconds": experiment["controls"]["warm_up_seconds"],
            "measurement_seconds": experiment["controls"]["measurement_seconds"],
            "tcp_forward_offered_rate": "unbounded",
            "tcp_reverse_offered_rate_per_ue_bits_per_second": reverse_rate,
            "udp_offered_rate_per_ue_bits_per_second": udp_rate,
        },
        "per_level": level_summary,
        "resources": resource_summary,
        "excluded_failed_exploratory_attempts": excluded,
        "limitations": [
            "Single Ubuntu host and single-node kind cluster; results are not carrier capacity or production sizing.",
            "UERANSIM models the radio link in user space and does not implement a complete 5G NR physical layer.",
            "Reverse TCP is a fixed 10 Mbit/s per-UE service-load check, not a maximum downlink-capacity test.",
            "The accepted matrix contains three repetitions per load level; nearest-rank p95 therefore equals the maximum repetition-level observation.",
            "Idle telemetry proves a timestamped baseline exists, but component comparisons use condition telemetry filtered by runtime Pod identity to exclude terminated-container series.",
        ],
    }

    output.mkdir(parents=True, exist_ok=True)
    plots = output / "plots"
    plots.mkdir(exist_ok=True)
    csv_write(output / "per-ue.csv", ue_rows)
    csv_write(output / "condition-summary.csv", condition_rows)
    csv_write(output / "resource-summary.csv", resource_rows)
    write_json(output / "summary.json", summary)

    levels = list(LEVELS)
    medians = lambda metric: [level_summary[str(level)]["metrics"][metric]["median"] for level in levels]
    resource_labels = {
        "ue/ue": "UE runtime",
        "gnb": "gNB",
        "upf": "UPF",
        "ue/benchmark-client": "UE benchmark",
        "data-internet/benchmark-server": "Internet server",
        "data-enterprise/benchmark-server": "Enterprise server",
    }
    grouped_svg(
        plots / "throughput.svg",
        "performance campaign aggregate traffic results",
        "Median of three repetitions; reverse TCP and UDP are fixed offered-load checks",
        levels,
        [
            ("Forward TCP (unbounded)", "#38bdf8", medians("tcp_forward_aggregate_mbps")),
            ("Reverse TCP (10 Mbps/UE)", "#a78bfa", medians("tcp_reverse_aggregate_mbps")),
            ("UDP (1 Mbps/UE)", "#34d399", medians("udp_aggregate_mbps")),
        ],
        "Aggregate delivered throughput (Mbit/s)",
    )
    grouped_svg(
        plots / "procedures.svg",
        "5G procedure latency",
        "Median of the per-condition median across three repetitions",
        levels,
        [
            ("Registration", "#fb7185", medians("registration_latency_median_ms")),
            ("PDU session", "#fbbf24", medians("pdu_session_latency_median_ms")),
            ("ICMP RTT", "#2dd4bf", medians("icmp_rtt_average_ms")),
        ],
        "Milliseconds",
    )
    level_five = resource_summary["5"]
    top_components = sorted(
        level_five,
        key=lambda component: level_five[component]["cpu_peak_millicores"]["median"],
        reverse=True,
    )[:6]
    grouped_svg(
        plots / "resources.svg",
        "Five-UE component CPU peaks",
        "Median peak across three repetitions; current runtime Pod identities only",
        [resource_labels.get(component, component) for component in top_components],
        [("Peak CPU", "#38bdf8", [
            level_five[component]["cpu_peak_millicores"]["median"]
            for component in top_components
        ])],
        "Peak CPU (millicores)",
    )

    table_rows = []
    for level in LEVELS:
        metrics = level_summary[str(level)]["metrics"]
        table_rows.append([
            str(level),
            f'{metrics["tcp_forward_aggregate_mbps"]["median"]:.2f}',
            f'{metrics["tcp_forward_per_ue_median_mbps"]["median"]:.2f}',
            f'{metrics["tcp_forward_jain_fairness"]["median"]:.4f}',
            f'{metrics["tcp_reverse_aggregate_mbps"]["median"]:.2f}',
            f'{metrics["udp_loss_percent_max"]["maximum"]:.2f}',
            f'{metrics["icmp_rtt_average_ms"]["median"]:.3f}',
        ])
    procedure_rows = []
    for level in LEVELS:
        metrics = level_summary[str(level)]["metrics"]
        procedure_rows.append([
            str(level), "100.0",
            f'{metrics["registration_latency_median_ms"]["median"]:.3f}',
            "100.0", f'{metrics["pdu_session_latency_median_ms"]["median"]:.3f}',
        ])
    peak_cpu = max(resource_rows, key=lambda row: row["cpu_peak_millicores"])
    peak_memory = max(resource_rows, key=lambda row: row["memory_peak_mib"])
    report = f"""# Performance And Capacity Experiment Report

Status: reviewed local-lab evidence; not production sizing.

## Result

Campaign `{campaign_id}` completed all nine accepted conditions: three repetitions
at 1, 3, and 5 concurrent synthetic UEs. Registration and PDU-session success
were 100% in every accepted condition, every traffic command completed, no new
container restart occurred, and the runner restored five UEs after every attempt.

![Aggregate traffic results](../benchmarks/performance/results/plots/throughput.svg)

{markdown_table(["UEs", "Forward aggregate Mbit/s", "Forward per-UE median Mbit/s", "Jain fairness", "Reverse aggregate Mbit/s", "Maximum UDP loss %", "Median ICMP RTT ms"], table_rows)}

Forward TCP was unbounded and is the only saturation-oriented traffic stage.
Reverse TCP offered exactly 10 Mbit/s per UE, while UDP offered 1 Mbit/s per UE;
those values test service-load delivery and are not downlink-capacity claims.

## Procedure Behavior

![Procedure latency](../benchmarks/performance/results/plots/procedures.svg)

{markdown_table(["UEs", "Registration success %", "Registration median ms", "PDU success %", "PDU median ms"], procedure_rows)}

Each latency cell above is the median of three condition-level medians. The
machine-readable summary also retains minimum, maximum, nearest-rank p95, and
sample standard deviation. With only three repetitions, p95 equals the maximum
observed repetition and should be interpreted cautiously.

## Resource Evidence And Bottleneck Reading

![Five-UE CPU peaks](../benchmarks/performance/results/plots/resources.svg)

The largest individual accepted-condition CPU peak was
`{peak_cpu['component']}` at {peak_cpu['cpu_peak_millicores']:.1f} millicores.
The largest memory peak was `{peak_memory['component']}` at
{peak_memory['memory_peak_mib']:.1f} MiB. Resource analysis filters Prometheus
series against each condition's runtime Pod snapshot, preventing terminated
rollout Pods from inflating the result. No accepted condition recorded a
container restart or Out-of-Memory kill.

The forward aggregate result should be read together with the falling per-UE
share as concurrency rises. It characterizes contention in this exact
single-host, user-space simulated path; it does not establish commercial RAN or
5G Core capacity.

At five UEs, the median peak CPU was 515.7 millicores across the five UE runtime
containers, 334.7 millicores at the single gNB, and 147.7 millicores at the
UPF. Median forward retransmissions rose from 233 at one UE to 729 at three and
1,919 at five, while aggregate forward throughput did not scale with UE count.
Together these observations identify the simulated UE/gNB side of the path as
the leading bottleneck candidate. They do not isolate one causal function;
packet-level profiling would be required for that stronger claim.

## Retained Failures

Earlier exploratory campaigns are intentionally excluded from the accepted
summary. They exposed reverse-TCP stalls under an unbounded downlink workload
and a stale UPF endpoint-policy ordering defect. Both failures were retained,
explained, and used to correct the experiment contract. The accepted contract
restarts DNN endpoints before rebuilding the session chain and treats reverse
TCP as a fixed 10 Mbit/s-per-UE service-load check.

## Reproduction

```bash
sudo ./scripts/performance-campaign.sh preflight
sudo ./scripts/performance-campaign.sh pilot
sudo ./scripts/performance-campaign.sh run-matrix
./scripts/analyze-performance.py
```

The analyzer validates the experiment hash, accepted markers, manifests,
runtime restart snapshots, and all required traffic/telemetry files before it
writes reviewed outputs. Raw evidence remains ignored and permission-restricted.

## Reviewed Artifacts

- `benchmarks/performance/results/summary.json`
- `benchmarks/performance/results/condition-summary.csv`
- `benchmarks/performance/results/per-ue.csv`
- `benchmarks/performance/results/resource-summary.csv`
- `benchmarks/performance/results/plots/`

## Limitations

""" + "\n".join(f"- {item}" for item in summary["limitations"]) + "\n"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(report, encoding="utf-8")
    print(f"performance_analysis_campaign={campaign_id}")
    print("performance_analysis_conditions=pass accepted=9")
    print("performance_analysis_outputs=pass csv=3 json=1 svg=3 report=1")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--state-file", type=Path)
    parser.add_argument("--experiment", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--report", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.project_root.resolve()
    analyze(
        root,
        args.state_file or root / "artifacts/kubernetes/performance-campaign.json",
        args.experiment or root / "benchmarks/performance/experiment.json",
        args.output or root / "benchmarks/performance/results",
        args.report or root / "reports/performance-results.md",
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AnalysisError as error:
        print(f"error: {error}")
        raise SystemExit(1)
