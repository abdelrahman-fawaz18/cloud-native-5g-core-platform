# Phase 6 Observability Runbook

## Installation And Acceptance

Run these commands from the repository root in a normal Ubuntu terminal. The
accepted Phase 5 release and project kind cluster must already be running.

```bash
cd /path/to/cloud-native-5g-core-platform

sudo -v
./scripts/capture-host-state.sh before-phase-06

sudo ./scripts/phase06-lab.sh preflight
sudo ./scripts/phase06-lab.sh prepare-secret
sudo ./scripts/phase06-lab.sh install
sudo ./scripts/phase06-lab.sh test-alerts
sudo ./scripts/phase06-lab.sh validate

./scripts/capture-host-state.sh after-phase-06
```

Expected terminal gates are:

```text
phase06_preflight=pass
phase06_secret_preparation=pass
phase06_install=pass
phase06_alert_lifecycle=pass tested=3
phase06_validation=pass
```

Stop if any command reports `error:`. Do not proceed to the next gate.
The preflight does not install an observability component; its Phase 5 gate
may reconcile only the two ownership-marked return routes inside the
disposable kind node if a current UPF Pod address changed.

If the Phase 5 gate reports a `curl: (28)` timeout or incomplete PFCP/GTP-U
session evidence after a long idle period, its Kubernetes resources can still
be Ready while the application session chain is stale. Use the scoped repair:

```bash
sudo ./scripts/phase05-lab.sh repair-sessions
sudo ./scripts/phase06-lab.sh preflight
```

The repair first scales the five UE Pods to zero, restarts only the
project-owned NRF-to-gNB dependency chain in its tested order, restores the UE
StatefulSet, reconciles the two owned return routes, and reruns the complete
Phase 5 validator. It does not submit a Helm change, create a release revision,
modify subscriber records, or replace the MongoDB volume.

The accepted 2026-08-05 run reached every gate above. It observed all 13
required Prometheus targets healthy, five UE probes, five AMF sessions, five
PFCP sessions, 20 custom UE series, recent Loki data, two Grafana data sources,
four dashboards, and three complete alert firing/resolution cycles.

## Opening Grafana

```bash
sudo ./scripts/phase06-lab.sh grafana
```

Keep that terminal open and browse to `http://127.0.0.1:13000`. The username
is printed; the password remains in the ignored mode-0600 file
`artifacts/secrets/phase-06/admin-password`. Press `Ctrl-C` to close the
port-forward. No persistent host port is created. The command also records the
Grafana Pod identity, restart count, and start time for the Stage A stability
soak; opening Grafana again deliberately replaces that baseline.

## Pre-Phase-7 Dashboard Hardening Gate

This bounded change updates only the `cn5g-observability` Helm release when
the Phase 6 UE-probe overlay is already active. It does not install a host
package, modify a host route, recreate the kind cluster, change subscriber
records, or replace MongoDB/Prometheus/Loki claims.

From a normal Ubuntu terminal in the repository root, first capture the host
boundary and run the static/runtime preconditions:

```bash
cd /path/to/cloud-native-5g-core-platform

sudo -v
./scripts/capture-host-state.sh before-pre-phase-07-dashboard-hardening

sudo ./scripts/phase06-lab.sh preflight
sudo ./scripts/phase06-lab.sh install
sudo ./scripts/phase06-lab.sh validate
sudo ./scripts/phase06-lab.sh test-alerts
```

Expected terminal gates include:

```text
dashboard_hardening_rollback_state=recorded observability_revision=<number>
phase06_core_overlay=already-active upgrade=skipped
grafana_runtime_hardening=pass request_memory=192Mi limit_memory=768Mi runtime_plugin_installation=disabled
phase06_validation=pass
phase06_alert_lifecycle=pass tested=3
```

If the preflight reports stale Phase 5 session evidence, stop and use only the
documented `phase05-lab.sh repair-sessions` action before retrying. Do not
weaken a dashboard query to hide a failed user-plane contract.

Start the interactive soak in one terminal:

```bash
sudo ./scripts/phase06-lab.sh grafana
```

For at least 30 minutes, open every dashboard, change the UE/DNN/component
variables, and inspect the bounded log panels. Leave that port-forward running.
After 30 minutes, open a second terminal in the repository root and run:

```bash
sudo ./scripts/phase06-lab.sh verify-grafana-soak
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
future phase cannot accidentally reuse the old rollback checkpoint. After a
pass, close the first terminal with `Ctrl-C` and capture the post-state:

```bash
./scripts/capture-host-state.sh after-pre-phase-07-dashboard-hardening
```

If runtime acceptance fails, preserve scoped diagnostics and roll back only
the observability release:

```bash
sudo ./scripts/phase06-lab.sh rollback-hardening --confirm
```

The rollback uses the exact locally recorded pre-change Helm revision, checks
that both telemetry PersistentVolumeClaim (PVC) identities were preserved,
and reruns the complete Phase 5 validator. It does not delete telemetry data,
subscriber material, the MongoDB claim, the cluster, images, or host network
state.

## Status And Repeat Validation

```bash
sudo ./scripts/phase06-lab.sh status
sudo ./scripts/phase06-lab.sh validate
```

Validation repeats the complete Phase 5 protocol/data-path gate, then verifies
observability workload readiness, required Prometheus targets, five successful
UE probes, AMF/PFCP counts, Kubernetes/container metrics, bounded custom
series, recent Loki ingestion, two Grafana data sources, and four dashboards.

## Alert Lifecycle Exercise

```bash
sudo ./scripts/phase06-lab.sh test-alerts
```

The helper sequentially activates one of three bounded exercise series, waits
for the corresponding real alert to activate, returns the series to zero, and
waits for resolution. It exercises target-down, UE-count, and user-plane rules
without stopping a 5G workload. An interruption trap restores all series to
zero.

## Diagnostics

```bash
sudo ./scripts/phase06-lab.sh status

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
sudo ./scripts/phase06-lab.sh uninstall --confirm
```

This restores the Phase 5 chart values and runs the complete Phase 5
validator. It preserves observability PVCs, namespace, Grafana Secret,
MongoDB claim, kind cluster, and images.

After uninstall, permanently remove only retained Phase 6 data and credential:

```bash
sudo ./scripts/phase06-lab.sh destroy --confirm
```

Destroy refuses to continue while the release or an unexpected workload
resource remains. Only the two exact observability PVCs, exact Grafana Secret,
and empty project-owned namespace are deletion targets.
