# Reports

This directory contains concise, sanitized validation, performance,
reliability, security, and release-readiness reports. Raw terminal transcripts
do not belong here.

Every report must state its method, result, supporting evidence, limitations,
and whether the tested gate passed or failed.

## Current Reports

- [Host preflight](01_host_preflight.md)
- [Phase 2 container baseline](02_container_baseline.md)
- [Phase 4 single-UE Kubernetes validation summary](#phase-4-single-ue-kubernetes-validation-summary)
- [Phase 5 multi-UE and DNN validation summary](#phase-5-multi-ue-and-dnn-validation-summary)
- [Phase 6 observability validation summary](#phase-6-observability-validation-summary)
- [Phase 7 performance and capacity experiment report](07_phase07_performance.md)
- [Phase 8 reliability and recovery experiment report](08_phase08_reliability.md)

The validation evidence below is paired with the
[complete Phase 4 visual system guide](../docs/README.md#23-phase-4-complete-system-and-operational-model),
which explains how the accepted objects, networks, protocols, storage,
security controls, and lifecycle operations connect.

## Phase 4 Single-UE Kubernetes Validation Summary

Validated on 2026-08-04 with Helm 4.2.0, kind 0.32.0, Kubernetes 1.36.1,
Open5GS 2.7.7, UERANSIM 3.2.8, MongoDB 8.0.28, and the repository-owned
data-network 0.1.0 image. Immutable inputs and accepted identities are recorded
in `versions/phase-02.env`, `versions/phase-03.env`, and
`versions/phase-04.env`.

### Method

The test loaded only accepted image identities into the named kind node,
verified the permission-restricted synthetic subscriber Secret, performed a
Helm server-side dry run, installed the `cn5g` chart, waited for the exact
subscriber Job and every workload, and reconciled service discovery and the
5G session chain. `scripts/validate-kubernetes.sh` then evaluated Kubernetes
state, component logs, network state, application traffic, TUN counters, and
effective Linux capabilities. Separate lifecycle operations recreated the
MongoDB Pod, upgraded the release, rolled it back, uninstalled/reinstalled it,
and checked the same claim and database marker after each boundary.

### Result

| Gate | Accepted evidence |
| --- | --- |
| Packaging | Strict Helm lint and deterministic rendering passed; invalid values were rejected by schema tests |
| Workloads | Thirteen Deployments and one MongoDB StatefulSet reached Ready; the exact revision-scoped subscriber Job completed |
| Service discovery | All nine SBI functions advertised stable Service DNS names and the NRF exposed nine matching profiles without stale Pod addresses |
| N2 | SCTP association and NG Setup passed between the gNB and AMF |
| Subscriber security | Synthetic subscriber record, 5G-AKA, NAS security, and registration passed |
| Session control | IPv4 PDU session, PFCP association/session, and GTP-U session evidence passed |
| User plane | HTTP and ICMP transactions passed through the UE TUN, gNB, N3 GTP-U, UPF, N6, and controlled data endpoint |
| Bidirectionality | UE and UPF receive/transmit counters each increased by at least eight packets during controlled traffic |
| N6 return path | One ownership-marked route inside the kind node returned `10.60.0.0/24` through the current UPF Pod |
| Least privilege | UPF effective capabilities were `0x1000`; UE was `0x3000`; the data endpoint was zero; no workload was privileged |
| Persistence | The same MongoDB claim UID and backing volume survived Pod recreation, upgrade, rollback, and Helm uninstall/reinstall |
| Release lifecycle | Upgrade passed at revision 10; rollback restored revision-7 configuration as revision 11; reinstall converged as a fresh revision 1 |
| Cleanup scope | Uninstall removed the release and two verified historical Jobs while retaining the bound claim, namespace, and subscriber Secret |

The final fresh-install validation ended with
`kubernetes_validation=pass` and `phase04_validation=pass`.

### Resource Baseline

Two ten-second cgroup v2 samples were collected in the validated single-UE
steady state. MongoDB averaged 143-170 mCPU with 217-222 MiB current and
380-381 MiB peak memory. Open5GS control-plane functions averaged 12-22 mCPU
and used 6-40 MiB. UPF averaged 14 mCPU and used 7-17 MiB across the samples.
The data endpoint averaged 6-8 mCPU and used 3-8 MiB. gNB averaged 11-15 mCPU
and used 7-17 MiB; UE averaged 16-17 mCPU and used 9-12 MiB.

The accepted requests are documented in `charts/cn5g/values.yaml`. The second
sample confirmed that they were applied and that every measured average and
current-memory value remained below its request. Memory peaks remained below
limits. This observation defines scheduling inputs for the single-UE baseline;
it is not a capacity or performance benchmark.

### Limitations

The result covers one synthetic UE on one local node and one replica per
component. It does not demonstrate multi-node rescheduling, high availability,
production storage, external RAN integration, multi-UE concurrency,
differentiated DNN/slice behavior, carrier-grade throughput, or production
security posture. The local-path PersistentVolume does not survive deletion
of the kind node. Those boundaries prevent the report from being interpreted
as a production-readiness or scale claim.

## Phase 5 Multi-UE And DNN Validation Summary

Validated on 2026-08-05 as Helm revision 8 on the accepted Phase 4 kind
cluster. The [Phase 5 visual and operational model](../docs/README.md#31-phase-5-multi-ue-and-dnn-implementation-model)
explains the identity pipeline, StatefulSet mapping, DNN routing, PFCP
discovery, recovery order, and lifecycle boundaries behind this summary.

### Method

The test generated permission-restricted subscriber material from a tracked
synthetic plan and an ignored local seed, created a pre-existing Secret,
server-side dry-ran and applied the Phase 5 Helm overlay, and converged the
core before starting five StatefulSet UE replicas. Validation correlated
runtime UE configuration, MongoDB records, Open5GS logs, routes, endpoint
responses, TUN counters, and effective Linux capabilities. Separate tests
introduced an unprovisioned sixth UE and one missing managed database record.
The release was then rolled back to Phase 4 and migrated to Phase 5 again.

### Result

| Gate | Accepted evidence |
| --- | --- |
| Workloads | 13 Deployments, two StatefulSets, one completed revision-scoped Job, 16 Services, and five Ready UE replicas |
| Identity | five distinct synthetic subscribers mapped to stable ordinals 0-4; database contained exactly five managed records |
| DNN selection | three `internet` UEs received unique `10.60.0.x/24` addresses; two `enterprise` UEs received unique `10.61.0.x/24` addresses |
| 5G control | N2 SCTP, NG Setup, nine NRF profiles, PFCP health, PDU sessions, and five distinct UP/CP F-SEIDs passed |
| User plane | intended HTTP and ICMP passed for all five UEs; every UE TUN RX/TX counter increased |
| Isolation | all five cross-DNN HTTP attempts were denied by source-policy routing |
| N4 behavior | SMF reached the UPF through a headless PFCP Service resolving directly to the UPF Pod address |
| Least privilege | UPF had `NET_ADMIN`; all UEs had `NET_ADMIN` and `NET_RAW`; data endpoints had zero effective capabilities |
| Invalid identity | a sixth unprovisioned UE was denied, produced no database side effect, and did not disrupt the five valid UEs |
| Recovery | an idempotent Job restored one deliberately missing managed record and full five-UE validation passed afterward |
| Lifecycle | MongoDB PVC identity survived migration and rollback; Phase 4 passed after rollback; the repeat Phase 5 migration passed at revision 8 |

The final command ended with `phase05_validation=pass` and
`phase05_upgrade=pass`.

### Resource Observation

A ten-second cgroup v2 observation was collected after full five-UE validation.
MongoDB averaged 162 mCPU, used 241 MiB current memory, and reached 691 MiB
peak memory. The five UE Pods each averaged 17-19 mCPU, used 5-10 MiB current
memory, and reached 11-15 MiB peak memory. Open5GS functions averaged 15-22
mCPU, while the UPF averaged 15 mCPU; current memory was 5-20 MiB for the
control plane and 7 MiB for the UPF. The two DNN endpoints averaged 8-9 mCPU
and used 2-3 MiB current memory. All observed peaks remained below declared
limits.

### Limitations

This result proves exactly five concurrent synthetic UEs, two differentiated
DNN contracts, one gNB, one UPF, one local node, and one replica per Network
Function. It does not prove general subscriber scale, performance, high
availability, multi-node scheduling, production storage, external RAN
integration, differentiated slice treatment, or production security. Numeric
GTP-U TEIDs were not exposed by the accepted INFO-level logs; the narrower
claim is five unique F-SEID/address correlations with no observed concurrent
session-collision symptom.

## Phase 6 Observability Validation Summary

The original Phase 6 release was validated on 2026-08-05 against the accepted
five-UE/two-DNN release. The pre-Phase-7 dashboard and Grafana hardening was
then accepted on 2026-08-06 as independent `cn5g-observability` revision 3;
the already-active core overlay was not upgraded. Component images and
immutable registry identities are recorded in `versions/phase-06.env`.

### Method

The lifecycle helper first ran the complete Phase 5 validator, applied the
bounded UE metrics sidecars, installed the separate observability chart, and
waited for every Deployment and StatefulSet. It then queried Prometheus target
and query APIs, Loki's query API, and Grafana's provisioning API from inside
the cluster. A separate exercise changed only a bounded synthetic metric and
waited for each real Prometheus alert to fire and resolve. Final inspection
checked release state, workload restarts, claims, active targets, 5G gauges,
probe counts, cardinality, and remaining alerts.

### Result

| Gate | Accepted evidence |
| --- | --- |
| Releases | Core Phase 6 overlay remained active; observability revision 3 `deployed` after the scoped hardening upgrade |
| Workloads | Four observability Deployments and two StatefulSets Ready with zero restarts |
| Storage | Prometheus and Loki each retained one Bound 2 GiB claim |
| Scraping | 14 active targets; all 13 required non-exercise targets healthy; five UE targets |
| 5G gauges | five active AMF sessions and five active PFCP sessions |
| User plane | five source-bound UE probes successful through the accepted session paths |
| Cardinality | 20 custom UE series, below the enforced limit of 30 |
| Logs | recent project log entries queryable from Loki |
| Dashboards | exactly two provisioned data sources and four enhanced Git-controlled dashboards containing 48 panels total |
| Alerts | target-down, UE-count mismatch, and user-plane failure each fired and resolved |
| Steady state | zero exercise alerts firing after the lifecycle test |
| Regression | complete Phase 5 registration, session, DNN isolation, and user-plane validation passed |

The install ended with `phase06_install=pass`; the repeated validator ended
with `phase06_validation=pass`; and the alert exercise ended with
`phase06_alert_lifecycle=pass tested=3`.

### Pre-Phase-7 Dashboard Hardening Result

The change disabled default runtime plugin preinstallation/update behavior,
retained the read-only root filesystem, bounded Loki results at 500 lines, and
raised Grafana from a 96 MiB request/384 MiB limit to a 192 MiB request/768
MiB limit. The four dashboards were reorganized into Service Overview; Control,
Sessions, UEs, And DNNs; Kubernetes Resources; and Logs And Troubleshooting.
They add bounded per-UE and DNN tables, component health, normalized resource
pressure, OOM/restart evidence, scrape behavior, procedure logs, Events,
variables, descriptions, and cross-dashboard navigation without adding a
subscriber identifier label.

The automated interactive gate ran for 2,568 seconds with the same Grafana Pod
identity, zero restart increase, no runtime plugin-install/update activity, and
a 473.2 MiB peak. The peak was 61.6% of the 768 MiB limit, below the enforced
80% ceiling. The Phase 5 and Phase 6 validators, current 20-series cardinality
gate, and all three alert firing-resolution cycles passed. Repository-wide
regression finished with 149 tests passing, strict Helm lint, deterministic
rendering, valid dashboard JSON, and a clean privacy scan.

### Post-Phase-7 Dashboard Extension Result

The reviewed Phase 7 summary is now projected through one token-free static
exporter and the fifth **Performance And Capacity Experiments** dashboard.
Observability revision 6 passed the complete Phase 5/6 validator with one
healthy reviewed-results target, exactly 556 reviewed series under the limit
of 600, five dashboards, and all three alert firing-resolution cycles. The
2,101-second interactive gate retained the same Ready Grafana Pod with zero
restarts and a 407.2 MiB peak, 53.0% of its 768 MiB limit. The exporter Service
used replaceable ClusterIP `10.96.38.108` in the accepted snapshot.

The chart upgrade also proved rollback safety. Two rejected attempts left the
accepted release deployed: one detected field-manager ownership and one
detected an immutable StatefulSet claim-template label. The accepted chart
preserves the original retained-claim lineage label, uses current `0.2.0`
labels elsewhere, and now exercises Helm's native server dry run before every
upgrade.

### Limitations

This is a 24-hour, single-node, single-replica local observability baseline.
The accepted 192/768 MiB Grafana settings are evidence for this topology, not
general sizing guidance.
It does not prove backend high availability, external alert delivery,
long-term retention, production access control, throughput, packet loss, or
capacity. The UE probe duration is an operational reachability signal, not a
radio or carrier-grade latency benchmark. Controlled Phase 7 performance
evidence is reported separately and remains limited to its declared local
experiment contract.
