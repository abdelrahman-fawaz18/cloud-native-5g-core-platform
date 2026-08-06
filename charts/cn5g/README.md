# CN5G Helm Chart

For a system-level visual explanation of where this chart runs and how its
objects, 5G interfaces, address domains, lifecycle, persistence, and validation
fit together, see the
[complete Phase 4 system guide](../../docs/README.md#23-phase-4-complete-system-and-operational-model)
the [accepted Phase 5 multi-UE model](../../docs/README.md#31-phase-5-multi-ue-and-dnn-implementation-model),
and the [accepted Phase 6 observability model](../../docs/README.md#32-phase-6-observability-and-operational-mental-model).

This chart packages the verified Open5GS, MongoDB, UERANSIM, and controlled
data-network images as one Kubernetes release. The baseline deliberately runs
one replica of each 5G function, one gNodeB, and one synthetic UE.

`values-phase05.yaml` is the accepted multi-UE overlay. It keeps the default
Phase 4 render intact for controlled rollback
while changing the UE controller to a five-replica StatefulSet and adding the
`enterprise` DNN, `10.61.0.0/24` session pool, `ogstun2`, and a second
controlled endpoint. The runtime gate in the
[system guide](../../docs/README.md#31-phase-5-multi-ue-and-dnn-implementation-model)
passed on 2026-08-05.

`values-phase06.yaml` composes with the Phase 5 overlay and adds one bounded
user-plane metrics sidecar to each UE Pod plus a headless metrics port. The
sidecar binds its synthetic HTTP request to `uesimtun0`, exposes only fixed
ordinal/DNN labels, mounts no subscriber material, has no API token, and drops
all capabilities. The separate `cn5g-observability` chart owns every metrics,
logging, dashboard, and alert backend.

The Phase 6 overlay passed the complete Phase 5 regression validator plus
live target, telecom-metric, user-plane probe, cardinality, log-ingestion,
dashboard-provisioning, and alert-lifecycle gates on 2026-08-05.

`values-phase07.yaml` composes with both accepted overlays and adds an idle
`benchmark-client` sidecar to each UE plus a listening `benchmark-server`
sidecar to each DNN endpoint. All benchmark containers run as UID/GID 65532,
drop every capability, use a read-only root filesystem, and receive bounded
resources. Each DNN Service exposes TCP and UDP ports 5201-5205 only inside
the cluster, one independent server port per UE ordinal. This overlay is an
experiment mechanism; it is not accepted until
the gated runtime pilot and later repeated matrix pass.

Non-sensitive configuration is rendered through ConfigMaps. The chart never
templates subscriber authentication material; `subscriberSecret.existingSecret`
must name a Secret created from the ignored files produced by
`scripts/generate-subscriber-secret.sh`.

Project-built workload images use `imagePullPolicy: Never` and must be loaded
into the named kind node only after their local identities match the Phase 2
manifest. The Phase 6 Python sidecar uses an upstream version-and-digest-pinned
image with `IfNotPresent`; its immutable registry identity is recorded in the
Phase 6 version manifest. MongoDB's
upstream `tag@digest` is verified before its fixed-version tag is imported;
the imported containerd image ID is then compared with that accepted digest.
This two-sided gate is required because kind's Docker-image import preserves
the tag and content identity but does not preserve the upstream RepoDigest
alias. Kubernetes therefore cannot pull an unreviewed replacement at runtime.
For project-built OCI indexes, the loader first accepts the recorded index
digest and then reads the runtime configuration digest from the same Docker
archive consumed by kind. That digest is compared with the image ID reported
by the container runtime through CRI. Index, platform-manifest, attestation,
and runtime-configuration digests are distinct OCI objects and are never
compared as though they were equivalent. Repository digests are not used for
this post-import comparison because kind assigns local `import-*` repository
aliases while retaining the configuration identity.

Open5GS, UERANSIM, and the data endpoint use Deployments. MongoDB uses a
StatefulSet and a dynamically provisioned data PersistentVolumeClaim (PVC).
Subscriber provisioning uses a revision-scoped idempotent Job. Workloads use a
ServiceAccount with no Role or RoleBinding because they do not need Kubernetes
Application Programming Interface (API) access.

Resource requests are grounded in two ten-second cgroup v2 observations of
the validated single-UE steady state, including a second sample after the
requests were applied by a fresh install. MongoDB averaged 143-170
millicores (mCPU), used 217-222 MiB current memory, and reached 380-381 MiB
peak memory, so its reservation is 200 mCPU and 256 MiB while its 500
mCPU/768 MiB limit retains startup headroom. The shared Open5GS profile
observed 12-22 mCPU and 6-40 MiB across its functions; its reservation is
therefore 25 mCPU/64 MiB. The data endpoint observed 6-8 mCPU, 3 MiB current
memory, and 7-8 MiB peak memory; its reservation is 10 mCPU/16 MiB. The
existing UPF and UERANSIM reservations already exceeded their observed
steady-state use and remain unchanged. A later five-UE observation measured
each UE at 17-19 mCPU and 5-10 MiB current memory, both data endpoints at 8-9
mCPU and 2-3 MiB, and MongoDB at 162 mCPU and 241 MiB current/691 MiB peak
memory. These local observations are scheduling evidence, not production
capacity guidance.

`helm lint` and `helm template` validate package structure and deterministic
rendering. They do not prove SCTP, NGAP, PFCP, GTP-U, TUN, N6 routing, UE
registration, PDU-session establishment, persistence, upgrade, or rollback.

## Runtime Object And Network Model

The release renders the following responsibility hierarchy:

```text
cn5g Helm release in namespace cn5g
├── ConfigMaps: non-secret Open5GS and gNB configuration
├── pre-existing Secret: UE and subscriber material (not chart-owned)
├── ServiceAccount: mounted API token disabled; no RBAC grants
├── Deployments
│   ├── nine Open5GS SBI control-plane functions
│   ├── UPF
│   ├── gNB and UE
│   └── controlled data-network endpoint
├── StatefulSet: MongoDB
│   └── retained PersistentVolumeClaim -> local-path PersistentVolume
├── revision-scoped subscriber initialization Job
└── cluster-internal Services and EndpointSlices
```

Every Pod gets a replaceable `10.244.0.0/16` address. ClusterIP Services use
the separate `10.96.0.0/16` range and provide stable DNS discovery. SBI
functions advertise their stable fully qualified Service names, while N2,
N3, and N4 listeners bind to the Pod address inserted at container startup.
The UE session subnet `10.60.0.0/24` is neither a Pod nor a Service network: it
exists on the UERANSIM and UPF TUN interfaces and is returned through one
project-marked route inside the kind node.

```text
UE application
  -> uesimtun0 (10.60.0.x, MTU 1400)
  -> simulated radio -> gNB
  -> N3 GTP-U/UDP 2152 -> UPF Pod
  -> ogstun (10.60.0.1) -> N6 -> data-network Pod

Return packet
  -> data Pod default gateway -> kind node
  -> exact 10.60.0.0/24 route -> current UPF Pod veth
  -> ogstun -> N3 GTP-U -> gNB -> UE -> uesimtun0
```

SBI communication uses TCP/7777, N2 uses SCTP/38412, N4 uses UDP/8805, and
N3 uses UDP/2152. Services are cluster-internal; the chart defines no
NodePort, LoadBalancer, host port, or host-network workload.

## Lifecycle And Recovery Semantics

Deployments use one replica because this phase proves orchestration and
protocol correctness rather than availability. Open5GS functions use
`Recreate` during the accepted revision transition so replaceable Pods do not
briefly advertise two endpoints. The lifecycle helper handles the Helm 4
server-side-apply transition between `RollingUpdate` and `Recreate` with
ownership checks and server-side previews.

Open5GS caches peers and session state. A simple Pod-ready result is therefore
not sufficient after an address-changing rollout. Convergence verifies nine
stable NRF profiles and, when required, restarts UPF, then SMF, then gNB, then
UE so PFCP and GTP-U state is rebuilt against current Pod addresses. The
complete validator must pass after install, upgrade, rollback, and reinstall.

MongoDB's claim carries a keep policy. The accepted tests proved the same
claim UID and backing volume across Pod recreation, controlled upgrade,
rollback, and Helm uninstall/reinstall. This does not imply survival across
kind-cluster deletion or provide replicated database availability.

## Security Boundary

All containers drop Linux capabilities before narrowly adding requirements.
UPF adds only `NET_ADMIN`; UE adds `NET_ADMIN` and `NET_RAW`; ordinary
Open5GS, MongoDB, subscriber Job, gNB, and data-network containers receive no
added network capability. `/dev/net/tun` is mounted only into UPF and UE. No
container is privileged, workload API-token mounting is disabled, and no
Role or RoleBinding is created.

## Accepted Scope

The default values are accepted as a local, single-node, single-UE integration
baseline. The Phase 5 overlay is accepted for exactly five concurrent UEs and
two differentiated DNN contracts. Together they prove Kubernetes packaging,
real 5G signalling and user-plane operation, state persistence, controlled
release lifecycle, deterministic identity mapping, and cross-DNN isolation.
They do not claim general multi-UE capacity, multi-node scheduling, high
availability, production storage or security controls, carrier-grade
performance, or geographic redundancy.

## Phase 5 Overlay Contract

The overlay consumes the pre-existing `cn5g-subscribers-phase05` Secret. The
chart neither generates nor owns its authentication values. StatefulSet Pod
ordinal `N` selects `imsi-N`, `dnn-N`, and `ue-N.yaml`, and the subscriber Job
consumes one batch provisioning script. The values schema fixes the replica
count at five and fixes both DNN network contracts so an unreviewed values
override cannot silently move a subscriber pool, gateway, TUN device,
endpoint, or route-policy table.

The UPF setup init container creates `ogstun` and `ogstun2`, then installs one
source-policy table per DNN. Each table contains only the intended headless
endpoint route plus an unreachable default. It receives only `NET_ADMIN` and
the existing TUN device mount. Endpoint containers remain non-root with all
capabilities dropped. The overlay does not add a host port, NodePort,
LoadBalancer, host-network Pod, or RBAC grant.

Phase 5 also adds the headless `cn5g-upf-pfcp` discovery Service for N4. The
SMF resolves this name directly to the ready UPF Pod address. This deliberately
bypasses ClusterIP UDP proxying for PFCP, whose association and session state
is tied to the peer transport address. The normal `cn5g-upf` ClusterIP Service
remains available for the other declared UPF ports and preserves the Phase 4
object contract.
