# Project Status

Last updated: 2026-08-21

| Phase | State | Current gate |
| --- | --- | --- |
| 0 — Project governance | Complete | Local Git identity, ignore boundary, and initial technical baseline verified |
| 1 — Host preflight and decisions | Complete | Host ready; safety constraints and proposed decisions recorded |
| 2 — Container and Compose baseline | Complete | Healthy deployment, protocol/data path, persistence, recreation, and scoped cleanup verified |
| 3 — Kubernetes networking feasibility | Complete | kind transport, TUN, capability, synthetic N6, packet visibility, and scoped cleanup verified |
| 4 — Helm-managed single-UE platform | Complete | Chart, real 5G path, persistence, resource baseline, upgrade, rollback, and scoped uninstall/reinstall verified |
| 5 — Multi-UE and DNN automation | Complete | Five concurrent UEs, two isolated DNNs, negative/recovery behavior, rollback, resource observation, and clean rerun verified |
| 6 — Observability and operational visibility | Complete | Metrics, logs, dashboards, bounded cardinality, persistence, and three alert firing/resolution lifecycles verified |
| 7 — Performance and capacity experiments | Complete | Nine-condition matrix, deterministic analysis, scoped rollback, and Phase 5/6 regression verified |
| 8 — Reliability and recovery | Complete | Nine recovery conditions, MongoDB persistence, invalid-config rejection, deterministic analysis, reviewed dashboard, alert regression, Grafana soak, and final Phase 5/6 regression passed |
| 9 — CI and supply-chain security | Complete | Local privileged integration plus hosted quality, schema, policy, secret, vulnerability, image, SBOM, and negative-control gates passed |
| 10 — Documentation and public release | Complete | Bounded claims, privacy, visuals, clean clone, fresh deployment/teardown, local privileged validation, and release audit passed; publication remains separately authorized |

Pinned Docker Engine `29.7.1`, containerd `2.2.6`, Buildx `0.36.0`, and Docker
Compose `5.3.1` are installed. The interactive account was not added to the
root-equivalent `docker` group. Integrity-checked before/after snapshots show
expected Docker bridge/firewall additions and no disruption to the existing
host Open5GS, MongoDB, or LXC services.

Phase 2 is complete. Three pinned Linux/AMD64 project images and the pinned
MongoDB image produced a healthy Compose topology. A synthetic UE registered,
established an IPv4 session, and passed bidirectional HTTP and ICMP traffic
through the UPF. MongoDB persistence, teardown/recreation, complete scoped
cleanup, and post-cleanup host state were verified. No Compose container,
network, or volume remains. See the
[container report](../reports/02_container_baseline.md) and [Compose
topology](architecture/phase-02-compose-topology.md).

Phase 3 is complete. Checksum-pinned `kind` 0.32.0 and `kubectl` 1.36.1 were
installed as standalone binaries, and the digest-pinned Kubernetes 1.36.1 node
image created the named, single-node `cn5g` cluster. The API server was bound
to loopback, the Pod and Service ranges were `10.244.0.0/16` and
`10.96.0.0/16`, and no workload port was published to the host.

The feasibility probe passed direct Pod and ClusterIP Service paths for TCP,
UDP, SCTP/38412, UDP/8805, and UDP/2152. A negative TUN control failed without
`NET_ADMIN`; the positive control created a TUN interface with only
`NET_ADMIN` and the `/dev/net/tun` device mount. The routed N6 model passed a
bidirectional TCP transaction across `cn5gue0`, a synthetic IP-over-UDP/2152
tunnel, `cn5gupf0`, and an exact node return route. Both TUN receive/transmit
counters increased by five packets, and Pod/node observers recorded the outer
UDP/2152 traffic.

No container used privileged mode. TUN endpoints had only `NET_ADMIN`, packet
observers had only `NET_RAW`, and the controlled data endpoint had zero
effective capabilities. The node observer was the only host-network Pod and
shared the disposable kind node network namespace, not the Ubuntu host network
namespace.

Cleanup removed the feasibility resources, dedicated node return route,
cluster container, project kubeconfig, and verified empty kind bridge. A
same-runtime create/delete recheck reproduced cluster readiness and exact
cleanup. Integrity-checked before/after snapshots had identical interfaces,
routes, policy rules, listening services, Docker resources, and firewall rule
structure; only volatile counters, timestamps, resource usage, and display
ordering changed. ADR-0001 and ADR-0003 are accepted for the local baseline.

Phase 4 is complete. Checksum-pinned Helm 4.2.0 manages the `cn5g` chart in the
`cn5g` namespace. The release contains thirteen Deployments, one MongoDB
StatefulSet with a retained 2 GiB claim, one revision-scoped subscriber Job,
thirteen cluster-internal Services, two ConfigMaps, and a workload
ServiceAccount without Role or RoleBinding grants. The pre-created synthetic
subscriber Secret is ignored by Git and validated by content hash without
printing its values.

The real single-UE path passed SCTP association, NG Setup, 5G-AKA, NAS
security, registration, IPv4 PDU-session establishment, PFCP association and
session creation, GTP-U session creation, HTTP and ICMP N6 traffic, and
positive bidirectional UE/UPF tunnel-counter deltas. The current UE address is
dynamically allocated from `10.60.0.0/24`; Kubernetes Pod and Service
addresses remain separate routing domains. An exact protocol-186 route inside
the disposable kind node returns that UE subnet through the current UPF Pod.

UPF runs with only `NET_ADMIN`; UE runs with `NET_ADMIN` and `NET_RAW`; the
data endpoint has zero effective capabilities. No workload uses privileged
mode, host networking, a host-published port, or Kubernetes API credentials.
Stable SBI advertisements and nine NRF profiles are checked after every
controlled lifecycle operation.

MongoDB data survived Pod recreation and full Helm uninstall/reinstall with
the same claim UID and backing volume. A controlled Helm upgrade passed at
revision 10; rollback created revision 11 from the accepted revision-7 state;
uninstall removed only release-owned resources and two verified historical
Jobs while retaining the namespace, Secret, and bound claim; reinstall then
converged as a new revision-1 release and preserved the database marker.

Two ten-second cgroup v2 observations established the single-UE scheduling
baseline. The applied requests are 200 mCPU/256 MiB for MongoDB, 25 mCPU/64
MiB for the shared Open5GS control-plane profile, 20 mCPU/64 MiB for UPF,
10 mCPU/16 MiB for the controlled data endpoint, and 25 mCPU/96 MiB for each
UERANSIM workload. These measurements do not establish multi-UE capacity,
performance, high availability, or production sizing.

Phase 5 is complete. A tracked non-secret plan defines five reserved synthetic
identities: ordinals 0-2 request `internet` and ordinals 3-4 request
`enterprise`. A permission-restricted local seed deterministically derives
matching UERANSIM and Open5GS authentication material without committing or
printing K, OPc, or the seed. A five-replica UE StatefulSet binds each stable
ordinal to its exact configuration, while an idempotent Job converges exactly
five managed subscriber records.

The accepted Helm overlay runs 13 Deployments, two StatefulSets, one
revision-scoped subscriber Job, and 16 internal Services. It adds two DNN
pools (`10.60.0.0/24` and `10.61.0.0/24`), two UPF TUN interfaces, two
headless controlled endpoints, a direct headless PFCP discovery Service, and
fail-closed source-policy tables 1060 and 1061. Two ownership-marked routes in
the disposable kind node provide the return path; no workload port or route
is added to the Ubuntu host namespace.

All five UEs concurrently passed authentication, NAS security, registration,
PDU-session establishment, intended-endpoint HTTP/ICMP traffic, and positive
bidirectional TUN counters. The validator correlated five unique UE addresses
with five unique control-plane and user-plane F-SEIDs, verified healthy PFCP
peer/session programming, and denied every cross-DNN request. UPF retained
only `NET_ADMIN`, each UE retained only `NET_ADMIN` and `NET_RAW`, and both
data endpoints had zero effective capabilities.

The negative UE test denied an unprovisioned sixth identity without changing
MongoDB or disrupting the accepted five. The partial-provisioning test removed
one exact managed record, restored it through the idempotent Job, recreated
the UE/session chain, and revalidated every data path. Controlled rollback
created revision 7 from the recorded Phase 4 revision 1, preserved the exact
MongoDB claim, removed only four Phase 5-managed records, and passed the full
Phase 4 validator. A clean repeat migration then passed as revision 8.

One ten-second five-UE steady-state cgroup observation recorded MongoDB at 162
mCPU, 241 MiB current memory, and 691 MiB peak memory under its 500 mCPU/768
MiB limit. Individual UEs averaged 17-19 mCPU, used 5-10 MiB current memory,
and peaked at 11-15 MiB. These are local scheduling observations, not capacity,
throughput, availability, or production-sizing claims.

Phase 6 is complete. The core release now exposes bounded native and synthetic
telemetry, while a separate `cn5g-observability` Helm release owns Prometheus,
Grafana, Loki, Grafana Alloy, and project-scoped kube-state-metrics. Prometheus
and Loki each use a retained 2 GiB claim with 24-hour retention. Grafana is
provisioned entirely from code and remains reachable only through an explicit
loopback port-forward.

Runtime acceptance found 14 active Prometheus targets, including five UE
probe targets, with all 13 required non-exercise targets healthy. Native
Open5GS metrics reported five registered UE sessions and five active PFCP
sessions; the five source-bound user-plane probes succeeded; and the custom UE
telemetry remained at 20 series against a limit of 30. Loki returned recent
project logs, and Grafana exposed exactly two provisioned data sources and
four version-controlled dashboards.

Three controlled alert exercises each proved both firing and resolution for a
scrape-target failure, registered-UE mismatch, and user-plane probe failure.
No exercise alert remained firing afterward. All observability workloads were
Ready with zero restarts at final inspection, both telemetry claims were
Bound, the complete Phase 5 validation still passed, and the post-Phase-6 host
snapshot was captured. These results establish operational visibility for the
five-UE local baseline; they do not establish throughput, packet-loss,
long-duration retention, high availability, or production monitoring scale.

The pre-Phase-7 Stage A dashboard hardening is also complete. A scoped upgrade
to observability revision 3 left the core overlay and both telemetry claims in
place, disabled Grafana runtime plugin preinstallation/update paths, bounded
Loki results at 500 lines, and adopted a measured 192 MiB request/768 MiB
limit. Four Git-controlled dashboards now provide 48 panels across service
overview, 5G UE/DNN behavior, Kubernetes resources, and troubleshooting logs.
The 2,568-second interactive gate kept the same Grafana Pod with zero restart
increase and measured a 473.2 MiB peak, below the 80% acceptance ceiling. Full
Phase 5/6 validation, all alert lifecycles, 149 repository tests, deterministic
rendering, and privacy checks passed before the post-change snapshot.

Phase 7 defined a controlled local performance experiment without making a
carrier-capacity or production-sizing claim.
The tracked experiment contract defines 1/3/5-UE levels, three repetitions,
warm-up, measurement/cool-down windows, ICMP plus forward/reverse TCP and UDP
traffic, procedure timing, aligned Prometheus resources, abort thresholds,
raw-evidence handling, and prohibited claims. The Helm mechanism adds only
zero-capability benchmark sidecars and five per-ordinal internal DNN ports.
The exact image build/load, full Phase 5/6 regression, route-enforced one-UE
pilot, and clean restoration of the five-UE baseline passed. Runtime
acceptance required the resumable repeated matrix, deterministic analysis,
reviewed evidence, and final rollback gate.

An initial matrix campaign passed its first three conditions, then exposed a
repeatable reverse-TCP stall after session state had accumulated across scale
cycles. Its raw data is retained but excluded from performance summaries. The
corrected experiment contract now restarts both benchmark servers and then
resets the dependency-ordered 5G session chain before every condition. The
ordering ensures that the restarted UPF installs current DNN Pod addresses in
its fail-closed policy tables and removes accumulated session state as a hidden
confounding variable.

A subsequent clean one-UE condition proved that unbounded forward TCP could
complete the full 15-second interval, while unbounded reverse TCP delivered an
initial burst, collapsed to the minimum congestion window, and stopped making
progress. The failed attempt remains retained and excluded from performance
summaries. The controlled matrix now keeps forward TCP unbounded but declares
a 10 Mbit/s per-UE reverse offered load. This is a repeatable downlink
service-load test, not a claim of maximum downlink capacity.

The corrected one-UE pilot then completed the full 15-second interval in every
traffic stage. Reverse TCP delivered 9.997 Mbit/s against its declared
10 Mbit/s target with zero retransmissions; fixed-rate UDP delivered
0.9999 Mbit/s with zero loss; unbounded forward TCP delivered 88.6 Mbit/s in
that mechanism check. The route used `uesimtun0`, no container restarted, and
the five-UE baseline recovered. These pilot values validate the mechanism but
are not accepted performance results by themselves.

The accepted campaign then completed nine conditions: three repetitions at
1, 3, and 5 concurrent UEs. Deterministic analysis produced three CSV files,
one JSON summary, three SVG plots, and a sanitized report. Median unbounded
forward aggregate throughput was 114.7, 79.4, and 91.7 Mbit/s at 1, 3, and 5
UEs respectively; the decreasing per-UE share and rising retransmissions show
contention without supporting a commercial-capacity claim. Fixed reverse TCP
delivered 99.96% of its 10 Mbit/s-per-UE target, UDP delivered approximately
100% of its 1 Mbit/s-per-UE target with zero loss, and every registration and
PDU session succeeded. The analyzer reproduced byte-identical outputs across
two runs, and the repository passed 161 tests. The final scoped rollback
restored revision 12's configuration as Helm revision 16, removed the
benchmark overlay, preserved the exact MongoDB claim identity, repaired all
five sessions, and passed the complete
Phase 5 and Phase 6 regression gates. The post-Phase-7 host-state snapshot was
captured locally. Phase 7 is complete; the subsequently accepted Phase 8
runtime result is documented below.

The post-analysis Phase 7 dashboard extension was runtime-accepted on
2026-08-06 as `cn5g-observability` revision 6. It deterministically projects
the reviewed summary as 556 bounded gauges through a token-free exporter and
adds the fifth **Performance And Capacity Experiments** dashboard. The complete
Phase 5/6 validator, one reviewed-results target, five dashboard definitions,
all three alert lifecycles, and repository static gates passed. A 2,101-second
interactive Grafana soak retained the same Ready Pod with zero restarts and a
407.2 MiB peak under the 768 MiB limit.

Phase 8 runtime evidence is accepted. Its
tracked contract defines exact one-Pod AMF, SMF, and UPF faults, one pilot per
component, three measured repetitions, separate Kubernetes detection/Pod
readiness/service-recovery boundaries, a 90-second automatic-recovery window,
operator-assisted restoration, resource abort floors, and ignored raw
evidence. The lifecycle also includes separate MongoDB recreation and invalid
configuration tests.

The first AMF, SMF, and UPF mechanism pilots each restored the complete
baseline, but their reported service-recovery times were invalidated before
the matrix. The runner had treated the Prometheus HTTP instant-query
evaluation timestamp as metric-sample freshness, allowing a pre-fault gauge to
appear post-fault. The corrected contract now evaluates `timestamp(metric)`,
requires the underlying source sample to cross the fault boundary, and uses
the minimum source timestamp across all five UE probes. Changing the tracked
contract hash deliberately prevents the retained exploratory pilots from
satisfying the corrected pilot gate.

The corrected pilots passed for AMF, SMF, and UPF. Each replacement Pod became
Ready in seconds, but none of the single-replica components restored the
complete five-UE service inside the 90-second automatic observation window.
The operator-assisted dependency-ordered path restored every baseline.

Campaign `20260807T050635Z-matrix` then accepted all nine conditions: three
repetitions each for AMF, SMF, and UPF. Median MTTD was 0.177, 0.177, and
0.214 seconds; median replacement readiness was 4.481, 4.432, and 6.581
seconds; and median fully validated MTTR was 212.187, 210.757, and 210.866
seconds respectively. Median observed user-plane disruption was 119.406,
72.274, and 155.825 seconds. These are local single-node, single-replica
measurements and do not establish high availability or a production RTO.

The separate MongoDB Pod recreation preserved the exact claim identity and
all five subscriber records. Invalid Helm values and an invalid Kubernetes
Deployment were rejected through rendering/server dry run without changing
Helm revision 16. Deterministic analysis accepted all nine conditions and
generated two CSV files, one JSON summary, three SVG plots, and the sanitized
reliability report.

Those reviewed artifacts drive the accepted sixth **Reliability And Recovery**
dashboard. Its token-free exporter exposes exactly 75 bounded
`cn5g_phase08_reviewed_*` gauges and keeps detection, Pod readiness, MTTR, and
user-plane disruption as separate boundaries. Runtime validation found two
healthy reviewed-results targets, exactly 75 Phase 8 series, and all six
provisioned dashboards. The three controlled alert scenarios still fired and
resolved. A 2,606-second interactive Grafana soak retained the same Ready Pod
with zero restarts and measured a 468.6 MiB peak under the 768 MiB limit. The
complete Phase 5 and Phase 6 regression passed, and the post-Phase-8 host-state
snapshot was captured locally. Phase 8 is complete.

Phase 9 local evidence is accepted. Eleven tools were checksum-verified, all
third-party workflow actions were pinned to full commit identities, 190 tests
passed, 70 rendered resources passed Kubernetes 1.36 schema validation, and
910 policy evaluations passed. Gitleaks found no unresolved secret in 40
commits, Trivy found no unresolved fixed high/critical repository or image
finding, and representative unpinned-action, floating-image, privileged-Pod,
and synthetic-token controls were all rejected.

Five local images passed the image gate and produced five SPDX 2.3 JSON SBOMs.
The gate rejected the original Alpine 3.22.1 endpoint, rebuilt both
Alpine-based images from the official Alpine 3.22.5 security-maintenance
manifest, and promoted only the active data-network endpoint through a
reversible Helm rollout. The complete Phase 5 and Phase 6 regressions passed,
including five unique UE sessions, both DNN paths, cross-DNN isolation,
node/container metrics, centralized logs, and six dashboards. The local
privileged report also revalidated nine reviewed Phase 7 and nine reviewed
Phase 8 conditions. GitHub Actions then passed the safe, five-image supply-chain,
and aggregate release-gate jobs for the exact reviewed implementation commit,
completing Phase 9.

Phase 10 release evidence is accepted. The tracked claim contract connects
seven bounded statements to sixteen reviewable evidence files, and four
metadata-stripped Grafana captures provide a visual index without replacing
the underlying tests. A clean local clone reproduced the deterministic gates.
The destructive runtime exercise reviewed and deleted only the project-owned
kind node, created a different node identity, installed Phases 4-6 from the
tracked lifecycle, and passed the complete five-UE, two-DNN, observability,
and local privileged gates. It then removed the observability release and
telemetry data, rolled the core back through its guarded lifecycle, and proved
the named cluster, kubeconfig, node container, and empty owned network absent.
Protected host Open5GS and MongoDB services remained active. Stale ignored
checkpoints exposed by the fresh runtime were archived through lineage-aware,
fail-closed recovery actions rather than silently reused. The final audit
binds clean-clone, clean-runtime, privileged, visual, claim, and privacy
evidence to one commit. Tagging, a GitHub release, and any public image push
remain separate publication decisions.
