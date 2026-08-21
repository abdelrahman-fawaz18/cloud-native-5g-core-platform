# Automation and Validation

## Primary interface

[`cn5g-platform.sh`](cn5g-platform.sh) is the supported operator entrypoint.
It converges a selected profile rather than requiring a sequence of historical
deployment scripts.

```text
cn5g-platform.sh
├── preflight
├── deploy [--profile default|core-only|resource-limited|single-ue]
├── validate
├── status
├── dashboard
├── test alerts|persistence|subscriber-recovery
├── campaign performance|resilience ACTION
├── verify supply-chain|release
└── destroy --confirm
```

The default deployment is the complete five-UE, two-DNN platform with
observability. Lower-scope profiles are explicit diagnostic choices.

## Component helpers

The primary interface delegates to narrowly scoped helpers. They remain
public because campaigns, CI, and focused debugging need their exact actions.

| Helper | Responsibility |
| --- | --- |
| `cluster-lifecycle.sh` | create, inspect, and delete only the named kind cluster and repository kubeconfig |
| `compose-reference.sh` | build and validate the isolated Docker Compose protocol reference |
| `networking-qualification.sh` | exercise SCTP/UDP/TCP, TUN controls, packet observation, and routed N6 behavior |
| `single-ue-lifecycle.sh` | install and validate the explicit one-UE compatibility profile |
| `platform-lifecycle.sh` | install, converge, validate, recover, and roll back the five-UE/two-DNN core |
| `observability-lifecycle.sh` | install and validate metrics, logs, dashboards, alerts, and Grafana stability |
| `performance-campaign.sh` | prepare, pilot, run, analyze, and roll back the controlled traffic campaign |
| `resilience-campaign.sh` | pilot and run exact AMF/SMF/UPF fault-and-recovery conditions |
| `supply-chain-assurance.sh` | scan sources/images, generate SBOMs, test policy, and run the privileged local gate |
| `release-qualification.sh` | bind claims, clean-runtime evidence, visuals, privacy, and teardown to one commit |

## Generators and analyzers

| Script | Output |
| --- | --- |
| `generate-subscriber-secret.sh` | random synthetic material for the one-UE profile in ignored mode-0600 files |
| `generate-subscribers.py` | deterministic five-UE material derived from a local seed and tracked public plan |
| `generate-performance-dashboard-metrics.py` | bounded Prometheus fixture from the reviewed performance summary |
| `generate-resilience-dashboard-metrics.py` | bounded Prometheus fixture from the reviewed resilience summary |
| `analyze-performance.py` | deterministic CSV, JSON, SVG, and Markdown performance reductions |
| `analyze-resilience.py` | deterministic recovery distributions, plots, and report data |
| `check-supply-chain-policies.py` | repository, workflow, link, privacy, and publication checks |
| `check-release.py` | release claims, evidence links, screenshot provenance, and readiness decision |

Analyzers accept only complete campaigns whose hashes, accepted markers,
runtime identities, and required evidence agree. Failed attempts remain local
and are not silently included.

## Validators

`validate-platform.sh` is the main service validator. It checks:

- Kubernetes and Helm readiness;
- stable SBI advertisements and nine NRF profiles;
- N2 SCTP association and NG Setup;
- synthetic subscriber count and security evidence;
- PDU sessions, PFCP state, unique addresses, and unique UP/CP F-SEIDs;
- intended endpoint traffic and cross-DNN denial for each UE;
- bidirectional UE tunnel counters; and
- effective Linux capability boundaries.

`validate-single-ue.sh` provides the equivalent minimal-profile check.
`validate-compose-reference.sh` validates the Docker Compose reference.

## Safety contract

Lifecycle scripts:

- use the repository kubeconfig rather than the user's default context;
- verify the repository root, cluster name, labels, and object identities;
- preserve secrets and raw evidence outside Git;
- require explicit confirmation for destructive cleanup;
- never use global Docker prune commands, wildcard resource deletion, broad
  host route/firewall cleanup, or unscoped namespace deletion; and
- print a specific recovery instruction when a fail-closed gate stops.

Cluster deletion removes local-path data. The target node and PVC count are
reviewed before the confirmed release-qualification teardown.
