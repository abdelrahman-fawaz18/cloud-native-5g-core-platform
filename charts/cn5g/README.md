# CN5G Helm Chart

This chart packages the verified Open5GS, MongoDB, UERANSIM, and controlled
data-network images as one Kubernetes release. The baseline deliberately runs
one replica of each 5G function, one gNodeB, and one synthetic UE.

Non-sensitive configuration is rendered through ConfigMaps. The chart never
templates subscriber authentication material; `subscriberSecret.existingSecret`
must name a Secret created from the ignored files produced by
`scripts/generate-subscriber-secret.sh`.

Every workload uses `imagePullPolicy: Never` and must be loaded into the named
kind node only after its local identity matches the Phase 2 manifest. MongoDB's
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
steady-state use and remain unchanged. These settings describe this
single-node, single-UE baseline; later multi-UE measurements must reassess
them rather than treating them as production capacity guidance.

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

The chart is accepted for a local, single-node, single-UE integration
baseline. It proves Kubernetes packaging, real 5G signaling and user-plane
operation, state persistence, and controlled release lifecycle. It does not
claim multi-node scheduling, high availability, production storage,
production security controls, multi-UE capacity, carrier-grade performance,
or geographic redundancy.
