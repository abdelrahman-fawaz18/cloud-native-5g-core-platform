# ADR-0003: Pod And 5G Interface Network Model

## Status

Proposed

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
- During Phase 3, test N2, N3, and N4 first with directly observable Pod or
  workload endpoints. Use a Kubernetes Service for SCTP, PFCP, or GTP-U only
  when packet evidence proves that address translation preserves the required
  protocol behavior.
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
- No kind packet-path test has run; the address and capability model remains
  deliberately provisional.

## Consequences

This model minimizes host exposure and makes address ownership explicit. It
requires careful configuration of advertised N2/N3/N4 endpoints, packet
captures at host/node/Pod boundaries, return routing, and cleanup evidence.

## Reversal Or Migration

Phase 3 may revise individual interfaces to host networking, Multus, or an
external UERANSIM process only after a narrow failed test and documented host
impact. Remove only named project networks/routes and verify the predecessor
lab after reversal.
