# Default Platform Validation

Status: **accepted**

## Scope

The validated topology contains five synthetic UEs, one UERANSIM gNodeB,
single-replica Open5GS network functions, two DNNs, and one MongoDB
StatefulSet on a single local kind node.

## Method

The lifecycle generated permission-restricted subscriber material from the
tracked synthetic plan, created a pre-existing Secret, server-side rendered
the Helm release, converged the dependency-ordered 5G session chain, and
installed two exact kind-node return routes. The validator correlated live
Kubernetes state, MongoDB records, Open5GS/UERANSIM logs, network interfaces,
PFCP state, endpoint responses, tunnel counters, and Linux capabilities.

## Result

| Gate | Accepted evidence |
| --- | --- |
| Workloads | 13 Deployments, 2 StatefulSets, 1 completed subscriber Job, 16 Services, 5 Ready UE Pods |
| Discovery | 9 stable NRF profiles without stale Pod advertisements |
| Radio/core transport | N2 SCTP association and NG Setup passed |
| Subscriber security | five synthetic records, 5G-AKA, NAS security, and registration passed |
| Session control | five unique UE addresses and five unique UP/CP F-SEIDs; PFCP health passed |
| User plane | intended HTTP/ICMP and positive RX/TX tunnel deltas passed for every UE |
| DNN selection | ordinals 0–2 used `internet`; ordinals 3–4 used `enterprise` |
| Isolation | every cross-DNN request was denied |
| Negative identity | an unprovisioned sixth UE received no service and caused no database side effect |
| Recovery | one removed managed subscriber was restored by the idempotent Job and all paths recovered |
| Privilege | UPF had `NET_ADMIN`; UEs had `NET_ADMIN`/`NET_RAW`; endpoints had zero effective capabilities |

## Resource observation

A ten-second steady-state cgroup sample recorded MongoDB at 162 mCPU,
241 MiB current memory, and 691 MiB peak memory. Individual UE containers
averaged 17–19 mCPU with 5–10 MiB current memory and 11–15 MiB peak memory.
These values support local scheduling requests; they are not production
sizing or capacity measurements.

## Limitations

The result covers exactly five UEs, two DNNs, one gNodeB, one UPF, one node,
and one replica per network function. It does not prove general subscriber
scale, high availability, production storage, external RAN integration, RF
behavior, or commercial capacity.
