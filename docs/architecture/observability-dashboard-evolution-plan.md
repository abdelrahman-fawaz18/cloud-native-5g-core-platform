# Observability Dashboard Evolution Plan

## Status And Purpose

Status: planned; implementation requires explicit approval.

This document defines how the CN5G dashboards will evolve from the accepted
Phase 6 operational baseline into a realistic monitoring, performance, and
reliability interface. It deliberately separates improvements that can use
real telemetry now from panels that must wait for measured Phase 7 or Phase 8
evidence.

The objective is not to maximize the number of graphs. The objective is to
make each dashboard answer a clear operational question, guide investigation
from symptom to cause, and remain reproducible from version-controlled files.

## Non-Negotiable Rules

1. Every panel must query a real, documented data source.
2. No dashboard may contain fabricated, manually entered, or stale
   demonstration values.
3. Performance and recovery values appear only after their experiment
   methodology and evidence pass the appropriate phase gate.
4. Subscriber identities, authentication material, and unbounded network
   values must not become metric labels or published evidence.
5. Dashboard JSON, data sources, Prometheus rules, and relevant recording
   rules remain version controlled and reproducible.
6. Visual polish must reduce cognitive load; it must not hide limitations or
   convert a local measurement into a production-scale claim.
7. Every observability change must preserve the complete accepted Phase 5
   five-UE/two-DNN validation result.

These rules follow the Prometheus guidance that every unique label set creates
another time series and therefore consumes memory, CPU, disk, and network
resources. They also follow Grafana's guidance that dashboards should tell a
story, move from general to specific, use consistent meaning and units, and
provide variables and drill-down links rather than uncontrolled dashboard
duplication.

## Current Accepted Baseline

Phase 6 currently provisions four dashboards:

| Dashboard | Current purpose | Current panel count |
| --- | --- | ---: |
| CN5G Platform Overview | release and target health plus aggregate CPU/memory | 6 |
| CN5G Control and User Plane | AMF/PFCP state and UE probe behavior | 7 |
| CN5G Kubernetes Resources | readiness, restarts, claims, CPU, and memory | 5 |
| CN5G Project Logs | recent logs, log volume, and warnings/errors | 3 |

The accepted data path is:

```mermaid
flowchart LR
    K["Kubernetes API + kubelet"] --> P["Prometheus"]
    K --> KSM["kube-state-metrics"] --> P
    NF["Open5GS native metrics"] --> P
    UE["Five bounded UE probes"] --> P
    LOG["Pod logs + Events"] --> A["Grafana Alloy"] --> L["Loki"]
    P --> G["Grafana"]
    L --> G
```

The baseline already proves five AMF sessions, five PFCP sessions, five
successful source-bound UE probes, bounded custom cardinality, recent log
ingestion, and tested Prometheus alert transitions. It is intentionally
sparse because Phase 6 did not fabricate performance or recovery evidence.

## Observed Hardening Defect

Interactive use exposed one real defect that must be corrected before adding
dashboard load:

| Observation | Evidence |
| --- | --- |
| Symptom | the loopback `kubectl port-forward` exited while a dashboard was open |
| Kubernetes cause | Grafana container terminated as `OOMKilled`, exit code 137 |
| Current memory limit | 384 MiB |
| Current state | Kubernetes restarted Grafana; the Pod became Ready with restart count 1 |
| Last activity before termination | project-log dashboard queries were being processed |

The port-forward did not cause the failure. It lost its backend when the
Grafana process stopped listening on port 3000. Because a port-forward is tied
to the live Pod connection, it exited and did not reconnect after Kubernetes
restarted the container.

The Grafana logs also show background plugin installation/update attempts,
including attempts incompatible with the read-only root filesystem. This
behavior adds resource use and weakens the intended immutable runtime model;
it must be disabled or otherwise explicitly controlled using supported Grafana
configuration.

## Evolution Strategy

```mermaid
flowchart LR
    A["Pre-Phase 7\nHardening + operational UX"] --> B["Phase 7\nPerformance and capacity"]
    B --> C["Phase 8\nReliability and recovery"]
    C --> D["Final release\nCurated presentation and evidence"]
```

The implementation is divided into four stages. Only Stage A should be
implemented before Phase 7.

## Stage A — Pre-Phase-7 Hardening And Operational UX

### A.1 Stabilize Grafana

The first change is operational, not visual.

Planned work:

1. verify the supported Grafana settings that disable automatic/background
   plugin installation and update checks;
2. preserve the read-only root filesystem and avoid runtime-downloaded plugin
   dependencies;
3. inspect retained Prometheus memory samples around the OOM event where
   available;
4. increase the Grafana request and limit using an explicit, reviewed values
   change—initial candidate request 192 MiB and limit 768 MiB;
5. ensure expensive Loki panels use bounded time ranges and line limits;
6. perform a minimum 30-minute interactive soak across all dashboards,
   including repeated log exploration;
7. require zero Grafana restarts, zero OOM events, and memory headroom during
   the soak; and
8. record the accepted request, limit, peak, query scope, and limitations.

The candidate memory values are not accepted until measured. If the soak peak
is too close to the limit, the values or query design must be revised before
acceptance.

### A.2 Create A Strong Service Overview

The Platform Overview should answer “is the service operating?” within a few
seconds.

Top status row:

| Panel | Source | Intended interpretation |
| --- | --- | --- |
| Core Helm/workload state | kube-state-metrics and current release validation | requested core workloads are available |
| Observability state | Prometheus target health and workload state | telemetry pipeline is operating |
| Active alerts | Prometheus | unresolved conditions requiring attention |
| Registered UEs | AMF metric | current value versus five-UE contract |
| PFCP sessions | UPF metric | current value versus five-session contract |
| User-plane paths | UE probe metric | successful paths versus five expected |

Additional overview rows:

- network-function health matrix;
- per-component restart and OOM status;
- normalized memory pressure;
- normalized CPU use;
- recent warning/error volume; and
- links to the control-plane, Kubernetes, and logs dashboards.

### A.3 Add A Network-Function Health Matrix

One table should correlate the major components instead of forcing the viewer
to compare several unrelated charts.

Proposed columns:

```text
component | desired | ready | restarts | scrape health | CPU | memory | last termination
```

The matrix should cover MongoDB, NRF, SCP, AMF, AUSF, UDM, UDR, PCF, NSSF,
SMF, UPF, gNB, both data endpoints, and the UE StatefulSet at an appropriate
aggregation level. Values must use consistent units and semantic thresholds.

### A.4 Add A Per-UE Operational Table

The table must use only fixed ordinal and DNN labels:

```text
UE ordinal | DNN | probe status | probe duration | TUN RX rate | TUN TX rate
```

It must not display IMSI, authentication material, Pod IP as a durable
identity, or other unbounded subscriber attributes. The five fixed ordinals
remain the correlation key.

### A.5 Add A DNN Comparison Row

The `internet` and `enterprise` contracts should be visually comparable:

| Signal | `internet` | `enterprise` |
| --- | ---: | ---: |
| expected UEs | 3 | 2 |
| successful probes | derived from fixed DNN label | derived from fixed DNN label |
| probe duration | aggregate over selected window | aggregate over selected window |
| TUN receive/transmit rate | derived from counters | derived from counters |
| endpoint state | Kubernetes and probe evidence | Kubernetes and probe evidence |

Cross-DNN denial remains acceptance-test evidence rather than a continuously
generated traffic panel unless a safe, bounded runtime isolation probe is
designed and approved.

### A.6 Normalize Resource Views

Raw byte and CPU values remain available, but the primary operational panels
should show pressure relative to the declared contract:

- current memory divided by Kubernetes memory limit;
- current CPU relative to request and limit, clearly labeled;
- restart count and last termination reason;
- desired versus available replicas;
- Prometheus and Loki storage usage where the kubelet exposes valid volume
  metrics; and
- target scrape duration and scrape health.

Percentages must use a 0-100% display while their PromQL calculation remains a
0-1 ratio. “No limit” must not be rendered as zero or as a healthy percentage.

### A.7 Improve Logs And Correlation

The logs dashboard should gain:

- warning/error volume over time by component;
- component and severity variables;
- bounded views for registration/authentication signals;
- bounded PFCP/session signals;
- Kubernetes restart and scheduling Events;
- direct links from component/resource panels to the matching log filter; and
- clear instructions explaining time-range and line-limit effects.

Raw message content remains in Loki only. Published documentation and
screenshots must be sanitized.

### A.8 Add Variables, Navigation, And Explanations

Planned fixed or query-backed variables:

- `component`;
- `ue_ordinal` from the fixed set 0-4;
- `dnn` from the fixed set `internet` and `enterprise`; and
- data source only if it materially improves reuse without weakening the
  fixed deployment contract.

Every dashboard should contain:

- a short text panel stating its purpose and limitations;
- consistent dashboard links for Overview, 5G, Kubernetes, and Logs;
- panel descriptions defining the query and healthy interpretation;
- correct units for seconds, bytes, bytes/second, packets/second, and ratios;
- consistent thresholds and value mappings;
- a sensible default time range and refresh interval; and
- no browser-only edits—the checked-in JSON remains authoritative.

### A.9 Pre-Phase-7 Dashboard Set

Stage A retains four dashboards but strengthens their roles:

```text
1. CN5G Service Overview
2. CN5G Control, Sessions, UEs, And DNNs
3. CN5G Kubernetes Resources
4. CN5G Logs And Troubleshooting
```

Avoiding premature dashboard sprawl is deliberate. New dashboards are added
only when a new phase creates a distinct operational question and evidence
model.

## Stage B — Phase 7 Performance And Capacity Dashboard

This dashboard must not be created with placeholder values. It is added only
after Phase 7 defines the traffic generator, topology, offered load, warm-up,
measurement window, repetition count, failure criteria, and summary format.

Planned evidence:

- idle versus active baseline;
- concurrent UE/load level;
- registration attempts, successes, failures, and success ratio;
- PDU-session attempts, successes, failures, and success ratio;
- registration and session-establishment duration distributions;
- throughput and goodput;
- packet loss, ICMP round-trip time, and jitter where measured;
- per-component CPU and memory aligned to the traffic window;
- UPF saturation and bottleneck indicators;
- median, percentile, variance, and outlier views across repetitions; and
- links to the exact experiment definition and reviewed report.

Proposed name: **CN5G Performance And Capacity Experiments**.

Dashboard panels should consume reviewed machine-readable summaries or
time-aligned experiment metrics. They must not silently mix separate runs or
present a best run as a general result.

## Stage C — Phase 8 Reliability And Recovery Dashboard

This dashboard is added only after controlled AMF, SMF, UPF, and selected
stateful recovery experiments pass.

Planned evidence:

- experiment and fault identifier;
- healthy baseline timestamp;
- fault injection timestamp;
- Prometheus alert/detection timestamp;
- Kubernetes restart and readiness transitions;
- UE registration and session behavior during the fault;
- user-plane interruption start and end;
- recovery validation timestamp;
- Mean Time To Detect (MTTD);
- Mean Time To Recover (MTTR);
- blast radius and affected DNN/UE count; and
- baseline-restoration result.

Proposed name: **CN5G Reliability And Recovery**.

Annotations should mark controlled experiment boundaries so that an operator
can correlate metrics and logs without guessing when the fault occurred.

## Stage D — Final Release Presentation

After the later phase gates, perform one final curation pass:

- ensure the Service Overview remains understandable in under one minute;
- remove redundant or unused panels;
- use consistent layout, typography, units, colors, and naming;
- ensure dashboard-to-runbook and dashboard-to-report links resolve;
- preserve sanitized screenshots for selected accepted states;
- document how each screenshot was generated and what it proves;
- include explicit local-lab limitations; and
- confirm a clean-clone deployment recreates the same dashboards.

The final expected family is:

```text
CN5G Dashboards
├── Service Overview
├── Control, Sessions, UEs, And DNNs
├── Kubernetes Resources
├── Logs And Troubleshooting
├── Performance And Capacity Experiments       (Phase 7 evidence)
└── Reliability And Recovery                   (Phase 8 evidence)
```

## Visual Design Standard

### Information hierarchy

Each operational dashboard follows this order:

```text
summary status -> affected scope -> trend -> resource/context -> logs/runbook
```

### Color semantics

- green: healthy or within an accepted bound;
- amber: warning, pressure, or degraded state;
- red: failed, unavailable, or breached accepted bound;
- neutral blue/gray: informational values without pass/fail meaning.

Color must never be the only carrier of meaning. Text, value mappings, or
icons must state the condition.

### Units and axes

- duration: seconds or milliseconds, selected consistently per panel;
- memory/storage: IEC bytes (MiB/GiB);
- throughput: bits/second or bytes/second, explicitly labeled;
- packet rate: packets/second;
- ratios: percent in the UI, ratio in metrics/PromQL; and
- counters: rates for operational trends, raw totals only when the total is
  itself meaningful.

Avoid mixing unrelated units on one axis and avoid stacking series where the
stack could hide an individual failure.

### Refresh and query bounds

- default refresh should reflect the 15-second scrape interval and avoid
  unnecessary backend load;
- Loki queries must use explicit time and line bounds;
- expensive panels should not refresh faster than their data changes;
- overview panels should prefer bounded aggregations or reviewed recording
  rules; and
- dashboard variables must not generate unbounded query combinations.

## Implementation Sequence For Stage A

After explicit approval, implement Stage A in this order:

1. capture the current Grafana Pod identity, restart/OOM state, resources, and
   relevant Prometheus memory history;
2. update Grafana runtime settings and candidate resource values;
3. add or revise only the Prometheus queries/recording rules required by the
   approved panels;
4. redesign the Service Overview;
5. add the component matrix, per-UE table, and DNN comparison;
6. normalize the Kubernetes resource dashboard;
7. improve bounded log correlation;
8. add variables, links, descriptions, units, and thresholds;
9. extend static tests for every required panel, query, UID, variable,
   cardinality boundary, and security constraint;
10. run strict Helm lint, deterministic render, YAML/JSON parsing, shell
    syntax, links, and privacy checks;
11. perform server-side dry-run and controlled Helm upgrade;
12. run complete Phase 5 and Phase 6 validation plus all alert lifecycles;
13. perform the interactive Grafana soak and verify zero restarts/OOMs;
14. capture a sanitized summary and selected screenshot evidence; and
15. update the Phase 6 documentation with the accepted hardening result.

## Stage A Acceptance Gate

Stage A is accepted only when all of the following pass:

- Grafana remains Ready with zero new restarts during the interactive soak;
- background plugin installation/update activity is disabled or explicitly
  controlled and reproducible;
- all four dashboards are recreated from Git-controlled JSON;
- every required panel returns live data or an intentional, clearly rendered
  empty state;
- five AMF/PFCP sessions and five UE probes remain visible;
- the per-UE and DNN views use only bounded labels;
- custom metric cardinality remains within the accepted bound;
- Prometheus, Loki, and Grafana validation passes;
- all tested alerts still fire and resolve;
- the full Phase 5 five-UE/two-DNN validator passes;
- no subscriber material, local identity, raw log, or kubeconfig enters Git;
  and
- the post-change working tree and published documentation are clean.

## Rollback

Before the Stage A Helm upgrade, record the core and observability release
revisions and current resource settings. If acceptance fails:

1. preserve scoped diagnostics from the exact failed workload;
2. roll back only the observability release to its recorded revision;
3. restore the previous core overlay only if the UE probe configuration
   changed;
4. verify both retained observability PVC identities;
5. rerun the complete Phase 5 validator; and
6. confirm that no host route, service, package, Docker resource, subscriber
   Secret, or MongoDB claim changed.

No broad Kubernetes, Docker, volume, image, or host cleanup is part of this
rollback.

## Source Guidance

- [Grafana dashboard best practices](https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/best-practices/)
  describes story-driven dashboards, reduced cognitive load, variables,
  drill-downs, consistent design, and version-controlled JSON.
- [Grafana variables](https://grafana.com/docs/grafana/latest/visualizations/dashboards/variables/)
  documents query-backed dashboard controls and reusable views.
- [Prometheus instrumentation practices](https://prometheus.io/docs/practices/instrumentation/)
  explains counters, gauges, rates, default series, and cardinality control.
- [Prometheus metric and label naming](https://prometheus.io/docs/practices/naming/)
  documents base units and the cost of high-cardinality labels.
- [Kubernetes resource monitoring](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-usage-monitoring/)
  distinguishes basic resource metrics from a richer monitoring pipeline.

## Approval Boundary

Creating this plan does not authorize a Helm change, Grafana configuration
change, dashboard JSON modification, cluster mutation, or resource-limit
change. Explicit approval is required before Stage A implementation begins.
