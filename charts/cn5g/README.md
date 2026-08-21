# CN5G Helm Chart

This chart packages Open5GS, MongoDB, UERANSIM, and two controlled data
networks as the `cn5g` Kubernetes release. Its default values represent the
accepted platform: five synthetic UEs, two DNNs, bounded UE telemetry, and no
benchmark sidecars.

The [complete system architecture](../../docs/architecture/complete-system-architecture.md)
explains how the rendered objects, protocols, addresses, storage, and
Observability paths connect.

## Profiles

Profile files live at the repository root so the unified lifecycle and direct
Helm users select the same contracts.

| Profile | Purpose |
| --- | --- |
| [`default`](../../profiles/default.yaml) | five UEs, `internet` + `enterprise`, observability-compatible telemetry |
| [`core-only`](../../profiles/core-only.yaml) | the same 5G topology without deploying the separate observability release |
| [`resource-limited`](../../profiles/resource-limited.yaml) | full 5G topology with a smaller local database reservation |
| [`single-ue`](../../profiles/single-ue.yaml) | minimal one-UE/one-DNN compatibility profile |
| [`performance`](../../profiles/performance.yaml) | temporary zero-capability benchmark sidecars and ports 5201–5205 |

The default chart render is intentionally the full topology. The single-UE
configuration must be requested explicitly.

## Object model

```text
Helm release cn5g · namespace cn5g
├── Deployments
│   ├── NRF, SCP, AMF, AUSF, UDM, UDR, PCF, NSSF, SMF, UPF
│   ├── UERANSIM gNodeB
│   └── internet and enterprise data endpoints
├── StatefulSets
│   ├── MongoDB + retained 2 GiB PVC
│   └── five ordinal-bound UE Pods
├── revision-scoped subscriber convergence Job
├── cluster-internal and headless Services
├── non-secret ConfigMaps
└── reference to a pre-created synthetic subscriber Secret
```

The chart never templates authentication keys. The lifecycle generates them
under ignored, permission-restricted storage and supplies a pre-existing
Secret named by `platform.subscriberSecret.existingSecret`.

## Network contract

| Interface | Protocol and port | Peers |
| --- | --- | --- |
| SBI | HTTP/2 TCP/7777 | Open5GS network functions |
| N2 | NGAP SCTP/38412 | gNodeB ↔ AMF |
| N4 | PFCP UDP/8805 | SMF ↔ UPF |
| N3 | GTP-U UDP/2152 | gNodeB ↔ UPF |
| N6 | routed IPv4 | UPF ↔ controlled data endpoint |
| UE radio simulation | UDP/4997 | UE ↔ gNodeB |
| UE telemetry | HTTP/TCP 9101 | Prometheus ↔ sidecar |

`internet` sessions use `10.60.0.0/24` through `ogstun`; `enterprise`
sessions use `10.61.0.0/24` through `ogstun2`. UPF source-policy tables 1060
and 1061 permit only the intended endpoint and reject other destinations.

All Services are cluster-internal. The chart defines no NodePort,
LoadBalancer, host port, or host-network workload.

## Security boundary

- UPF receives only `NET_ADMIN` and `/dev/net/tun`.
- UE containers receive only `NET_ADMIN`, `NET_RAW`, and `/dev/net/tun`.
- Data endpoints, benchmark sidecars, metrics sidecars, and ordinary core
  functions run with all capabilities dropped.
- Workload service-account token mounting is disabled and the chart creates no
  Role or RoleBinding.
- Containers disable privilege escalation and use `RuntimeDefault` seccomp;
  root filesystems are read-only where the application permits.

## Image identity

Third-party images are version-and-digest pinned. Project images are built
from pinned sources, compared with recorded local identities, and loaded into
the exact kind node with `imagePullPolicy: Never`. OCI index, platform
manifest, attestation, and runtime configuration digests are treated as
different objects; the loader compares the runtime configuration identity
reported by containerd.

## Validation boundary

`helm lint` and deterministic `helm template` rendering prove package
structure only. Runtime acceptance additionally requires SCTP association,
NG Setup, 5G-AKA, NAS security, PDU sessions, PFCP and GTP-U state,
session-bound HTTP/ICMP, unique addresses and F-SEIDs, tunnel counter deltas,
cross-DNN denial, and effective capability checks.
