# Engineering Handbook

This handbook explains the system as an operating platform rather than as a
sequence of implementation steps. It is intended for readers who understand
containers or networking but may not know both Kubernetes and the 5G
Standalone (SA) architecture.

For exact object, address, interface, and port inventories, use the
[complete system architecture](architecture/complete-system-architecture.md).
For commands, use [Platform operations](platform-operations.md).

## 1. System boundary

The project runs a complete, bounded 5G service on one local Kubernetes node.
Open5GS implements the core network. UERANSIM implements a simulated gNodeB
and five simulated User Equipments (UEs). MongoDB stores synthetic subscriber
records. Two controlled data endpoints represent separate external data
networks. A second Helm release owns the monitoring and logging stack.

The platform proves protocol integration and operational behavior. It does
not provide a physical radio, geographically redundant control plane,
replicated storage, Internet-facing service, commercial subscriber database,
or production capacity claim.

The default contract is:

| Item | Contract |
| --- | --- |
| Cluster | one kind control-plane node |
| Radio simulation | one UERANSIM gNodeB |
| Subscribers | five synthetic UEs with stable StatefulSet ordinals |
| Data networks | `internet` for ordinals 0–2; `enterprise` for ordinals 3–4 |
| Session pools | `10.60.0.0/24` and `10.61.0.0/24` |
| Slice | SST 1 |
| Core persistence | one MongoDB PersistentVolumeClaim (PVC) |
| Telemetry | Prometheus, Grafana, Loki, Alloy, kube-state-metrics |
| External access | none; Grafana uses an explicit loopback port-forward |

## 2. Management and service planes

Three distinct systems operate at the same time:

1. **Management plane.** The lifecycle command invokes Helm and `kubectl`.
   Helm renders versioned Kubernetes objects and submits them to the API.
2. **Kubernetes execution plane.** Controllers and the kubelet create Pods,
   attach configuration and storage, run probes, and replace failed Pods.
3. **5G service plane.** Open5GS and UERANSIM exchange NGAP, SBI, PFCP, and
   GTP-U traffic. User packets travel through the UE tunnel, gNodeB, and UPF.

Kubernetes readiness is necessary but not sufficient. A Pod can be Running
while a UE is unregistered, a PFCP session is missing, or the user-plane
return route is stale. This is why the validator checks Kubernetes state,
protocol state, and end-to-end traffic separately.

## 3. Kubernetes object model

The `cn5g` Helm release owns the mobile-network workloads in namespace
`cn5g`. The `cn5g-observability` release owns telemetry workloads in namespace
`cn5g-observability`.

| Kubernetes object | Why it is used |
| --- | --- |
| Deployment | replaceable singleton Open5GS functions, gNodeB, and data endpoints |
| StatefulSet | stable UE ordinals and MongoDB/telemetry storage identity |
| Service | stable DNS and protocol ports despite changing Pod IPs |
| Headless Service | direct Pod discovery where PFCP or ordinal identity matters |
| Job | finite, revision-scoped subscriber convergence |
| ConfigMap | non-secret Open5GS, UERANSIM, telemetry, and dashboard configuration |
| Secret | locally generated synthetic authentication material and Grafana password |
| PVC | retained MongoDB, Prometheus, and Loki data |

### Why the UEs use a StatefulSet

The names `cn5g-ue-0` through `cn5g-ue-4` are stable even when their Pods are
replaced. Each ordinal selects one exact synthetic subscriber configuration
and one DNN. Stable ordinal does not mean stable IP: both the Pod IP and the
PDU-session address can change.

Each UE Pod contains:

```text
init: wait-for-subscriber
init: render-config
main: ue
sidecar: user-plane-metrics
```

Init containers finish before the main process starts. The sidecar remains
running and shares the Pod network namespace, so it can observe `uesimtun0`
and issue a source-bound probe without receiving subscriber credentials or
network-administration capability.

## 4. 5G control path

A UE reaches service through a distributed exchange:

1. The UE finds the simulated gNodeB over UERANSIM's UDP radio link.
2. The gNodeB sends the registration request to the Access and Mobility
   Management Function (AMF) using NGAP over N2 SCTP/38412.
3. The AMF uses the Service-Based Interface (SBI), normally through the
   Service Communication Proxy (SCP), to discover and call other functions.
4. The Authentication Server Function (AUSF), Unified Data Management (UDM),
   and Unified Data Repository (UDR) obtain the synthetic subscriber data and
   complete 5G Authentication and Key Agreement (5G-AKA).
5. The AMF enables Non-Access Stratum (NAS) security and accepts registration.
6. The UE requests a Protocol Data Unit (PDU) session for its configured DNN.
7. The Session Management Function (SMF) selects policy and programs the User
   Plane Function (UPF) over N4 PFCP/UDP 8805.
8. The gNodeB and UPF establish the N3 GTP-U/UDP 2152 tunnel.

The Network Repository Function (NRF) is the core's service registry. The
validator expects nine stable network-function profiles. Seeing nine profiles
does not alone prove service; it proves that discovery converged.

## 5. User-plane packet path

After session establishment, a UE receives an address from its DNN pool and
creates `uesimtun0`:

```text
application
  -> uesimtun0 (10.60.0.x or 10.61.0.x)
  -> UERANSIM UE and gNodeB
  -> N3 GTP-U tunnel
  -> Open5GS UPF
  -> N6 route
  -> controlled DNN endpoint
```

The reply takes the inverse path. The kind node has two exact,
ownership-marked return routes that point the UE pools through the current UPF
Pod. They exist inside the disposable node container, not in the Ubuntu host
network namespace.

The UPF owns two TUN gateways:

- `ogstun` at `10.60.0.1/24` for `internet`;
- `ogstun2` at `10.61.0.1/24` for `enterprise`.

Source-policy rule 1060 selects the Internet table; rule 1061 selects the
Enterprise table. Each table permits only its intended endpoint and has an
unreachable default. Cross-DNN traffic therefore fails closed.

### Pod IP versus session IP

Every UE Pod has two important addresses:

- `eth0` receives a `10.244.0.0/16` Kubernetes Pod address;
- `uesimtun0` receives a `10.60.0.0/24` or `10.61.0.0/24` session address.

Testing directly from `eth0` can bypass the 5G user plane. Accepted probes
bind to the session address and verify positive tunnel counter deltas, so a
direct Pod-network shortcut cannot be reported as GTP-U success.

## 6. Network functions in plain language

| Function | Responsibility in this platform |
| --- | --- |
| NRF | network-function registration and discovery |
| SCP | routes SBI service calls |
| AMF | gNodeB association, UE registration, mobility, and NAS security |
| AUSF | authentication service |
| UDM | subscriber and authentication-data management |
| UDR | data repository API backed by MongoDB |
| PCF | policy control |
| NSSF | slice selection; this platform uses SST 1 |
| SMF | PDU-session control and PFCP programming |
| UPF | GTP-U termination and N6 packet forwarding |

These functions are separate Pods and processes. Their stable Service names
are part of configuration; their replaceable Pod IPs are runtime state.

## 7. Observability without confusing it with service truth

Prometheus scrapes native Open5GS metrics, UE sidecar metrics,
kube-state-metrics, and Kubernetes node/container metrics. Loki stores
project logs and Events collected by Alloy. Grafana queries both systems and
renders six provisioned dashboards.

The evidence paths are deliberately separate:

```text
live service -> metrics -> Prometheus -> Grafana
live service -> logs -> Alloy -> Loki -> Grafana
reviewed campaign JSON -> deterministic exporter -> Prometheus -> Grafana
```

Reviewed performance and resilience dashboards do not pretend to show a live
load test. Their values are regenerated from accepted, version-controlled
summaries and served as bounded metrics after temporary experiment activity
has ended.

The alert lifecycle exercises prove both directions: a controlled fault makes
the rule fire, restoration makes it resolve, and no exercise alert is left
active.

## 8. Persistence and configuration

MongoDB is a StatefulSet with a PVC. Deleting its Pod tests process recovery;
uninstalling a Helm release while retaining the claim tests lifecycle
persistence. Deleting the kind cluster destroys its local-path volume and is
therefore a separate, explicitly confirmed operation.

Subscriber authentication data is synthetic. A deterministic local seed
derives matching UERANSIM and Open5GS files under a permission-restricted,
Git-ignored directory. Only the resulting Kubernetes Secret is supplied to
the running cluster. Public files contain the topology and identity plan, not
keys or credentials.

Configuration follows one direction:

```text
tracked profile + chart templates + local Secret
  -> Helm render
  -> Kubernetes objects
  -> init-container rendered runtime configuration
  -> application process
```

## 9. Deployment profiles

The `default` profile is the normal system. It enables five UEs, two DNNs, and
observability. The other profiles are explicit operational choices:

- `core-only`: accepted multi-UE core without observability;
- `resource-limited`: multi-UE core with reduced database reservation;
- `single-ue`: minimal compatibility and diagnosis configuration;
- `performance`: temporary benchmark sidecars over the full platform.

This arrangement prevents the simpler topology from appearing to be the main
product. Profiles change configuration; they do not require separate source
trees or a sequence of prior deployments.

## 10. Experiment design

### Performance

The performance campaign uses 1, 3, and 5 concurrent UEs with three
repetitions. Traffic starts in a zero-capability sidecar sharing each UE Pod's
network namespace and is bound to the real session address. Each DNN has a
temporary benchmark-server sidecar on one port per UE ordinal.

The contract includes warm-up, measurement, cool-down, fixed offered loads,
resource floors, baseline restoration, and a complete-evidence requirement.
Failed attempts are retained but excluded from reviewed summaries.

### Resilience

The resilience campaign deletes one exact AMF, SMF, or UPF Pod. Kubernetes
creates a replacement; the runner separately measures API detection, Pod
readiness, component-specific service recovery, and full five-UE restoration.

All accepted runs required operator-assisted session repair. That result is
reported directly: Kubernetes replacement is automatic, but this
single-replica 5G service is not high availability.

## 11. Security and host safety

No application workload uses privileged mode. The minimum exceptions are:

| Workload | Additional capability | Reason |
| --- | --- | --- |
| UPF | `NET_ADMIN` | create TUN interfaces and policy routes |
| UE | `NET_ADMIN`, `NET_RAW` | create the session TUN and run ICMP validation |
| Data endpoints | none | ordinary controlled application traffic |
| Benchmark sidecars | none | share an already configured Pod network namespace |

Service-account tokens are disabled where the workload does not call the
Kubernetes API. Observability RBAC is read-only and project-scoped. Images and
tool inputs are pinned; images pass High/Critical vulnerability gates and have
SPDX Software Bills of Materials (SBOMs).

Lifecycle safety relies on exact ownership checks. Scripts do not use global
Docker prune commands, wildcard deletion, broad route flushes, or host
firewall resets. Before a destructive clean-runtime test, the target cluster,
node identity, PVC count, and expected data loss are printed for review.

## 12. Reading a validation result

A successful platform validation means all of these independent statements
were true during the run:

- Kubernetes workloads were ready;
- network functions advertised stable SBI identities;
- the gNodeB had N2 SCTP association and NG Setup;
- the SMF and UPF had healthy PFCP control state;
- all five provisioned identities registered and established PDU sessions;
- UE and F-SEID values were unique;
- every UE reached its intended endpoint through its session tunnel;
- every cross-DNN request was denied;
- tunnel receive and transmit counters increased; and
- effective Linux capabilities matched the documented minimum boundary.

Observability validation adds target health, expected telecom values, bounded
cardinality, recent log ingestion, Grafana provisioning, and reviewed-result
exporters. A green dashboard is useful presentation, but these explicit gates
remain the acceptance source of truth.

## 13. Common diagnostic distinctions

| Symptom | What it usually means |
| --- | --- |
| Pod is Ready, UE is not registered | container health passed but 5G signalling did not |
| gNB has no SCTP association | N2 transport or AMF/gNB state is incomplete |
| PDU session exists, endpoint fails | inspect UPF policy tables, current DNN Pod, and return routes |
| direct Pod request works, session-bound request fails | Kubernetes network works; 5G user plane does not |
| Grafana URL stops responding | the loopback port-forward ended; Grafana may still be healthy |
| Prometheus target is down | scrape discovery or target health failed; it does not by itself prove 5G failure |
| replacement Pod is Ready, UEs remain disrupted | infrastructure recovered before service/session state |

## 14. Evidence model

The repository separates three evidence classes:

- tracked contracts and sanitized reviewed summaries;
- generated but tracked charts, metrics fixtures, and dashboard definitions;
- ignored raw logs, scanner output, kubeconfigs, credentials, host snapshots,
  and detailed attempt data.

Public claims in [`release/release-evidence.json`](../release/release-evidence.json)
link to a method and report and include a scope limit. This keeps the project
useful to reviewers without publishing sensitive or misleading raw material.
