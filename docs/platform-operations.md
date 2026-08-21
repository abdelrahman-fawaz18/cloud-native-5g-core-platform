# Platform Operations

## Supported environment

The accepted local environment is Ubuntu on AMD64 with Docker Engine, a
single-node kind cluster, `kubectl`, and Helm. Tool and image identities are
pinned in [`versions/`](../versions/README.md). The scripts refuse unsafe or
unrecognized targets and keep project kubeconfig, credentials, raw logs, and
host snapshots under ignored `artifacts/` paths.

## Default deployment

Run commands from the repository root. The default profile deploys five
synthetic User Equipments (UEs), two isolated Data Network Names (DNNs), the
Open5GS core, UERANSIM radio simulation, MongoDB persistence, and the complete
Observability stack.

```bash
sudo ./scripts/cn5g-platform.sh preflight
sudo ./scripts/cn5g-platform.sh deploy
sudo ./scripts/cn5g-platform.sh validate
```

The deployment command creates the project-owned kind cluster when it is
absent, builds and loads exact local images, creates synthetic subscriber
material outside Git, installs the Helm releases, and waits for the complete
service contract. Rerunning the same profile is idempotent. Switching profiles
requires an explicit `destroy --confirm` followed by a new deployment, which
prevents a stale mixed-profile release from being mistaken for the requested
configuration.

## Profiles

| Profile | Intended use | Core topology | Observability |
| --- | --- | --- | --- |
| `default` | Normal demonstration and review | 5 UEs, 2 DNNs | Enabled |
| `core-only` | 5G protocol work without telemetry stack | 5 UEs, 2 DNNs | Disabled |
| `resource-limited` | Lower MongoDB reservation on a constrained host | 5 UEs, 2 DNNs | Disabled |
| `single-ue` | Minimal compatibility or diagnosis | 1 UE, 1 DNN | Disabled |

Select a non-default profile explicitly:

```bash
sudo ./scripts/cn5g-platform.sh deploy --profile core-only
```

## Inspect the platform

```bash
sudo ./scripts/cn5g-platform.sh status
sudo ./scripts/cn5g-platform.sh dashboard
```

`dashboard` opens no public service. It starts a loopback-only `kubectl
port-forward` at `http://127.0.0.1:13000`; closing that terminal intentionally
ends access.

## Validation and controlled tests

```bash
sudo ./scripts/cn5g-platform.sh validate
sudo ./scripts/cn5g-platform.sh test alerts
sudo ./scripts/cn5g-platform.sh test persistence
sudo ./scripts/cn5g-platform.sh test subscriber-recovery
```

Validation checks Kubernetes readiness and the actual 5G contract: Network
Repository Function (NRF) registration, N2 SCTP association and NG Setup,
authentication, PDU sessions, N4 Packet Forwarding Control Protocol (PFCP), N3
GPRS Tunnelling Protocol User Plane (GTP-U), unique UE and F-SEID state,
bidirectional traffic, DNN selection, and cross-DNN denial. Observability
validation additionally checks scrape health, metric cardinality, logs,
datasources, dashboards, and reviewed experiment exporters.

Performance and resilience are optional campaigns over the accepted default
platform:

```bash
sudo ./scripts/cn5g-platform.sh campaign performance prepare
sudo ./scripts/cn5g-platform.sh campaign performance pilot
sudo ./scripts/cn5g-platform.sh campaign performance run
sudo ./scripts/cn5g-platform.sh campaign performance analyze

sudo ./scripts/cn5g-platform.sh campaign resilience pilot-amf
sudo ./scripts/cn5g-platform.sh campaign resilience run
sudo ./scripts/cn5g-platform.sh campaign resilience analyze
```

Each campaign records raw local evidence separately from sanitized reviewed
results. A failed condition stops safely and is never silently included in an
accepted summary.

## Cleanup

```bash
sudo ./scripts/cn5g-platform.sh destroy --confirm
```

Destruction is deliberately explicit because the kind node contains local
PersistentVolumes. The command verifies the exact project-owned cluster,
removes it, and confirms that the kubeconfig and empty project network are
gone. It does not prune Docker globally, remove host packages, or modify
unrelated host labs.
