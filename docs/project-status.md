# Project Status

Last updated: 2026-08-02

| Phase | State | Current gate |
| --- | --- | --- |
| 0 — Project governance | Complete | Local Git identity, ignore boundary, and initial technical baseline verified |
| 1 — Host preflight and decisions | Complete | Host ready; safety constraints and proposed decisions recorded |
| 2 — Container and Compose baseline | Complete | Healthy deployment, protocol/data path, persistence, recreation, and scoped cleanup verified |
| 3 — Kubernetes networking feasibility | Complete | kind transport, TUN, capability, synthetic N6, packet visibility, and scoped cleanup verified |
| 4 — Helm-managed single-UE platform | Ready to begin | kind accepted; no Phase 4 resources exist yet |
| 5-10 | Not started | Each later phase remains gated by the preceding verified baseline |

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

Phase 3 proved transport and network primitives rather than telecom protocol
semantics. Actual NGAP, PFCP, and GTP-U exchanges remain required Phase 4
evidence from the Helm-managed Open5GS/UERANSIM topology.
