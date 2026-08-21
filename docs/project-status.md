# Project Status

## Release state

The bounded `v1.0.0` engineering claim set is accepted. Acceptance includes a
clean-cluster deployment from tracked inputs, full platform and observability
validation, local privileged policy checks, deterministic reviewed campaign
analysis, dashboard evidence, and exact project-owned teardown.

The capability-based operator interface was accepted on 2026-08-21. Starting
from an absent cluster, its default profile deployed and independently
validated five UEs, two DNNs, observability, alert lifecycles, MongoDB
persistence, and subscriber reprovisioning. A conflicting profile request was
rejected before mutation, and scoped destruction removed only the project
cluster, kubeconfig, local-path data, and empty owned network. The underlying
`v1.0.0` claim set remains bound to the commit recorded in
[`release/release-evidence.json`](../release/release-evidence.json).

## Capability matrix

| Capability | State | Accepted gate |
| --- | --- | --- |
| Container reference | Accepted | Pinned builds, protocol-correct single-UE baseline, persistence, scoped teardown |
| Kubernetes networking | Accepted | TCP, UDP, SCTP, PFCP/GTP-U ports, TUN controls, routed return path, least privilege |
| Default 5G platform | Accepted | 5 UEs, 2 DNNs, unique sessions/F-SEIDs, bidirectional traffic, cross-DNN denial |
| Observability | Accepted | Prometheus targets, telecom metrics, bounded cardinality, Loki logs, six Grafana dashboards |
| Alert behavior | Accepted | Target-down, UE-count mismatch, and user-plane failure each fired and resolved |
| Performance engineering | Accepted | 1/3/5 UEs × 3 repetitions, route enforcement, deterministic analysis, clean restoration |
| Resilience engineering | Accepted | AMF/SMF/UPF × 3 repetitions, measured detection/restoration, preserved baseline |
| Data persistence | Accepted | MongoDB Pod recreation preserved PVC identity and five subscriber records |
| Configuration rejection | Accepted | Invalid Helm values and invalid Kubernetes objects rejected before mutation |
| Supply-chain assurance | Accepted | Pinned inputs, image scans, SPDX SBOMs, policy tests, secret scan, read-only CI |
| Release qualification | Accepted | Fresh node identity, clean deployment, validation, exact teardown, host snapshots |

## Accepted topology

```text
5 synthetic UEs
  -> 1 UERANSIM gNodeB
  -> Open5GS 5G SA core
  -> 1 UPF
     -> internet DNN (3 UEs)
     -> enterprise DNN (2 UEs)

Prometheus + Loki + Alloy + kube-state-metrics
  -> 6 provisioned Grafana dashboards
```

All application workloads are cluster-internal. Grafana is reachable only
while an operator runs the loopback port-forward. Authentication values,
kubeconfigs, raw scanner output, raw experiment attempts, and host snapshots
remain outside Git.

## Important claim boundaries

- The radio link is UERANSIM user-space simulation, not RF measurement.
- The environment is one local kind node, not a high-availability design.
- Recovery experiments required operator-assisted session restoration.
- Performance results compare controlled local conditions; they are not
  carrier capacity, production sizing, or a service-level objective.
- Local-path PVC persistence is not replicated storage or disaster recovery.
- Images were scanned and inventoried locally; no registry signing or remote
  production promotion is claimed.

## Current local runtime

The project-owned kind cluster is absent after the accepted scoped teardown.
The protected host reference services remain active, and no project RAN or
simulation processes remain. To recreate the accepted default platform, run:

```bash
sudo ./scripts/cn5g-platform.sh deploy
```

Use [`scripts/cn5g-platform.sh status`](platform-operations.md) to distinguish
accepted repository capability from the machine's current runtime state.
