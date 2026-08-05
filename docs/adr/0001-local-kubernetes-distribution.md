# ADR-0001: Local Kubernetes Distribution

## Status

Accepted on 2026-08-02; real single-UE workload acceptance confirmed on
2026-08-04

## Context

The platform needs a reproducible local Kubernetes environment without
replacing the host's working Open5GS/UERANSIM lab or LXC setup. The cluster
must eventually carry N2 over Stream Control Transmission Protocol (SCTP), N3
GPRS Tunnelling Protocol User Plane (GTP-U), N4 Packet Forwarding Control
Protocol (PFCP), TUN-backed traffic, and N6 return routing. Containers share
the host kernel, and a local cluster can change bridges, routes, firewall
rules, storage, and boot-time services.

The host uses cgroup v2, has the required kernel primitives, and has sufficient
initial resources. Phase 2 installed pinned Docker components and verified
their coexistence with the host lab.

## Decision

Use `kind` 0.32.0 as the local Kubernetes baseline, with a named cluster
`cn5g`, loopback-only API access, and the digest-pinned Kubernetes 1.36.1 node
image. The cluster is disposable and uses a repository-local kubeconfig.

k3s remains a documented contingency rather than an active fallback. A future
change may invoke it only if real Open5GS/UERANSIM integration exposes a
requirement that the accepted feasibility tests did not model.

## Alternatives Considered

- **k3s:** closer to a host service and a useful fallback, but more persistent
  host impact than a named disposable kind cluster.
- **Minikube:** flexible drivers and add-ons, but adds another abstraction and
  is not needed before testing kind's Docker-node model.
- **MicroK8s:** convenient packaging, but introduces snap-managed services and
  persistent host state.
- **Direct kubeadm:** excessive setup and cleanup scope for this single-host
  integration and evidence platform.

## Evidence

- The host has x86-64, cgroup v2, AppArmor, `/dev/net/tun`, SCTP support, an
  available GTP module, and adequate initial headroom.
- [kind 0.32.0 release](https://github.com/kubernetes-sigs/kind/releases/tag/v0.32.0)
  publishes a Kubernetes 1.36.1 node image and requires digest pinning for
  reproducibility.
- A single-node cluster reached Ready state with Kubernetes 1.36.1, containerd
  2.3.1, kindnet, CoreDNS, kube-proxy, and the local-path provisioner.
- Direct Pod-IP and ClusterIP Service tests passed TCP, UDP, SCTP/38412,
  UDP/8805, and UDP/2152 without effective Linux capabilities.
- `/dev/net/tun` access failed without `NET_ADMIN` and succeeded with only
  `NET_ADMIN`; no test required privileged mode.
- A routed synthetic N6 transaction crossed two TUN interfaces, an
  IP-over-UDP/2152 tunnel, the Pod network, and an explicit kind-node return
  route. Pod and node observers recorded the UDP/2152 outer packets.
- Probe cleanup removed the exact return route and namespace resources.
  Cluster cleanup removed the named node container, project kubeconfig, and
  verified empty `kind` bridge.
- A second same-runtime create/delete cycle reproduced readiness and cleanup.
  Host snapshots before and after that cycle had identical network, service,
  Docker-resource, and firewall-rule structure.
- The Helm-managed Open5GS/UERANSIM release subsequently passed real N2
  SCTP/NGAP, N4 PFCP, N3 GTP-U, TUN, N6 return routing, bidirectional user
  traffic, upgrade, rollback, and uninstall/reinstall persistence on kind.

## Consequences

The project gains a named, automatable local cluster without a permanent
Kubernetes control-plane service. Networking remains nested inside Docker:
Pods use per-Pod node-side `veth` routes, Services add virtual addresses, and
5G tunnels add another encapsulation layer. Phase 4 therefore configures
advertised N2/N3/N4 addresses deliberately and retains the verified Maximum
Transmission Unit, capability, return-routing, and packet-observation checks.

The Phase 3 probe established transport feasibility rather than protocol
semantics. Phase 4 supplied the required real single-UE Open5GS/UERANSIM
validation, so kind is now accepted for the local Helm baseline. This does not
make the single-node cluster a production or high-availability platform.

## Reversal Or Migration

List clusters, delete only `cn5g`, remove the `kind` bridge only after proving
that no kind cluster or attached container remains and that its exact address
contract matches, then remove the project kubeconfig. Compare interfaces,
routes, firewall structure, services, and Docker state with a same-runtime
baseline. If a future requirement invalidates kind, record the failed test and
create a separate k3s evaluation before installing or enabling it.
