# ADR-0001: Local Kubernetes Distribution

## Status

Proposed

## Context

The platform needs a reproducible local Kubernetes environment without
replacing the host's working Open5GS/UERANSIM lab or LXC setup. The cluster
must eventually carry N2 over Stream Control Transmission Protocol (SCTP), N3
GPRS Tunnelling Protocol User Plane (GTP-U), N4 Packet Forwarding Control
Protocol (PFCP), TUN-backed traffic, and N6 return routing. Containers share
the host kernel, and a local cluster can change bridges, routes, firewall
rules, storage, and boot-time services.

The host uses cgroup v2, has the required kernel primitives, and has sufficient
initial resources. Docker and Kubernetes tooling are not currently installed.

## Decision

Use `kind` 0.32.0 as the first **candidate**, with a named cluster `cn5g` and a
digest-pinned Kubernetes 1.36.1 node image. This is not an accepted platform
decision until Phase 3 proves SCTP, PFCP, GTP-U, TUN, minimum capabilities, N6
return routing, packet visibility, and scoped cleanup.

If kind fails a required primitive, preserve the evidence and evaluate k3s
through a separate change-controlled procedure. Do not switch silently.

## Alternatives Considered

- **k3s:** closer to a host service and a useful fallback, but more persistent
  host impact than a named disposable kind cluster.
- **Minikube:** flexible drivers and add-ons, but adds another abstraction and
  is not needed before testing kind's Docker-node model.
- **MicroK8s:** convenient packaging, but introduces snap-managed services and
  persistent host state.
- **Direct kubeadm:** excessive setup and cleanup scope for this single-host
  learning and evidence project.

## Evidence

- The host has x86-64, cgroup v2, AppArmor, `/dev/net/tun`, SCTP support, an
  available GTP module, and adequate initial headroom.
- [kind 0.32.0 release](https://github.com/kubernetes-sigs/kind/releases/tag/v0.32.0)
  publishes a Kubernetes 1.36.1 node image and requires digest pinning for
  reproducibility.
- No Docker or Kubernetes state currently exists, so before/after effects can
  be measured cleanly.
- No 5G networking behavior has yet been tested inside kind; acceptance would
  therefore be premature.

## Consequences

The project gains a named, automatable local cluster that can be deleted
without managing a permanent Kubernetes control-plane service. Networking is
nested inside Docker, which may complicate tunnel endpoints, packet capture,
Maximum Transmission Unit sizing, capabilities, and return routing.

## Reversal Or Migration

List clusters, delete only the exact `cn5g` cluster, and compare the host's
interfaces, routes, firewall rules, services, and disk state to the baseline.
If kind is rejected, record the failed tests here and create a k3s evaluation
procedure before installation.
