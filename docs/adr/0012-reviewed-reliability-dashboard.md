# ADR-0012: Reviewed Reliability Evidence In The Operational Dashboard

## Status

Accepted on 2026-08-07 after deterministic analysis accepted all nine resilience campaign
conditions.

## Context

The resilience campaign experiments retained detailed Kubernetes events, Prometheus
ranges, Loki logs, Pod identities, and validation output locally. Those raw
artifacts are valuable for audit and troubleshooting but are unsuitable for a
stable public dashboard: they contain ephemeral identities, expire with the
24-hour telemetry retention window, and can expose local paths.

The dashboard also must not confuse three different boundaries:

- Kubernetes detecting the fault;
- the replacement Pod becoming Ready; and
- all component-specific 5G signals and five UE paths recovering.

Publishing live recovery panels before a complete reviewed campaign would
permit partial or exploratory attempts to look like accepted evidence.

## Decision

Generate an immutable, bounded Prometheus fixture only from
`benchmarks/resilience/results/summary.json` after its campaign state is
`reviewed_complete`. A separate least-privileged exporter serves exactly 75
`cn5g_resilience_reviewed_*` gauge series. The exporter has no Kubernetes API
token, drops every Linux capability, uses a read-only root filesystem, and
receives only the generated metric ConfigMap.

Provision **CN5G Reliability And Recovery** as the sixth Grafana dashboard.
It presents reviewed medians and distributions for Mean Time To Detect (MTTD),
replacement Pod readiness, Mean Time To Recover (MTTR), user-plane disruption,
recovery mode, baseline restoration, and MongoDB PersistentVolumeClaim (PVC)
preservation. Every panel labels the results as one local, single-node,
single-replica campaign rather than live availability or a production
Recovery Time Objective.

Advance the observability chart to `0.3.0`. Preserve the immutable Prometheus
and Loki claim-template lineage labels at `0.1.0`; only mutable workload and
Release labels advance to the current chart version.

## Alternatives Considered

### Keep resilience campaign only in the Markdown report

This is safe but makes the most important recovery boundaries harder to
compare and leaves the provisioned dashboard family incomplete.

### Query the original raw campaign directly

Rejected because raw evidence is intentionally ignored, contains ephemeral
runtime details, and is not a durable Grafana data source.

### Reconstruct recovery values from current live telemetry

Rejected because the experiment windows have expired and repeating static
gauges is different from repeating controlled faults. A dashboard must not
invent historical timing from current steady-state signals.

### Merge performance campaign and resilience campaign into one reviewed-results exporter

Rejected because separate targets make provenance, cardinality, health, and
rollback boundaries explicit. Each capability can be regenerated and validated
independently.

## Evidence

- Campaign `20260807T050635Z-matrix` completed with nine accepted conditions.
- The deterministic analyzer generated two CSV files, one JSON summary, three
  SVG plots, and one reliability report.
- All AMF, SMF, and UPF attempts preserved the MongoDB PVC and restored the
  complete platform and observability baseline.
- The generated metric fixture contains exactly 75 series under a hard limit
  of 100 and contains no subscriber identity, Pod identity, PVC UID, or local
  path.
- Static tests require the generator, exporter security context, target,
  dashboard queries, six-dashboard navigation, and immutable claim lineage.

## Consequences

- Reviewed recovery evidence remains visible after raw telemetry expires.
- Operators can see why a Ready Pod did not imply recovered 5G service.
- One additional tiny Deployment, Service, ConfigMap, and Prometheus target
  are added to the observability namespace.
- The dashboard is historical reviewed evidence, not a live incident timeline.
- A new resilience campaign requires deterministic re-analysis and metric
  regeneration before the displayed values change.

## Reversal Or Migration

Roll back only the `cn5g-observability` Helm release to its prior revision.
Prometheus and Loki PVC identities remain unchanged because their retained
claim-template specifications are not modified. Re-run the complete observability stack
validator after rollback. Removing the reviewed dashboard does not change the
5G Core release, subscriber state, host routes, or raw resilience campaign evidence.
