# Test Strategy

The test suite protects the platform's public interface and its internal
contracts. Static tests are safe on hosted Continuous Integration (CI);
privileged protocol and networking checks run only against the local,
project-owned kind cluster.

## Hosted test boundaries

| Area | Representative checks |
| --- | --- |
| Product interface | unified command surface, complete default profile, explicit diagnostic profiles, scoped destruction |
| Helm and Kubernetes | schema validation, deterministic rendering, object mapping, probes, storage, Role-Based Access Control (RBAC), capability limits |
| 5G configuration | subscriber consistency, Data Network Name (DNN) policy, Network Repository Function (NRF) discovery, N2/N3/N4/N6 contracts |
| Observability | scrape targets, bounded labels, alerts, dashboard models, log collection, local-only Grafana exposure |
| Performance | traffic-path enforcement, 1/3/5-UE repetitions, resume behavior, deterministic analysis, reviewed metrics |
| Resilience | exact fault targets, recovery boundaries, restoration gates, persistence, deterministic analysis |
| Supply chain | pinned inputs, workflow permissions, policy-as-code, secret and vulnerability controls, Software Bill of Materials (SBOM) contracts |
| Release | claim-to-evidence links, privacy, clean-clone binding, screenshot provenance, and readiness decision |

Negative tests are first-class. They verify rejection of invalid subscribers,
unsafe Kubernetes objects, floating inputs, unexpected capabilities,
credential-like material, stale evidence, and broad cleanup behavior.

Run the hosted-safe suite from the repository root:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

## Local privileged boundary

The hosted suite cannot prove Stream Control Transmission Protocol (SCTP),
Tunnel (TUN) devices, GPRS Tunnelling Protocol User Plane (GTP-U), Packet
Forwarding Control Protocol (PFCP), source-bound UE traffic, or real Pod
replacement. Those checks require the local cluster:

```bash
sudo ./scripts/cn5g-platform.sh validate
sudo ./scripts/cn5g-platform.sh test alerts
sudo ./scripts/cn5g-platform.sh test persistence
sudo ./scripts/cn5g-platform.sh test subscriber-recovery
```

Performance and resilience campaigns add their own pilots, resource abort
floors, repeated conditions, recovery gates, and retained failed-attempt
evidence. Passing static tests never substitutes for those runtime results.
