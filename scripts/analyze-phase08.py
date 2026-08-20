#!/usr/bin/env python3
"""Validate a complete Phase 8 campaign and generate reviewed evidence."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import sys
from typing import Any, Iterable


COMPONENTS = ("amf", "smf", "upf")
METRICS = (
    "mttd_seconds",
    "replacement_ready_seconds",
    "mttr_seconds",
    "baseline_restoration_seconds",
    "user_plane_disruption_seconds",
)


class AnalysisError(RuntimeError):
    """Rejected or incomplete Phase 8 evidence."""


def percentile(values: Iterable[float], quantile: float) -> float:
    ordered = sorted(float(value) for value in values)
    if not ordered:
        raise AnalysisError("cannot calculate a percentile of no values")
    index = max(0, math.ceil((quantile / 100) * len(ordered)) - 1)
    return ordered[index]


def distribution(values: Iterable[float]) -> dict[str, float]:
    samples = [float(value) for value in values]
    if not samples:
        raise AnalysisError("cannot summarize no values")
    return {
        "minimum": min(samples),
        "median": statistics.median(samples),
        "mean": statistics.mean(samples),
        "p95_nearest_rank": percentile(samples, 95),
        "maximum": max(samples),
        "sample_standard_deviation": statistics.stdev(samples) if len(samples) > 1 else 0.0,
    }


def parse_time(value: str) -> float:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def prometheus_values(path: Path) -> list[tuple[float, float]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("status") != "success":
        raise AnalysisError(f"Prometheus evidence is unsuccessful: {path.name}")
    output: list[tuple[float, float]] = []
    for series in payload.get("data", {}).get("result", []):
        for timestamp, value in series.get("values", []):
            output.append((float(timestamp), float(value)))
    return sorted(output)


def first_transition(
    samples: list[tuple[float, float]], *, start: float, value: float,
) -> float | None:
    return next((timestamp for timestamp, item in samples if timestamp >= start and item == value), None)


def user_plane_disruption(timeline: list[dict[str, Any]], fault_at: float) -> tuple[bool, float]:
    observations: list[tuple[float, float]] = []
    for item in timeline:
        if item.get("epoch", 0) < fault_at or "prometheus" not in item:
            continue
        sample = item["prometheus"].get("user_plane_paths", {})
        if sample.get("present") and sample.get("value") is not None:
            observations.append((float(item["epoch"]), float(sample["value"])))
    first_failure = next((timestamp for timestamp, value in observations if value < 5), None)
    if first_failure is None:
        return False, 0.0
    recovered = next(
        (timestamp for timestamp, value in observations if timestamp > first_failure and value == 5),
        None,
    )
    if recovered is None:
        raise AnalysisError("user-plane failure has no later recovered observation")
    return True, recovered - first_failure


def read_attempt(path: Path, component: str, repetition: int, experiment_sha: str,
                 helm_revision: int) -> dict[str, Any]:
    accepted = json.loads((path / "accepted.json").read_text(encoding="utf-8"))
    manifest = json.loads((path / "manifest.json").read_text(encoding="utf-8"))
    if accepted.get("result") != "accepted":
        raise AnalysisError("attempt marker is not accepted")
    required = {
        "result": "pass", "component": component,
        "experiment_sha256": experiment_sha, "helm_revision": helm_revision,
        "baseline_restored": True,
    }
    for key, expected in required.items():
        if manifest.get(key) != expected:
            raise AnalysisError(f"attempt field {key} differs from the campaign contract")
    identity = manifest.get("identity", {})
    if identity.get("repetition") != repetition:
        raise AnalysisError("attempt repetition identity differs from its accepted condition")
    if manifest.get("mongodb_pvc_before") != manifest.get("mongodb_pvc_after"):
        raise AnalysisError("MongoDB PVC identity changed in an accepted attempt")
    timeline = json.loads((path / "timeline.json").read_text(encoding="utf-8"))
    fault_at = parse_time(manifest["fault_at"])
    disruption, disruption_seconds = user_plane_disruption(timeline, fault_at)
    target_samples = prometheus_values(path / "prometheus" / "target_up.json")
    target_down_at = first_transition(target_samples, start=fault_at, value=0)
    target_up_at = (
        first_transition(target_samples, start=target_down_at, value=1)
        if target_down_at is not None else None
    )
    timings = manifest["timings_seconds"]
    for name in ("mttd", "replacement_ready", "operator_assisted_baseline_restoration", "mttr"):
        if not isinstance(timings.get(name), (int, float)) or timings[name] < 0:
            raise AnalysisError(f"invalid timing value: {name}")
    return {
        "repetition": repetition,
        "component": component,
        "attempt": identity["attempt"],
        "service_recovery_mode": manifest["service_recovery_mode"],
        "mttd_seconds": timings["mttd"],
        "replacement_ready_seconds": timings["replacement_ready"],
        "mttr_seconds": timings["mttr"],
        "baseline_restoration_seconds": timings["operator_assisted_baseline_restoration"],
        "user_plane_disruption_observed": disruption,
        "user_plane_disruption_seconds": disruption_seconds,
        "prometheus_target_down_observed": target_down_at is not None,
        "prometheus_target_detection_seconds": (
            target_down_at - fault_at if target_down_at is not None else None
        ),
        "prometheus_target_recovery_seconds": (
            target_up_at - fault_at if target_up_at is not None else None
        ),
        "fault_target_before_uid": manifest["fault_target_before"]["pod_uid"],
        "fault_target_after_uid": manifest["fault_target_after"]["pod_uid"],
        "baseline_restored": True,
    }


def fmt(value: float) -> str:
    return f"{value:.3f}"


def csv_text(fieldnames: list[str], rows: list[dict[str, Any]]) -> str:
    from io import StringIO
    handle = StringIO(newline="")
    writer = csv.DictWriter(handle, fieldnames=fieldnames, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return handle.getvalue()


def svg_grouped(summary: dict[str, Any]) -> str:
    width, height = 960, 520
    plot_left, plot_top, plot_width, plot_height = 90, 70, 800, 340
    series = (
        ("MTTD", "mttd_seconds", "#3b82f6"),
        ("Pod Ready", "replacement_ready_seconds", "#f59e0b"),
        ("MTTR", "mttr_seconds", "#10b981"),
    )
    maximum = max(
        summary[component][metric]["median"]
        for component in COMPONENTS for _, metric, _ in series
    )
    scale = plot_height / max(maximum, 1)
    pieces = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<title>Median Phase 8 detection, Pod readiness, and service recovery times</title>',
        '<rect width="100%" height="100%" fill="#0f172a"/>',
        '<text x="48" y="38" fill="#f8fafc" font-size="22" font-family="sans-serif">Phase 8 median recovery boundaries</text>',
        f'<line x1="{plot_left}" y1="{plot_top + plot_height}" x2="{plot_left + plot_width}" y2="{plot_top + plot_height}" stroke="#64748b"/>',
    ]
    group_width = plot_width / len(COMPONENTS)
    bar_width = 54
    for index, component in enumerate(COMPONENTS):
        center = plot_left + group_width * (index + 0.5)
        for series_index, (label, metric, color) in enumerate(series):
            value = summary[component][metric]["median"]
            bar_height = value * scale
            x = center + (series_index - 1) * (bar_width + 8) - bar_width / 2
            y = plot_top + plot_height - bar_height
            pieces.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_width}" height="{bar_height:.1f}" fill="{color}" rx="4"/>')
            pieces.append(f'<text x="{x + bar_width / 2:.1f}" y="{max(y - 7, 55):.1f}" text-anchor="middle" fill="#e2e8f0" font-size="12" font-family="sans-serif">{value:.1f}s</text>')
        pieces.append(f'<text x="{center:.1f}" y="{plot_top + plot_height + 30}" text-anchor="middle" fill="#f8fafc" font-size="16" font-family="sans-serif">{component.upper()}</text>')
    for index, (label, _, color) in enumerate(series):
        x = 180 + index * 220
        pieces.append(f'<rect x="{x}" y="470" width="18" height="18" fill="{color}" rx="3"/>')
        pieces.append(f'<text x="{x + 26}" y="484" fill="#cbd5e1" font-size="14" font-family="sans-serif">{label}</text>')
    pieces.append('</svg>\n')
    return "\n".join(pieces)


def svg_modes(rows: list[dict[str, Any]]) -> str:
    width, height = 820, 420
    pieces = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<title>Automatic and operator-assisted Phase 8 service recovery outcomes</title>',
        '<rect width="100%" height="100%" fill="#0f172a"/>',
        '<text x="40" y="38" fill="#f8fafc" font-size="21" font-family="sans-serif">Service recovery mode by component</text>',
    ]
    for index, component in enumerate(COMPONENTS):
        selected = [row for row in rows if row["component"] == component]
        automatic = sum(row["service_recovery_mode"] == "automatic" for row in selected)
        assisted = len(selected) - automatic
        y = 95 + index * 95
        pieces += [
            f'<text x="40" y="{y + 28}" fill="#f8fafc" font-size="16" font-family="sans-serif">{component.upper()}</text>',
            f'<rect x="130" y="{y}" width="{automatic * 180}" height="38" fill="#10b981" rx="4"/>',
            f'<rect x="{130 + automatic * 180}" y="{y}" width="{assisted * 180}" height="38" fill="#f59e0b" rx="4"/>',
            f'<text x="680" y="{y + 26}" fill="#cbd5e1" font-size="14" font-family="sans-serif">{automatic} automatic / {assisted} assisted</text>',
        ]
    pieces += [
        '<rect x="220" y="365" width="18" height="18" fill="#10b981" rx="3"/>',
        '<text x="246" y="379" fill="#cbd5e1" font-size="14" font-family="sans-serif">Automatic</text>',
        '<rect x="410" y="365" width="18" height="18" fill="#f59e0b" rx="3"/>',
        '<text x="436" y="379" fill="#cbd5e1" font-size="14" font-family="sans-serif">Operator-assisted</text>',
        '</svg>\n',
    ]
    return "\n".join(pieces)


def svg_disruption(summary: dict[str, Any]) -> str:
    width, height = 820, 420
    maximum = max(
        summary[component]["user_plane_disruption_seconds"]["median"]
        for component in COMPONENTS
    )
    scale = 260 / max(maximum, 1)
    pieces = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<title>Median observed user-plane disruption by Phase 8 fault component</title>',
        '<rect width="100%" height="100%" fill="#0f172a"/>',
        '<text x="40" y="38" fill="#f8fafc" font-size="21" font-family="sans-serif">Median observed user-plane disruption</text>',
    ]
    for index, component in enumerate(COMPONENTS):
        value = summary[component]["user_plane_disruption_seconds"]["median"]
        x = 140 + index * 220
        bar_height = value * scale
        y = 330 - bar_height
        pieces += [
            f'<rect x="{x}" y="{y:.1f}" width="100" height="{bar_height:.1f}" fill="#ef4444" rx="4"/>',
            f'<text x="{x + 50}" y="{max(y - 8, 58):.1f}" text-anchor="middle" fill="#e2e8f0" font-size="14" font-family="sans-serif">{value:.1f}s</text>',
            f'<text x="{x + 50}" y="360" text-anchor="middle" fill="#f8fafc" font-size="16" font-family="sans-serif">{component.upper()}</text>',
        ]
    pieces.append('</svg>\n')
    return "\n".join(pieces)


def report_text(campaign: dict[str, Any], summary: dict[str, Any], rows: list[dict[str, Any]]) -> str:
    lines = [
        "# Phase 8 Reliability And Recovery Results",
        "",
        "## Scope",
        "",
        "This report summarizes one reviewed local single-node kind campaign. Each",
        "AMF, SMF, and UPF condition deleted exactly one project-owned Pod and used",
        "three measured repetitions. The result is not evidence of high availability,",
        "zero downtime, carrier-grade resilience, or a production Recovery Time Objective.",
        "",
        "## Recovery Boundaries",
        "",
        "| Component | Median MTTD | Median Pod Ready | Median MTTR | Automatic | Assisted | Median user-plane disruption |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for component in COMPONENTS:
        selected = [row for row in rows if row["component"] == component]
        automatic = sum(row["service_recovery_mode"] == "automatic" for row in selected)
        assisted = len(selected) - automatic
        item = summary[component]
        lines.append(
            f"| {component.upper()} | {fmt(item['mttd_seconds']['median'])} s | "
            f"{fmt(item['replacement_ready_seconds']['median'])} s | "
            f"{fmt(item['mttr_seconds']['median'])} s | {automatic} | {assisted} | "
            f"{fmt(item['user_plane_disruption_seconds']['median'])} s |"
        )
    lines += [
        "",
        "MTTD is measured from the fault request to Kubernetes API detection. MTTR",
        "ends only when the component-specific 5G service signals recover; Pod Ready",
        "alone is reported separately. Operator-assisted restoration is labelled and",
        "is never presented as automatic recovery.",
        "",
        "## Evidence And Restoration",
        "",
        f"- Campaign: `{campaign['campaign_id']}`",
        f"- Accepted attempts: {len(rows)}",
        "- Every attempt preserved the MongoDB PVC identity.",
        "- Every attempt ended with complete Phase 5 and Phase 6 validation.",
        "- Kubernetes events, Prometheus ranges, Loki logs, and source-bound UE probes",
        "  remain in ignored raw evidence; this report contains reviewed reductions.",
        "",
        "## Interpretation",
        "",
        "Kubernetes reconciliation measures infrastructure replacement. The wider gap",
        "between Pod readiness and MTTR, where present, represents restoration of 5G",
        "state and user-visible service rather than container startup. Because all three",
        "network functions have one replica on one node, an interruption is expected and",
        "the measurements must not be extrapolated to a redundant deployment.",
    ]
    return "\n".join(lines) + "\n"


def analyze(root: Path) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, Any]]:
    experiment_path = root / "benchmarks" / "phase-08" / "experiment.json"
    state_path = root / "artifacts" / "kubernetes" / "phase-08-campaign.json"
    if not state_path.is_file() or state_path.is_symlink():
        raise AnalysisError("Phase 8 campaign state is absent or unsafe")
    experiment = json.loads(experiment_path.read_text(encoding="utf-8"))
    state = json.loads(state_path.read_text(encoding="utf-8"))
    experiment_sha = hashlib.sha256(experiment_path.read_bytes()).hexdigest()
    if state.get("status") != "raw_complete":
        raise AnalysisError("Phase 8 campaign is not raw_complete")
    if state.get("experiment_sha256") != experiment_sha:
        raise AnalysisError("campaign experiment hash differs from the tracked contract")
    expected = {
        f"repetition-{repetition}/{component}"
        for repetition in range(1, 4) for component in COMPONENTS
    }
    if set(state.get("accepted", {})) != expected:
        raise AnalysisError("campaign does not contain the exact nine accepted conditions")
    campaign_dir = root / "benchmarks" / "raw" / "phase-08" / state["campaign_id"]
    rows: list[dict[str, Any]] = []
    for repetition in range(1, 4):
        for component in COMPONENTS:
            key = f"repetition-{repetition}/{component}"
            attempt = campaign_dir / state["accepted"][key]
            if not attempt.is_dir() or attempt.is_symlink():
                raise AnalysisError(f"accepted attempt path is absent or unsafe: {key}")
            rows.append(read_attempt(
                attempt, component, repetition, experiment_sha, state["helm_revision"]
            ))
    component_summary: dict[str, Any] = {}
    for component in COMPONENTS:
        selected = [row for row in rows if row["component"] == component]
        component_summary[component] = {
            metric: distribution(row[metric] for row in selected) for metric in METRICS
        }
        component_summary[component]["repetitions"] = len(selected)
        component_summary[component]["automatic_recoveries"] = sum(
            row["service_recovery_mode"] == "automatic" for row in selected
        )
        component_summary[component]["operator_assisted_recoveries"] = sum(
            row["service_recovery_mode"] == "operator-assisted" for row in selected
        )
        component_summary[component]["prometheus_target_down_observations"] = sum(
            row["prometheus_target_down_observed"] for row in selected
        )
    summary = {
        "schema_version": 1,
        "campaign": {
            "campaign_id": state["campaign_id"],
            "status": "reviewed_complete",
            "completed_at": state["completed_at"],
            "accepted_attempt_count": len(rows),
            "helm_revision": state["helm_revision"],
        },
        "contract": {
            "components": list(COMPONENTS),
            "repetitions": experiment["controls"]["repetitions"],
            "fault_method": experiment["controls"]["fault_method"],
        },
        "components": component_summary,
        "limitations": experiment["publication"]["required_limitations"],
    }
    return state, rows, summary


def write_outputs(root: Path, state: dict[str, Any], rows: list[dict[str, Any]],
                  summary: dict[str, Any]) -> None:
    results = root / "benchmarks" / "phase-08" / "results"
    plots = results / "plots"
    plots.mkdir(parents=True, exist_ok=True)
    row_fields = [
        "repetition", "component", "attempt", "service_recovery_mode",
        "mttd_seconds", "replacement_ready_seconds", "mttr_seconds",
        "baseline_restoration_seconds", "user_plane_disruption_observed",
        "user_plane_disruption_seconds", "prometheus_target_down_observed",
        "prometheus_target_detection_seconds", "prometheus_target_recovery_seconds",
        "baseline_restored",
    ]
    public_rows = [{key: row[key] for key in row_fields} for row in rows]
    (results / "attempt-summary.csv").write_text(
        csv_text(row_fields, public_rows), encoding="utf-8"
    )
    component_rows = []
    for component in COMPONENTS:
        item = summary["components"][component]
        component_rows.append({
            "component": component,
            "repetitions": item["repetitions"],
            "automatic_recoveries": item["automatic_recoveries"],
            "operator_assisted_recoveries": item["operator_assisted_recoveries"],
            "mttd_median_seconds": item["mttd_seconds"]["median"],
            "replacement_ready_median_seconds": item["replacement_ready_seconds"]["median"],
            "mttr_median_seconds": item["mttr_seconds"]["median"],
            "user_plane_disruption_median_seconds": item["user_plane_disruption_seconds"]["median"],
        })
    component_fields = list(component_rows[0])
    (results / "component-summary.csv").write_text(
        csv_text(component_fields, component_rows), encoding="utf-8"
    )
    (results / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (plots / "recovery-times.svg").write_text(
        svg_grouped(summary["components"]), encoding="utf-8"
    )
    (plots / "recovery-modes.svg").write_text(svg_modes(rows), encoding="utf-8")
    (plots / "user-plane-disruption.svg").write_text(
        svg_disruption(summary["components"]), encoding="utf-8"
    )
    report = root / "reports" / "08_phase08_reliability.md"
    report.write_text(
        report_text(summary["campaign"], summary["components"], rows), encoding="utf-8"
    )
    print(f"phase08_analysis_campaign={state['campaign_id']}")
    print("phase08_analysis_conditions=pass accepted=9")
    print("phase08_analysis_outputs=pass csv=2 json=1 svg=3 report=1")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    if os.geteuid() == 0:
        print("error: analyze must run without sudo", file=sys.stderr)
        return 2
    root = parse_args().project_root.resolve()
    try:
        state, rows, summary = analyze(root)
        write_outputs(root, state, rows, summary)
    except (AnalysisError, OSError, json.JSONDecodeError, KeyError, ValueError) as error:
        print(f"error: Phase 8 analysis rejected the evidence: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
