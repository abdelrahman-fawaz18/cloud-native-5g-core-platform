# Observability Runbook

## Installation And Acceptance

Run these commands from the repository root in a normal Ubuntu terminal. The
accepted platform release and project kind cluster must already be running.

```bash
cd /path/to/cloud-native-5g-core-platform

sudo -v
./scripts/capture-host-state.sh before-observability

sudo ./scripts/observability-lifecycle.sh preflight
sudo ./scripts/observability-lifecycle.sh prepare-secret
sudo ./scripts/observability-lifecycle.sh install
sudo ./scripts/observability-lifecycle.sh test-alerts
sudo ./scripts/observability-lifecycle.sh validate

./scripts/capture-host-state.sh after-observability
```

Expected terminal gates are:

```text
observability_preflight=pass
observability_secret_preparation=pass
observability_install=pass
observability_alert_lifecycle=pass tested=3
observability_validation=pass
```

Stop if any command reports `error:`. Do not proceed to the next gate.
The preflight does not install an observability component; its platform gate
may reconcile only the two ownership-marked return routes inside the
disposable kind node if a current UPF Pod address changed.

If the platform gate reports a `curl: (28)` timeout or incomplete PFCP/GTP-U
session evidence after a long idle period, its Kubernetes resources can still
be Ready while the application session chain is stale. Use the scoped repair:

```bash
sudo ./scripts/platform-lifecycle.sh repair-sessions
sudo ./scripts/observability-lifecycle.sh preflight
```

The repair first scales the five UE Pods to zero, restarts only the
project-owned NRF-to-gNB dependency chain in its tested order, restores the UE
StatefulSet, reconciles the two owned return routes, and reruns the complete
Platform validator. It does not submit a Helm change, create a release revision,
modify subscriber records, or replace the MongoDB volume.

The accepted 2026-08-05 run reached every gate above. It observed all 13
required Prometheus targets healthy, five UE probes, five AMF sessions, five
PFCP sessions, 20 custom UE series, recent Loki data, two Grafana data sources,
four dashboards, and three complete alert firing/resolution cycles.

## Opening Grafana

```bash
sudo ./scripts/observability-lifecycle.sh grafana
```

Keep that terminal open and browse to `http://127.0.0.1:13000`. The username
is printed; the password remains in the ignored mode-0600 file
`artifacts/secrets/observability/admin-password`. Press `Ctrl-C` to close the
port-forward. No persistent host port is created. The command also records the
Grafana Pod identity, restart count, and start time for the Stage A stability
soak; opening Grafana again deliberately replaces that baseline.

## Pre-performance campaign Dashboard Hardening Gate

This bounded change updates only the `cn5g-observability` Helm release when
the observability stack UE-probe overlay is already active. It does not install a host
package, modify a host route, recreate the kind cluster, change subscriber
records, or replace MongoDB/Prometheus/Loki claims.

From a normal Ubuntu terminal in the repository root, first capture the host
boundary and run the static/runtime preconditions:

```bash
cd /path/to/cloud-native-5g-core-platform

sudo -v
./scripts/capture-host-state.sh before-pre-performance-dashboard-hardening

sudo ./scripts/observability-lifecycle.sh preflight
sudo ./scripts/observability-lifecycle.sh install
sudo ./scripts/observability-lifecycle.sh validate
sudo ./scripts/observability-lifecycle.sh test-alerts
```

Expected terminal gates include:

```text
dashboard_hardening_rollback_state=recorded observability_revision=<number>
observability_core_overlay=already-active upgrade=skipped
grafana_runtime_hardening=pass request_memory=192Mi limit_memory=768Mi runtime_plugin_installation=disabled
observability_validation=pass
observability_alert_lifecycle=pass tested=3
```

If the preflight reports stale platform session evidence, stop and use only the
documented `platform-lifecycle.sh repair-sessions` action before retrying. Do not
weaken a dashboard query to hide a failed user-plane contract.

Start the interactive soak in one terminal:

```bash
sudo ./scripts/observability-lifecycle.sh grafana
```

For at least 30 minutes, open every dashboard, change the UE/DNN/component
variables, and inspect the bounded log panels. Leave that port-forward running.
After 30 minutes, open a second terminal in the repository root and run:

```bash
sudo ./scripts/observability-lifecycle.sh verify-grafana-soak
```

The accepted result is:

```text
grafana_interactive_soak=pass duration_seconds=<at-least-1800> restarts_delta=0 peak_memory_mib=<measured> limit_memory_mib=768 headroom=pass
```

The accepted 2026-08-06 run reported `duration_seconds=2568`,
`restarts_delta=0`, and `peak_memory_mib=473.2` under the 768 MiB limit.

The gate fails if the Pod changes, the restart count increases, runtime plugin
installation appears, the duration is short, or the 30-minute peak reaches
80% of the limit. A pass consumes both temporary acceptance-state files so a
future capability cannot accidentally reuse the old rollback checkpoint. After a
pass, close the first terminal with `Ctrl-C` and capture the post-state:

```bash
./scripts/capture-host-state.sh after-pre-performance-dashboard-hardening
```

If runtime acceptance fails, preserve scoped diagnostics and roll back only
the observability release:

```bash
sudo ./scripts/observability-lifecycle.sh rollback-hardening --confirm
```

The rollback uses the exact locally recorded pre-change Helm revision, checks
that both telemetry PersistentVolumeClaim (PVC) identities were preserved,
and reruns the complete platform validator. It does not delete telemetry data,
subscriber material, the MongoDB claim, the cluster, images, or host network
state.

## Status And Repeat Validation

```bash
sudo ./scripts/observability-lifecycle.sh status
sudo ./scripts/observability-lifecycle.sh validate
```

Validation repeats the complete platform protocol/data-path gate, then verifies
Observability workload readiness, required Prometheus targets, five successful
UE probes, AMF/PFCP counts, Kubernetes/container metrics, bounded custom
series, recent Loki ingestion, two Grafana data sources, and all five
dashboards. After the performance campaign extension it additionally requires one healthy
reviewed-results exporter, nine accepted conditions, three repetitions per
level, and exactly 556 generated reviewed series under the hard bound of 600.

## Alert Lifecycle Exercise

```bash
sudo ./scripts/observability-lifecycle.sh test-alerts
```

The helper sequentially activates one of three bounded exercise series, waits
for the corresponding real alert to activate, returns the series to zero, and
waits for resolution. It exercises target-down, UE-count, and user-plane rules
without stopping a 5G workload. An interruption trap restores all series to
zero.

## Diagnostics

```bash
sudo ./scripts/observability-lifecycle.sh status

sudo kubectl \
  --kubeconfig artifacts/kubernetes/cn5g.kubeconfig \
  --namespace cn5g-observability \
  get events --sort-by=.lastTimestamp

sudo kubectl \
  --kubeconfig artifacts/kubernetes/cn5g.kubeconfig \
  --namespace cn5g-observability \
  logs statefulset/cn5g-observability-prometheus --tail=100
```

Use `prometheus`, `loki`, `alloy`, `grafana`, or `kube-state-metrics` as the
exact component. Sanitize logs and screenshots before publication.

Two implementation-specific diagnostics are worth preserving:

- kube-state-metrics serves startup health from `/healthz` on its metrics
  listener and readiness from `/readyz` on its telemetry listener. A probe
  failure here means the declared endpoint/port pair should be checked before
  increasing a timeout.
- Prometheus 3 requires an explicit fallback scrape protocol for the minimal
  alert-exercise endpoint because that endpoint intentionally emits the text
  format without a full HTTP content type. The chart already declares this;
  do not weaken target validation to hide a protocol negotiation error.

The observability install uses rollback-on-failure. If a first attempt fails,
Helm removes the failed release but retained telemetry claims can remain by
design. Diagnose the exact failed workload, apply the chart fix, and rerun
`install`; do not delete the claims or use a broad cleanup command.

## Scoped Uninstall And Destruction

Remove the stack and UE sidecars while retaining telemetry data and the local
credential:

```bash
sudo ./scripts/observability-lifecycle.sh uninstall --confirm
```

This restores the platform chart values and runs the complete platform
validator. It preserves observability PVCs, namespace, Grafana Secret,
MongoDB claim, kind cluster, and images.

After uninstall, permanently remove only retained observability stack data and credential:

```bash
sudo ./scripts/observability-lifecycle.sh destroy --confirm
```

Destroy refuses to continue while the release or an unexpected workload
resource remains. Only the two exact observability PVCs, exact Grafana Secret,
and empty project-owned namespace are deletion targets.
