# Cloud-Native Multi-UE 5G Core Platform

## Overview

This repository is the implementation workspace for a reproducible,
containerized 5G Standalone (5G SA) Core platform. The target system will
deploy Open5GS, MongoDB, and UERANSIM on a local Kubernetes environment,
exercise multiple synthetic User Equipments (UEs), and produce measured
evidence for signalling, user-plane traffic, observability, load, failure, and
recovery behavior.

The project extends the validated protocol baseline documented in the
[5G SA Core Protocol Lab](https://github.com/abdelrahman-fawaz18/5g-sa-core-protocol-lab).
It focuses on packaging, orchestration, repeatability, operational visibility,
and reliability rather than repeating the original single-host installation.

## Current Status

The repository boundary, host preflight, container baseline, and Kubernetes
networking feasibility gate are complete. Pinned images produce a healthy
Compose deployment in which a synthetic UE registers, establishes an IPv4
session, and exchanges controlled traffic through the UPF. A disposable,
single-node kind cluster has independently passed Pod and Service transport,
TUN-device, minimum-capability, routed N6, packet-visibility, and scoped
cleanup tests. kind is therefore the accepted local Kubernetes baseline for
Phase 4. See the [project status](docs/project-status.md), [container
report](reports/02_container_baseline.md), and [architecture
decisions](docs/adr/README.md).

## Verified Phase 2 Baseline

Phase 2 establishes the protocol-correct container reference that later
Kubernetes work must preserve. The declared topology contains 15 services on
two internal Docker networks, with the UE session subnet routed through a TUN
interface in the UPF rather than implemented as a Docker bridge.

```mermaid
flowchart LR
    UE["UERANSIM UE\n10.60.0.x"]
    GNB["UERANSIM gNodeB"]
    AMF["Open5GS AMF"]
    CP["Open5GS control plane\nNRF/SCP/AUSF/UDM/UDR/PCF/NSSF/SMF"]
    DB[("MongoDB")]
    UPF["Open5GS UPF\nogstun 10.60.0.1"]
    DN["Controlled N6 endpoint\n10.62.0.10"]

    UE <-->|"simulated radio"| GNB
    GNB <-->|"N2: NGAP/SCTP"| AMF
    AMF <-->|"HTTP/2 SBI"| CP
    CP <--> DB
    CP <-->|"N4: PFCP"| UPF
    GNB <-->|"N3: GTP-U"| UPF
    UPF <-->|"N6: routed IPv4"| DN
```

Verified properties:

- source commits, archives, base images, runtime packages, and local output
  identities are pinned or recorded;
- health-gated startup reaches 14 healthy long-running containers plus one
  successful subscriber-initialization job;
- one synthetic UE completes authentication, registration, and an IPv4
  Protocol Data Unit session for DNN `internet` and SST `1`;
- HTTP and Internet Control Message Protocol traffic traverses the UE tunnel,
  simulated radio path, N3 GTP-U tunnel, UPF, and controlled N6 return route;
- positive receive and transmit counter deltas provide bidirectional tunnel
  evidence without publishing a raw packet capture;
- MongoDB data survives container/network recreation; and
- exact destruction removes all project containers, networks, and volumes
  while leaving host Open5GS, MongoDB, LXC, routes, and firewall structure
  intact.

The full technical model is documented in [Phase 2 Docker Compose
architecture](docs/architecture/phase-02-compose-topology.md). Reproduction,
diagnostics, persistence testing, and cleanup are covered by the [Compose
runbook](docs/runbooks/compose-baseline.md).

## Verified Phase 3 Kubernetes Feasibility

Phase 3 tested the networking primitives before attempting a full Kubernetes
deployment of Open5GS and UERANSIM. This isolates cluster-network behavior from
5G application configuration and startup behavior.

### Deployment hierarchy

```text
Ubuntu host
└── Docker Engine
    └── kind node container: cn5g-control-plane (172.18.0.2)
        ├── Kubernetes control plane and containerd
        ├── kindnet Pod network (10.244.0.0/16)
        │   ├── transport client and server Pods
        │   ├── minimum-capability TUN Pods
        │   └── synthetic UE, N6 router, and data endpoint Pods
        └── Kubernetes Service network (10.96.0.0/16)
```

The kind node is a Docker container, but Kubernetes Pods run inside that node
through its containerd runtime. Each Pod receives a distinct `10.244.0.0/16`
address and a node-side virtual Ethernet (`veth`) route. ClusterIP Services
provide stable virtual addresses and DNS names from `10.96.0.0/16`. The
Kubernetes API is published only on a random loopback port and no workload
port is exposed on the Ubuntu host.

### Feasibility results

| Question | Verified result |
| --- | --- |
| Ordinary Pod transport | Direct Pod-IP and ClusterIP Service paths passed for TCP and UDP |
| N2 transport prerequisite | SCTP port `38412` passed through direct Pod and ClusterIP Service paths |
| N4 transport prerequisite | UDP port `8805` passed through direct Pod and ClusterIP Service paths |
| N3 transport prerequisite | UDP port `2152` passed through direct Pod and ClusterIP Service paths |
| TUN access | Access failed without `NET_ADMIN` and succeeded with only `NET_ADMIN` plus `/dev/net/tun` |
| N6 routing | A controlled TCP request and response crossed two TUN interfaces and a synthetic UDP/2152 tunnel |
| Packet visibility | UDP/2152 outer packets were observed in both the router Pod and kind-node network contexts |
| Privilege | No privileged container was used; ordinary transport and the data endpoint ran with zero effective capabilities |
| Cleanup | Probe resources, the node route, cluster container, kubeconfig, and empty kind bridge were removed by exact ownership checks |

The N6 feasibility path was:

```text
application in synthetic UE Pod
  -> cn5gue0 (10.60.0.2/24, MTU 1400)
  -> synthetic IP-over-UDP tunnel on port 2152
  -> cn5gupf0 (10.60.0.1/24, MTU 1400) in router Pod
  -> data endpoint Pod (TCP/8080)
  -> data Pod default gateway (10.244.0.1)
  -> exact kind-node return route for 10.60.0.0/24
  -> router Pod -> tunnel -> synthetic UE Pod
```

The synthetic tunnel proves Kubernetes routing, TUN, capability, return-path,
and packet-observation behavior. It is not an implementation of GTP-U and does
not prove NGAP, PFCP, or GTP-U message semantics. Those protocols will be
validated with the real Open5GS/UERANSIM workloads in the Helm-managed Phase 4
platform.

## Target Capabilities

- pinned and reproducible container images;
- a reversible local Kubernetes environment;
- Helm-managed Open5GS, MongoDB, and UERANSIM workloads;
- meaningful startup, readiness, and liveness checks;
- automated synthetic subscriber generation and provisioning;
- concurrent UE registration and Protocol Data Unit (PDU) sessions;
- at least two Data Network Names (DNNs) or network slices;
- Prometheus metrics and version-controlled Grafana dashboards;
- centralized, correlated operational logs;
- repeatable throughput, latency, loss, and resource measurements;
- controlled component-failure and recovery experiments;
- Continuous Integration (CI) validation for source, configuration, charts,
  tests, and container artifacts;
- concise, sanitized evidence and operational runbooks.

## Roadmap Target Architecture

```mermaid
flowchart LR
    UE["Multiple UERANSIM UEs"]
    GNB["UERANSIM gNB"]
    AMF["Open5GS AMF"]
    CORE["Open5GS control-plane functions"]
    SMF["Open5GS SMF"]
    UPF["Open5GS UPF"]
    DB[("MongoDB")]
    DN["Controlled data network"]
    PROM["Prometheus"]
    GRAF["Grafana"]
    LOGS["Centralized logs"]

    UE <-->|"Simulated radio"| GNB
    GNB <-->|"N2: NGAP over SCTP"| AMF
    AMF <-->|"Service-Based Interface"| CORE
    CORE <--> DB
    AMF <-->|"Session services"| SMF
    SMF <-->|"N4: PFCP"| UPF
    GNB <-->|"N3: GTP-U"| UPF
    UPF <-->|"N6: IP"| DN
    PROM --> GRAF
    AMF --> PROM
    SMF --> PROM
    UPF --> PROM
    AMF --> LOGS
    SMF --> LOGS
    UPF --> LOGS
    GNB --> LOGS
    UE --> LOGS
```

The target topology builds on the accepted kind networking baseline. Exact
Open5GS Service types, advertised N2/N3/N4 endpoints, storage resources, and
health probes remain Phase 4 implementation decisions and must pass real
single-UE protocol validation before they become accepted runtime behavior.

## Repository Structure

```text
cloud-native-5g-core-platform/
├── charts/                 Helm packaging
├── containers/             Container build definitions
├── configs/                Synthetic lab configuration
├── scripts/                Lifecycle, test, and cleanup automation
├── tools/                  Validation and reporting software
├── tests/                  Unit, integration, and acceptance tests
├── monitoring/             Prometheus rules and Grafana provisioning
├── logging/                Centralized logging configuration
├── benchmarks/             Reproducible experiment definitions and summaries
├── docs/                   Architecture, decisions, operation, and analysis
├── reports/                Sanitized validation and experiment reports
├── versions/               Exact tool, image, and source provenance manifests
├── captures/               Intentionally reviewed protocol evidence
├── screenshots/            Selected visual evidence
├── diagrams/               Architecture and call-flow sources
└── .github/                Continuous Integration workflows
```

## Evidence Policy

Only synthetic identities and credentials may be used. Raw logs, runtime data,
local kubeconfigs, private keys, and packet captures are ignored by default.
Selected captures may be added only after a documented content and privacy
review. Performance and reliability claims must link to reproducible commands,
machine-readable measurements, and concise reports.

## Technical Documentation

- [Current phase and gate status](docs/project-status.md)
- [Phase 2 Docker Compose architecture](docs/architecture/phase-02-compose-topology.md)
- [Container image provenance](docs/image-provenance.md)
- [Docker Engine installation runbook](docs/runbooks/docker-engine-installation.md)
- [Compose build, operation, validation, and cleanup runbook](docs/runbooks/compose-baseline.md)
- [Phase 2 validation and host-safety report](reports/02_container_baseline.md)
- [Architecture Decision Records](docs/adr/README.md)

## Authoritative References

- [Open5GS documentation](https://open5gs.org/open5gs/docs/)
- [Kubernetes concepts](https://kubernetes.io/docs/concepts/)
- [kind documentation](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [Helm documentation](https://helm.sh/docs/)
- [Prometheus documentation](https://prometheus.io/docs/introduction/overview/)
- [Grafana documentation](https://grafana.com/docs/grafana/latest/)
- [GitHub Actions documentation](https://docs.github.com/en/actions)
