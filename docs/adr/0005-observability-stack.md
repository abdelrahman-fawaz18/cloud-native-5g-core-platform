# ADR-0005: Metrics, Logs, Dashboards, And Alerts Stack

## Status

Accepted

## Context

The project must distinguish Kubernetes workload health from 5G registration,
session, and user-plane health. It needs reproducible metrics, searchable logs,
dashboards, and alerts without consuming enough resources to distort a
single-host experiment.

Promtail was named as an early logging option in the planning package, but it
reached end of life on 2026-03-02. Current Grafana documentation recommends
Grafana Alloy for sending logs to Loki.

## Decision

- Use Prometheus for metrics and alert rules.
- Use Grafana for provisioned data sources and dashboards.
- Use a single-replica Loki deployment for bounded local log storage.
- Use Grafana Alloy, deployed with the minimum required Kubernetes access, to
  collect project workload logs and forward them to Loki.
- Do not introduce Promtail.
- Prefer a small, project-scoped configuration over an unmodified full-cluster
  monitoring bundle. Add Kubernetes/node/container exporters only when their
  signal is required by an acceptance criterion.
- Start with 24-hour retention and explicit disk/memory limits. Recalculate
  limits from observed ingestion before performance testing.
- Keep high-cardinality per-UE detail in logs and reports; expose bounded
  aggregate metrics unless a cardinality review approves otherwise.
- Pin every image by version and release-baseline digest in Phase 6.
- Run the stack as a separate `cn5g-observability` Helm release and namespace.
- Collect node/container metrics through the authenticated API proxy and logs
  through the Kubernetes API rather than host mounts.
- Defer Alertmanager until a notification receiver and credential boundary
  are approved; Prometheus evaluates and tests rules in this phase.

## Alternatives Considered

- **Promtail:** familiar Loki collector, but now unsupported and end of life.
- **Full kube-prometheus stack immediately:** feature-rich but potentially too
  heavy and broad for the initial single-node scope.
- **OpenTelemetry Collector for logs:** viable and vendor-neutral, but Alloy is
  the primary path recommended by Loki documentation and supports the required
  Kubernetes log pipeline.
- **Container logs only:** low overhead, but not centrally searchable or
  sufficient for cross-component incident correlation.

## Evidence

- [Promtail documentation](https://grafana.com/docs/loki/latest/send-data/promtail/)
  records its end-of-life date and directs users to Alloy.
- [Loki Alloy documentation](https://grafana.com/docs/loki/latest/send-data/alloy/)
  recommends Alloy as the primary log-ingestion method.
- [Grafana Alloy documentation](https://grafana.com/docs/alloy/latest/collect/logs-in-kubernetes/)
  documents Kubernetes log collection.
- The accepted Phase 5 preflight observed about 8 GiB available memory and
  28 GiB free Docker filesystem space, requiring bounded retention, explicit
  resource limits, and staged deployment.
- Registry identities are pinned in `versions/phase-06.env`; both charts pass
  strict linting, deterministic rendering, and Kubernetes server-side dry-run.
- Live acceptance on 2026-08-05 verified 14 active Prometheus targets, all 13
  required targets healthy, five UE probe targets, five AMF sessions, five
  PFCP sessions, 20 bounded custom UE series, recent Loki ingestion, two
  Grafana data sources, four dashboards, and three alert firing/resolution
  lifecycles.
- Prometheus reported no firing exercise alert after the lifecycle test, all
  observability workloads were Ready with zero restarts, and both 2 GiB
  telemetry claims were Bound.

## Consequences

The stack covers the required metrics, logs, dashboards, and alerts with
supported components. It adds storage, memory, permissions, and label-design
work. Single replicas demonstrate observability behavior, not high
availability.

The accepted implementation also records two compatibility constraints:
kube-state-metrics exposes startup health on the metrics listener and
readiness on its telemetry listener, while Prometheus 3 requires an explicit
fallback scrape protocol for the deliberately minimal alert-exercise
exporter. Both constraints are encoded in the chart and protected by tests.

## Reversal Or Migration

All components remain project-scoped and can be removed by the exact Helm
release/namespace after inspecting owned PersistentVolumeClaims. A future
collector or backend requires equivalent query, alert, retention, resource,
and recovery tests before replacement.
