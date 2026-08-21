# Dashboard Design and Evidence Standard

## Purpose

The dashboard suite is an operational interface and an evidence presentation
layer. It must help an operator move from platform status to a specific UE,
DNN, component, resource, or log signal without turning local measurements
into production claims.

Grafana definitions, datasources, Prometheus rules, and reviewed-result metric
fixtures are version controlled. Screenshots prove that the provisioned
interface rendered; the underlying metrics, experiment summaries, and
validators remain the sources of truth.

## Dashboard set

| Dashboard | Question it answers |
| --- | --- |
| Service Overview | Is the mobile service and telemetry pipeline operating now? |
| Control, Sessions, UEs, and DNNs | Which subscriber path or DNN is affected? |
| Kubernetes Resources | Is scheduling pressure, restart behavior, or a target failure involved? |
| Logs and Troubleshooting | Which component or procedure explains the symptom? |
| Performance and Capacity Experiments | What did the accepted 1/3/5-UE campaign measure? |
| Reliability and Recovery | What happened after controlled AMF, SMF, and UPF faults? |

The first four query live service state. The last two query immutable,
bounded metrics generated from reviewed machine-readable summaries. Their
titles and descriptions identify them as historical experiments, not live
tests.

## Information hierarchy

Operational dashboards follow a stable reading order:

```text
service summary
  -> affected scope
  -> time trend
  -> component and resource context
  -> logs, report, or runbook
```

The overview must be understandable quickly without hiding detail needed by a
technical reviewer. Deeper dashboards expose per-UE state, DNN comparison,
component health, normalized CPU/memory pressure, restart and OOM evidence,
bounded log queries, and Kubernetes Events.

## Data rules

1. Every panel queries a documented datasource and real tracked metric.
2. No panel contains fabricated or manually entered demonstration values.
3. Reviewed experiment values appear only after the exact campaign and
   deterministic analyzer pass.
4. Subscriber identifiers, authentication material, and unbounded values are
   prohibited metric labels and screenshot content.
5. Variables, time windows, and Loki line counts are bounded.
6. A missing signal renders as an explicit empty or failed state; it is not
   converted into a healthy value.
7. Color is never the only carrier of meaning.

## Visual language

The interface uses Grafana's normal typography and a restrained operational
palette:

- green: within an accepted service contract;
- amber: pressure, warning, or degraded state;
- red: failed or outside the accepted contract;
- blue/gray: informational values without pass/fail meaning.

Units remain consistent: milliseconds or seconds for duration, MiB/GiB for
memory, bits per second for throughput, packets per second for rates, and
percent for ratios. Unrelated units do not share an axis. Raw totals appear
only when the total itself has operational meaning.

## Cardinality and query cost

UE metrics use ordinal and DNN labels rather than IMSI or session-address
labels. The live custom UE set is limited to 30 series. Reviewed performance
and resilience exporters have separate enforced limits of 600 and 100 series.

The default refresh interval reflects the 15-second scrape interval. Loki
queries have explicit time and line limits. Reviewed dashboards change only
when a new summary is deliberately regenerated, so they do not need rapid
refresh.

## Runtime hardening

Grafana runs with plugin installation and update paths disabled, a read-only
root filesystem, a 192 MiB memory request, and a 768 MiB limit. The accepted
interactive soak kept one Ready Pod with zero restart increase for 2,606
seconds and observed a 468.6 MiB peak.

This setting is evidence for the local six-dashboard workload. It is not a
general Grafana sizing recommendation.

## Screenshot publication

Four views are preserved because each contributes different information:

1. healthy service overview;
2. per-UE and two-DNN behavior;
3. reviewed performance evidence;
4. reviewed resilience evidence.

Before publication, each capture is inspected for credentials, usernames,
local paths, subscriber identities, browser chrome, unrelated applications,
and misleading time windows. PNG metadata is stripped. The evidence manifest
records dashboard UID, source JSON, dimensions, checksum, role, and meaning.

The root README uses all four in two compact comparison rows. The
[dashboard gallery](../dashboard-gallery.md) provides the larger views,
interpretation, provenance, and limitations.

## Acceptance checks

- all six dashboards are provisioned from the chart;
- exactly two datasources are configured;
- every required target is healthy;
- live and reviewed metric cardinality remains below its bound;
- recent project logs are queryable;
- all three alert scenarios fire and resolve;
- the full five-UE/two-DNN validator still passes;
- Grafana completes the interactive soak with zero restart increase and
  memory headroom; and
- dashboard JSON, screenshot links, checksums, and privacy checks pass from a
  clean checkout.
