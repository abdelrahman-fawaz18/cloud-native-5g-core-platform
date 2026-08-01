# Host Preflight Report

## Result

**State:** `READY_FOR_CONTAINER_RUNTIME_PHASE`

The host satisfies the observed operating-system, architecture, resource,
kernel, TUN, cgroup, and security-module prerequisites for a container-runtime
phase. The live privileged firewall and Network Address Translation (NAT)
rules were subsequently captured and reviewed. No blocking conflict was found.
Runtime installation still requires the user's explicit continuation and a
review of the exact versioned commands, expected host effects, verification,
and rollback procedure.

This report records a read-only inspection performed on 2026-08-01. No package,
service, interface, route, firewall rule, kernel module, container, or cluster
state was changed.

## Scope And Method

The inspection covered:

- operating system, kernel, architecture, virtualization, memory, swap, disk,
  and inodes;
- TUN, Stream Control Transmission Protocol (SCTP), and GPRS Tunnelling
  Protocol (GTP) kernel support;
- interfaces, routes, policy rules, bridges, and network namespaces;
- relevant packages, commands, services, processes, and listening ports;
- container and Kubernetes state where tooling was present;
- cgroup and AppArmor state;
- the predecessor repository's read-only Git status; and
- public/private repository boundaries.

Raw host transcripts were not copied into this report. Unrelated host
addresses and identifiers are intentionally omitted.

## Sanitized Host Facts

| Area | Observation | Interpretation |
| --- | --- | --- |
| Operating system | Ubuntu 24.04.4 Long-Term Support, x86-64 | Supported by current Docker Engine documentation |
| Kernel | 6.17.0-41-generic | Record again before benchmarks or kernel-sensitive tests |
| CPU | 24 logical CPUs; Intel VT-x available | Adequate for a gradual local single-node baseline |
| Memory | 15 GiB total; about 10 GiB available during inspection | Adequate for early phases; observability must be resource-limited |
| Swap | 4 GiB total; unused during inspection | Swap use during benchmarks will invalidate results above the defined threshold |
| Disk | 98 GiB filesystem; 37 GiB available; 61% used | Adequate with an explicit project storage budget and retention limits |
| Inodes | About 90% free | No current inode pressure |
| TUN | `/dev/net/tun` exists as a character device | Required primitive is present |
| SCTP | Kernel module available and loaded | N2 feasibility can be tested later |
| GTP | Kernel module available but not loaded | Acceptable for preflight; temporary need must be proven before loading |
| IPv4 forwarding | Enabled before this project | Existing state, likely used by the predecessor lab; preserve and re-check |
| cgroups | cgroup v2 | Compatible with current Kubernetes/kind direction |
| Security module | AppArmor enabled | Container profiles and exceptions must remain scoped |
| Current load | Low relative to 24 logical CPUs during inspection | A point-in-time observation, not capacity evidence |

## Existing Workloads And Coexistence

- Open5GS 2.8.0 Ubuntu packages and their relevant services are installed,
  enabled, and active.
- MongoDB 8.0.28 is installed, enabled, active, and bound to loopback.
- The existing Open5GS tunnel owns `10.45.0.0/16`.
- LXC (Linux Containers) networking owns `10.0.3.0/24`; LXC services are
  active, although no containers were listed.
- A private local-area-network route exists and must remain excluded from
  project subnet selection. Its host address is intentionally omitted.
- No named Linux network namespaces were present during inspection.
- The predecessor repository was clean at inspected commit `47121f155fb9`.
  It was accessed read-only and was not changed.
- The unrelated ns-3/5G-LENA project was not inspected or modified.

### Relevant listeners

Existing Open5GS services use loopback-bound instances of TCP/7777, TCP/3868,
TCP/9090, UDP/2123, UDP/2152, UDP/8805, and SCTP/38412. MongoDB uses
loopback TCP/27017. These bindings do not justify stopping the host lab.
Project workloads should communicate on private container or Pod networks and
avoid publishing these ports on the host.

No listener was found on the proposed loopback-only operator ports 13000,
13100, 16443, or 19090 during inspection. Availability must be checked again
immediately before use.

## Container And Cluster State

- Docker Engine, Docker Compose, Podman, containerd, `kubectl`, `kind`, k3s,
  Helm, Prometheus, and Grafana commands were absent.
- No Docker, containerd, or k3s state directory was present.
- No conflicting `docker.io`, Compose, `podman-docker`, containerd, `runc`, or
  Moby package was found.
- Docker objects and contexts were not applicable because Docker was absent.
- Kubernetes contexts and namespaces were not applicable because `kubectl`
  and cluster tooling were absent.

Absence is not permission to install. The selected runtime procedure and its
host effects require explicit review before Phase 2.

## Firewall And NAT Baseline

The installed firewall commands use the nftables-compatible iptables backend.
The UFW systemd unit appeared enabled/active during unprivileged inspection,
while `/etc/ufw/ufw.conf` reported `ENABLED=no`. The subsequent privileged
command confirmed the effective result: UFW status is inactive.

The live nftables ruleset contains only LXC-owned state:

- an `inet lxc` input chain permitting Domain Name System (DNS) and Dynamic
  Host Configuration Protocol (DHCP) traffic arriving from `lxcbr0`;
- an `inet lxc` forward chain accepting traffic entering or leaving `lxcbr0`;
  and
- an `ip lxc` post-routing NAT rule that masquerades traffic sourced from
  `10.0.3.0/24` when its destination is outside that range.

The live IPv4 and IPv6 `iptables-save` outputs were empty. No Docker-owned
chain exists because Docker is not installed. These observations do not make
future Docker firewall changes harmless: Docker will add its own
iptables-compatible state, and the LXC table, policies, packet counters, and
`10.0.3.0/24` behavior must remain present and functional after installation
and cleanup.

## Candidate Network And Port Plan

All values are provisional until the Phase 3 packet-path feasibility gate.

| Purpose | Candidate | Reason |
| --- | --- | --- |
| Compose project network | `172.28.0.0/24` | No route conflict observed; explicit narrow project range |
| kind Pod network | `10.244.0.0/16` | Explicit cluster-local range; no route conflict observed |
| kind Service network | `10.96.0.0/16` | Explicit cluster Service range; no route conflict observed |
| Synthetic DNN A UE pool | `10.60.0.0/24` | Separate from the predecessor UE tunnel |
| Synthetic DNN B UE pool | `10.61.0.0/24` | Distinct differentiated-session pool |
| Controlled data network | `10.62.0.0/24` | Isolated N6 test endpoint range |
| Kubernetes API | loopback TCP/16443 | Avoid local-network exposure and the default port |
| Grafana operator access | loopback TCP/13000 | Avoid wildcard publication |
| Loki operator access, if needed | loopback TCP/13100 | Avoid wildcard publication |
| Prometheus operator access | loopback TCP/19090 | Avoid the host Open5GS TCP/9090 listeners |

The Docker-managed bridge range and all candidates must be checked again after
runtime installation and before cluster creation. No 5G or database port will
be host-published by default.

## Initial Resource And Retention Guardrails

- Require at least 15 GiB free disk before an image-build or cluster-creation
  session.
- Limit initial project-owned images, writable layers, volumes, logs, and
  local cluster data to a combined working budget of 20 GiB.
- Require at least 6 GiB available memory before starting the full early
  platform; reserve host headroom for the existing lab and desktop.
- Stop a controlled experiment if available memory falls below 2 GiB, swap use
  exceeds 512 MiB, or sustained host load reaches a later documented abort
  threshold.
- Start with one UE in Phases 2-4 and five UEs in Phase 5. Higher counts require
  gradual Phase 7 measurement.
- Begin observability retention at 24 hours with explicit storage limits; tune
  only from measured use.
- Keep raw logs and benchmark data under ignored project-owned paths and remove
  them only by exact path after inspection.

These are safety guardrails, not measured capacity claims.

## Candidate Version Matrix

Versions are candidates recorded from official sources on 2026-08-01. A
candidate becomes a released baseline only after checksums/digests,
compatibility, licensing, and the relevant phase tests pass.

| Component | Candidate | Pinning note |
| --- | --- | --- |
| Docker Engine | `5:29.7.1-1~ubuntu.24.04~noble` | Exact package version from Docker's Ubuntu instructions |
| Docker Compose | `5.3.1` | Resolve and pin the matching repository plugin package before installation |
| kind | `0.32.0` | Verify downloaded binary checksum |
| Kubernetes node | `1.36.1` | Use kind's published `kindest/node` SHA-256 digest |
| kubectl | `1.36.1` | Match the candidate node patch version and verify checksum |
| Helm | `4.2.0` | Verify the official Linux x86-64 SHA-256 checksum |
| Open5GS | `2.7.7` | Build from the signed/tagged upstream source candidate; do not reuse host results |
| UERANSIM | `3.2.8` | Build from the upstream release candidate; review AGPL obligations |
| MongoDB | `8.0.28` candidate | Verify official container tag, digest, license, and Open5GS compatibility in Phase 2 |
| Prometheus | `3.13.0` candidate | Defer final image digest and compatibility acceptance to Phase 6 |
| Grafana | `13.1.0` candidate | Defer final image digest and compatibility acceptance to Phase 6 |
| Loki | `3.7.2` candidate | Defer final image digest and compatibility acceptance to Phase 6 |
| Grafana Alloy | `1.18` series candidate | Use instead of end-of-life Promtail; pin exact image/digest in Phase 6 |

Primary references:

- [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Engine 29 release notes](https://docs.docker.com/engine/release-notes/29/)
- [Docker Compose releases](https://github.com/docker/compose/releases)
- [kind releases](https://github.com/kubernetes-sigs/kind/releases)
- [Kubernetes supported releases](https://kubernetes.io/releases/)
- [Helm 4.2.0 release](https://github.com/helm/helm/releases/tag/v4.2.0)
- [Open5GS releases](https://github.com/open5gs/open5gs/releases)
- [UERANSIM releases](https://github.com/aligungr/UERANSIM/releases)
- [MongoDB release notes](https://www.mongodb.com/docs/manual/release-notes/)
- [Prometheus releases](https://github.com/prometheus/prometheus/releases)
- [Grafana releases](https://github.com/grafana/grafana/releases)
- [Loki releases](https://github.com/grafana/loki/releases)
- [Grafana Alloy documentation](https://grafana.com/docs/alloy/latest/)
- [Promtail end-of-life notice](https://grafana.com/docs/loki/latest/send-data/promtail/)

## Expected Host Impact Of The Next Phase

Installing Docker Engine will add packages, a system service, a Unix socket,
containerd state, boot-time behavior, bridges, routes, firewall/NAT chains,
and storage under `/var/lib`. Adding the user to the Docker group would grant
root-equivalent daemon access and must be treated as a security decision.
Images and builds will consume disk. Published ports could affect firewall
expectations.

Phase 2 should therefore:

1. capture the now-missing privileged firewall baseline;
2. review exact versioned installation commands before execution;
3. install only official pinned packages;
4. record immediate before/after services, sockets, routes, interfaces, and
   firewall state;
5. use the Compose project name `cn5g` and explicit project labels;
6. avoid host port publication unless a test requires a loopback-only port;
7. preserve the active host Open5GS and MongoDB services; and
8. verify the predecessor lab after any network-affecting experiment.

## Isolation And Rollback Proposal

- Identify every resource by the `cn5g` project/cluster name, namespace, Helm
  release, and project labels.
- Remove only exact project containers, networks, and volumes after listing
  them. Never use a global prune command.
- Delete only the named kind cluster after listing clusters; never remove all
  Kubernetes or container state.
- Compare post-cleanup interfaces, routes, firewall rules, services, disk, and
  memory to the recorded baseline.
- Do not uninstall packages or delete `/var/lib` data as routine cleanup.
  Package rollback requires a separate ownership and impact review.
- If a test temporarily changes one exact host service or rule, record its
  previous state, restore that exact state, and validate the predecessor lab.

## Gate Assessment

| Phase 0/1 requirement | State |
| --- | --- |
| Correct directory and required reading | Pass |
| Scaffold and private/public boundary reviewed | Pass |
| Read-only host inspection | Pass |
| Candidate versions from official sources | Pass as provisional candidates |
| Networking risks and provisional ranges recorded | Pass |
| Proposed ADRs | Pass |
| Repository-local Git identity and ignore proof | Pass |
| Live privileged firewall/NAT baseline | Pass |
| Ready for runtime installation | **Yes, after explicit user continuation and command review** |

## Final Phase 0/1 Decision

Phase 0 and Phase 1 pass. No known host prerequisite or conflict blocks the
container-runtime phase. The following conditions remain mandatory rather than
optional:

- do not start installation without explicit user continuation;
- use Docker's official repository and exact reviewed package versions;
- capture interfaces, routes, nftables, iptables, services, sockets, disk, and
  memory immediately before and after installation;
- preserve the LXC nftables tables and `10.0.3.0/24` network;
- keep the host Open5GS and MongoDB services running unless a later exact test
  requires a temporary, recorded exception;
- avoid wildcard host port publication; and
- stop after the Phase 2 container/Compose gate rather than creating a
  Kubernetes cluster early.
