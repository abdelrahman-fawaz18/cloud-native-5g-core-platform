# Project Status

Last updated: 2026-08-04

| Phase | State | Current gate |
| --- | --- | --- |
| 0 — Project governance | Complete | Local Git identity, ignore boundary, and initial technical baseline verified |
| 1 — Host preflight and decisions | Complete | Host ready; safety constraints and proposed decisions recorded |
| 2 — Container and Compose baseline | Complete | Healthy deployment, protocol/data path, persistence, recreation, and scoped cleanup verified |
| 3 — Kubernetes networking feasibility | Complete | kind transport, TUN, capability, synthetic N6, packet visibility, and scoped cleanup verified |
| 4 — Helm-managed single-UE platform | Complete | Chart, real 5G path, persistence, resource baseline, upgrade, rollback, and scoped uninstall/reinstall verified |
| 5 — Multi-UE, DNN, and slice automation | Ready to begin | Phase 4 single-UE release is the accepted Kubernetes baseline |
| 6-10 | Not started | Each later phase remains gated by the preceding verified baseline |

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
