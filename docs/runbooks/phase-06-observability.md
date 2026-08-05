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
port-forward. No persistent host port is created.

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
