# ADR-0010: Reviewed Performance Evidence In The Operational Dashboard

## Status

Accepted on 2026-08-06.

## Context

Performance campaign produced one accepted nine-condition performance campaign, then
deliberately removed its benchmark sidecars and restored the permanent platform
service. Prometheus retains only 24 hours of local samples. A durable Grafana
view therefore cannot depend on the temporary benchmark targets or on raw time
series that will expire.

The dashboard must remain derived from reviewed evidence, distinguish completed
experiment results from live service state, avoid subscriber or unbounded
labels, and fit the single-node resource budget. The observability release also
contains retained Prometheus and Loki claim templates created by chart 0.1.0;
Kubernetes makes their StatefulSet claim-template specification immutable.

## Decision

Generate a bounded Prometheus text fixture deterministically from the tracked
`reviewed_complete` performance campaign summary. The generator validates the schema, the
1/3/5 UE levels, three repetitions per level, nine accepted conditions, and the
resource summary before producing exactly 556
`cn5g_performance_reviewed_*` gauge series under a hard limit of 600.

Serve the fixture from a dedicated observability Deployment and ClusterIP
Service. The exporter receives no Kubernetes token, runs as a non-root fixed
identity, drops all Linux capabilities, disables privilege escalation, uses a
read-only root filesystem, and copies the ConfigMap into a bounded memory
volume. Prometheus scrapes it every 15 seconds. Grafana provisions a fifth
dashboard that uses instant queries and a fixed 1/3/5 selector; explanatory
panels state that the values describe one completed local campaign rather than
a live speed test or capacity promise.

Advance the observability chart to 0.2.0 while keeping only the immutable Loki
and Prometheus `volumeClaimTemplates` lineage label at its originally accepted
`cn5g-observability-0.1.0` value. StatefulSet, Pod, Service, ConfigMap, and
other current workload labels use 0.2.0. Before a real upgrade, run both a
generic Kubernetes server-side dry run under Helm's existing field-manager
identity and Helm's native server dry run. Never use force-conflict takeover.

## Alternatives Considered

- Keep the temporary benchmark sidecars running. Rejected because it changes
  the permanent service, consumes resources, and confuses experiment tooling
  with an operational dependency.
- Query retained raw Prometheus samples. Rejected because the 24-hour retention
  boundary would make the dashboard disappear and separate campaigns could be
  mixed accidentally.
- Copy result values into Grafana text or JSON manually. Rejected because it
  breaks deterministic traceability to the reviewed summary.
- Add a database or general-purpose metrics gateway. Rejected as unnecessary
  state, privileges, and operational cost for 556 immutable gauges.
- Change or recreate the retained StatefulSet claim templates during the chart
  upgrade. Rejected because Kubernetes forbids the update and claim recreation
  would introduce avoidable data risk.
- Use `--force-conflicts`. Rejected because it could seize ownership of fields
  managed by another controller and would not make immutable StatefulSet fields
  safely mutable.

## Evidence

- deterministic generator checks produced exactly 556 series;
- strict Helm lint, deterministic render, YAML/JSON parsing, privacy checks,
  link checks, and 164 repository tests passed;
- two guarded upgrade failures rolled back automatically without changing the
  accepted service or telemetry claims;
- Helm's native server dry run passed after the immutable lineage correction;
- observability revision 6 deployed with one Ready token-free exporter and
  replaceable Service ClusterIP `10.96.38.108`;
- the complete platform and observability validator found one healthy reviewed-results target,
  nine accepted conditions, three repetitions, 556 series, and five dashboards;
- all three alert scenarios fired and resolved; and
- a 2,101-second interactive Grafana soak recorded zero restarts and a 407.2
  MiB peak under the 768 MiB limit.

## Consequences

The reviewed experiment stays visible after benchmark rollback and raw-sample
expiry, while its evidence lineage remains reproducible from Git. The
operational dashboards gain one small Deployment, Service, target, ConfigMap,
and 556 time series. Repeated scrapes intentionally duplicate constant gauges
through the 24-hour retention window; the dashboard uses instant comparisons
so this does not look like continuously remeasured performance.

The retained claim-template label is intentionally historical and differs from
the current chart label. Static tests must preserve that narrow exception.
Future summary-schema or metric changes require deterministic regeneration,
cardinality review, dashboard tests, a chart upgrade, full regression, alert
lifecycles, and an interactive Grafana gate.

## Reversal Or Migration

Roll back only the observability Helm release to its recorded prior revision,
then verify the two retained telemetry claim identities and rerun the complete
Platform validator. Removing the exporter and fifth dashboard does not require
changing the core release, host networking, subscriber Secret, MongoDB claim,
or accepted performance campaign report. A future long-term evidence backend may replace the
static exporter only after it preserves the same reviewed/raw distinction,
privacy boundary, and reproducible traceability.
