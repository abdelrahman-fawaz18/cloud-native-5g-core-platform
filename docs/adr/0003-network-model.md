# ADR-0003: Pod And 5G Interface Network Model

## Status

Accepted on 2026-08-02 for feasibility; real single-UE protocol behavior was
confirmed on 2026-08-04 and five-UE/two-DNN behavior on 2026-08-05

## Context

Kubernetes Service networking is designed primarily for stable application
endpoints, while 5G protocols may advertise endpoint addresses inside their
own messages. A Service address is not automatically a valid GTP-U tunnel
endpoint. UERANSIM and the User Plane Function (UPF) may also need TUN access
and the `NET_ADMIN` Linux capability. The host already owns an Open5GS UE
subnet and an LXC bridge, and Docker/Kubernetes will add more routes and NAT.

## Decision

- Use project-private container and Pod networks; do not use host networking
  by default.
- Keep Service-Based Interface (SBI) HTTP traffic on Kubernetes Services and
  cluster Domain Name System names.
- Use direct Pod endpoints where a 5G protocol advertises a tunnel or
  association address. ClusterIP Services and cluster DNS are accepted for
  stable application discovery only when the advertised protocol endpoint
  remains explicit.
- Give `/dev/net/tun` and `NET_ADMIN` only to the exact UE or UPF workload that
  proves it needs them. Full privileged mode is a last-resort experiment, not
  a baseline default.
- Avoid host-publishing Open5GS, MongoDB, and 5G transport ports. Operator
  access, when needed, is loopback-only.
- Start with explicit candidate ranges: Compose `172.28.0.0/24`, Pods
  `10.244.0.0/16`, Services `10.96.0.0/16`, DNN pools `10.60.0.0/24` and
  `10.61.0.0/24`, and controlled data network `10.62.0.0/24`.
- Preserve `10.45.0.0/16`, `10.0.3.0/24`, and the host LAN for existing
  workloads. Re-check every range before creation.
- Test packet sizes and effective Maximum Transmission Unit across nested
  encapsulation before accepting the model.
- Keep the Phase 3 N6 return route in the disposable kind-node namespace,
  where the upstream data-network router logically belongs. Discover the
  router Pod's node-side `veth` dynamically; Pod addresses and interface names
  are not stable configuration inputs.
- Use a dedicated headless PFCP Service so the SMF resolves the current UPF
  Pod address directly. Keep the ordinary UPF ClusterIP Service for its wider
  stable Service contract, but do not place kube-proxy UDP translation in the
  N4 association path.
- For differentiated DNNs, select one policy-routing table by each UE source
  pool, permit only that DNN's headless endpoint, and terminate the table with
  an unreachable default. Reconcile one ownership-marked kind-node return
  route per session pool.

## Alternatives Considered

- **Host networking for every function:** simpler addresses but weak isolation,
  extensive port conflicts, and a larger host blast radius.
- **Kubernetes Services for every 5G interface:** stable names but potentially
  invalid tunnel endpoint advertisement and opaque translation.
- **Multus secondary networks immediately:** may provide explicit interfaces,
  but adds a Container Network Interface plugin and complexity before the
  minimum feasibility question is understood.
- **Run UERANSIM outside Kubernetes:** a valid contingency if safe in-cluster
  TUN/capability behavior cannot be achieved.

## Evidence

- The host routes show no current conflicts with the candidate ranges.
- The predecessor Open5GS tunnel and LXC bridge establish ranges that must be
  reserved.
- SCTP is loaded, GTP is available, TUN exists, and IPv4 forwarding was already
  enabled before this project.
- The Compose reference proved N2 SCTP, N3 GTP-U, N4 PFCP, UE/UPF TUN devices,
  source-policy routing, controlled N6 forwarding, and complete bridge/network
  cleanup without host-network damage.
- kind assigned a distinct Pod address and node-side host route to every probe
  Pod. No shared `cni0` bridge existed, so node return routing targeted the
  router Pod's dynamically discovered `veth` interface.
- Direct Pod-IP and ClusterIP Service paths passed TCP, UDP, SCTP/38412,
  UDP/8805, and UDP/2152. This verifies transport reachability on the N2, N4,
  and N3 prerequisite ports, not NGAP, PFCP, or GTP-U semantics.
- The negative TUN Pod mounted `/dev/net/tun` but dropped all capabilities and
  received `Operation not permitted`. The positive TUN Pod added only
  `NET_ADMIN`, created `cn5gtun0`, assigned `10.63.0.1/30`, and remained
  non-privileged.
- The synthetic N6 model used `cn5gue0` (`10.60.0.2/24`) and `cn5gupf0`
  (`10.60.0.1/24`) at MTU 1400. A TCP request and response crossed both TUN
  devices and the UDP/2152 outer path; both UE TUN counters increased by five
  packets.
- A project-marked kind-node route sent `10.60.0.0/24` return traffic through
  the router Pod. The data endpoint used its normal gateway and zero effective
  capabilities rather than acting as its own router.
- The router and UE used only `NET_ADMIN`; Pod and node observers used only
  `NET_RAW`; no container used privileged mode. The sole host-network observer
  shared the disposable kind node network namespace, not the Ubuntu host.
- Exact cleanup removed the route, probe resources, cluster container,
  kubeconfig, and empty kind bridge. Same-runtime snapshots confirmed identical
  network, service, Docker-resource, and firewall-rule structure.
- The Helm release proved real SBI discovery, N2 SCTP/NGAP, N4 PFCP, N3
  GTP-U, UE/UPF TUN interfaces, and bidirectional N6 traffic without host
  networking or host-published workload ports.
- The accepted validator reconciles one protocol-186, metric-46060 route for
  `10.60.0.0/24` through the current UPF Pod's dynamically discovered
  node-side `veth`; it refuses to replace or remove an unrecognized route.
- UPF required only `NET_ADMIN`, UE required `NET_ADMIN` and `NET_RAW`, and
  the data endpoint required no effective capabilities. No Phase 4 workload
  used privileged mode.
- Phase 5 ran five simultaneous UEs through one gNB and one UPF. Three unique
  `10.60.0.x` sessions selected `internet`; two unique `10.61.0.x` sessions
  selected `enterprise`; five unique UP/CP F-SEID correlations and all five
  bidirectional TUN-counter checks passed.
- Every intended DNN endpoint was reachable and every cross-DNN HTTP attempt
  was denied. Source-aware route lookups confirmed tables 1060 and 1061, and
  two exact kind-node return routes covered the two session pools.
- Direct Pod-address PFCP through `cn5g-upf-pfcp` removed ClusterIP UDP
  translation from N4 and allowed five concurrent PFCP/GTP-U sessions to
  converge without an unknown-peer symptom.

## Consequences

This model minimizes host exposure and makes address ownership explicit. It
requires careful configuration of advertised N2/N3/N4 endpoints, packet
observation at node and Pod boundaries, return routing, and cleanup evidence.
The outer Pod network and inner UE session network are separate address
domains; a Kubernetes Service address must not silently become a GTP-U tunnel
endpoint.

## Reversal Or Migration

A later phase may revise an individual interface to Multus, another Container
Network Interface, or an external RAN only after a narrow requirement and a
documented host-impact review. Remove only named project resources and exact
owned routes, then repeat the host coexistence checks after reversal.
