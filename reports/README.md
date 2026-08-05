# Reports

This directory contains concise, sanitized validation, performance,
reliability, security, and release-readiness reports. Raw terminal transcripts
do not belong here.

Every report must state its method, result, supporting evidence, limitations,
and whether the tested gate passed or failed.

## Current Reports

- [Host preflight](01_host_preflight.md)
- [Phase 2 container baseline](02_container_baseline.md)
- [Phase 4 single-UE Kubernetes validation summary](#phase-4-single-ue-kubernetes-validation-summary)

The validation evidence below is paired with the
[complete Phase 4 visual system guide](../docs/README.md#23-phase-4-complete-system-and-operational-model),
which explains how the accepted objects, networks, protocols, storage,
security controls, and lifecycle operations connect.

## Phase 4 Single-UE Kubernetes Validation Summary

Validated on 2026-08-04 with Helm 4.2.0, kind 0.32.0, Kubernetes 1.36.1,
Open5GS 2.7.7, UERANSIM 3.2.8, MongoDB 8.0.28, and the repository-owned
data-network 0.1.0 image. Immutable inputs and accepted identities are recorded
in `versions/phase-02.env`, `versions/phase-03.env`, and
`versions/phase-04.env`.

### Method

The test loaded only accepted image identities into the named kind node,
verified the permission-restricted synthetic subscriber Secret, performed a
Helm server-side dry run, installed the `cn5g` chart, waited for the exact
subscriber Job and every workload, and reconciled service discovery and the
5G session chain. `scripts/validate-kubernetes.sh` then evaluated Kubernetes
state, component logs, network state, application traffic, TUN counters, and
effective Linux capabilities. Separate lifecycle operations recreated the
MongoDB Pod, upgraded the release, rolled it back, uninstalled/reinstalled it,
and checked the same claim and database marker after each boundary.

### Result

| Gate | Accepted evidence |
| --- | --- |
| Packaging | Strict Helm lint and deterministic rendering passed; invalid values were rejected by schema tests |
| Workloads | Thirteen Deployments and one MongoDB StatefulSet reached Ready; the exact revision-scoped subscriber Job completed |
| Service discovery | All nine SBI functions advertised stable Service DNS names and the NRF exposed nine matching profiles without stale Pod addresses |
| N2 | SCTP association and NG Setup passed between the gNB and AMF |
| Subscriber security | Synthetic subscriber record, 5G-AKA, NAS security, and registration passed |
| Session control | IPv4 PDU session, PFCP association/session, and GTP-U session evidence passed |
| User plane | HTTP and ICMP transactions passed through the UE TUN, gNB, N3 GTP-U, UPF, N6, and controlled data endpoint |
| Bidirectionality | UE and UPF receive/transmit counters each increased by at least eight packets during controlled traffic |
| N6 return path | One ownership-marked route inside the kind node returned `10.60.0.0/24` through the current UPF Pod |
| Least privilege | UPF effective capabilities were `0x1000`; UE was `0x3000`; the data endpoint was zero; no workload was privileged |
| Persistence | The same MongoDB claim UID and backing volume survived Pod recreation, upgrade, rollback, and Helm uninstall/reinstall |
| Release lifecycle | Upgrade passed at revision 10; rollback restored revision-7 configuration as revision 11; reinstall converged as a fresh revision 1 |
| Cleanup scope | Uninstall removed the release and two verified historical Jobs while retaining the bound claim, namespace, and subscriber Secret |

The final fresh-install validation ended with
`kubernetes_validation=pass` and `phase04_validation=pass`.

### Resource Baseline

Two ten-second cgroup v2 samples were collected in the validated single-UE
steady state. MongoDB averaged 143-170 mCPU with 217-222 MiB current and
380-381 MiB peak memory. Open5GS control-plane functions averaged 12-22 mCPU
and used 6-40 MiB. UPF averaged 14 mCPU and used 7-17 MiB across the samples.
The data endpoint averaged 6-8 mCPU and used 3-8 MiB. gNB averaged 11-15 mCPU
and used 7-17 MiB; UE averaged 16-17 mCPU and used 9-12 MiB.

The accepted requests are documented in `charts/cn5g/values.yaml`. The second
sample confirmed that they were applied and that every measured average and
current-memory value remained below its request. Memory peaks remained below
limits. This observation defines scheduling inputs for the single-UE baseline;
it is not a capacity or performance benchmark.

### Limitations

The result covers one synthetic UE on one local node and one replica per
component. It does not demonstrate multi-node rescheduling, high availability,
production storage, external RAN integration, multi-UE concurrency,
differentiated DNN/slice behavior, carrier-grade throughput, or production
security posture. The local-path PersistentVolume does not survive deletion
of the kind node. Those boundaries prevent the report from being interpreted
as a production-readiness or scale claim.
