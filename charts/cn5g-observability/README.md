# CN5G Observability Helm Chart

This chart owns the independent observability stack telemetry release in the
`cn5g-observability` namespace. It does not own the 5G network functions,
subscriber Secrets, MongoDB claim, kind cluster, or host networking.

## Components

| Component | Purpose | Persistent state |
| --- | --- | --- |
| Prometheus | scrapes metrics, stores time series, evaluates alert rules | retained 2 GiB PVC |
| Grafana | renders six provisioned dashboards from two provisioned data sources | none; configuration is recreated from ConfigMaps |
| Loki | stores recent project logs for LogQL queries | retained 2 GiB PVC |
| Grafana Alloy | collects Pod logs and Events through the Kubernetes API | none |
| kube-state-metrics | translates selected Kubernetes object state into metrics | none |
| alert exercise | exposes a bounded synthetic series for safe rule-state tests | none |
| performance campaign reviewed-results exporter | serves deterministic gauges generated from the accepted performance summary | none; the reviewed metric file is recreated from a ConfigMap |
| resilience campaign reviewed-results exporter | serves deterministic gauges generated from the accepted recovery summary | none; the reviewed metric file is recreated from a ConfigMap |

Prometheus and Loki retain 24 hours of local data. Grafana is a ClusterIP-only
Service and is opened only through the loopback-bound port-forward in
`scripts/observability-lifecycle.sh`.

Grafana's accepted pre-performance campaign hardening disables runtime plugin
preinstallation/update paths, preserves the read-only root filesystem, raises
the measured test memory boundary to a 192 MiB request and 768 MiB limit, and
caps Loki data-source results at 500 lines. The 2,568-second interactive soak
passed with zero restart increase and a 473.2 MiB peak. These values are not
sizing guidance for a different topology.

The fifth dashboard, **CN5G Performance And Capacity Experiments**, does not
rerun traffic or depend on expired Prometheus history. The deterministic
`generate-performance-dashboard-metrics.py` helper converts the accepted
machine-readable performance campaign summary into 556 bounded, immutable gauges. The
least-privileged reviewed-results exporter serves those gauges to Prometheus.
They describe one accepted local campaign and are deliberately named
`cn5g_performance_reviewed_*`; they must not be interpreted as live capacity.

The sixth dashboard, **CN5G Reliability And Recovery**, similarly projects the
accepted resilience campaign summary through 75 bounded `cn5g_resilience_reviewed_*` gauges.
It keeps fault detection, replacement Pod readiness, full 5G service recovery,
and user-plane disruption separate. The values describe one controlled
single-node, single-replica campaign and are not live availability metrics or
a production Recovery Time Objective.

## Security And Scope

Collectors receive read-only access only where the required signal demands
it. Alloy and kube-state-metrics are restricted to the two project namespaces;
Prometheus reaches node/container metrics through the authenticated API proxy.
No component mounts a host log directory, container-runtime socket, or host
network namespace. Container security contexts run non-root, drop Linux
capabilities, disable privilege escalation, and use read-only root filesystems
where the component supports them.

## Accepted Runtime Gate

The chart passed strict linting, deterministic rendering, Kubernetes
server-side dry-run, live installation and upgrade, target-health checks,
five-session telecom metric checks, five user-plane probes, Loki ingestion,
Grafana provisioning, a 20-series cardinality result under the limit of 30,
and three alert firing/resolution lifecycles on 2026-08-05. The enhanced
dashboard and Grafana hardening upgrade passed complete regression and alert
validation plus the interactive stability gate on 2026-08-06. The performance campaign
dashboard extension was then accepted as observability revision 6: one healthy
reviewed-results target, 556 series under the limit of 600, five dashboards,
complete platform and observability regression, all three alert lifecycles, and a 2,101-second
interactive soak with zero restarts and a 407.2 MiB Grafana peak.

See the [architecture](../../docs/architecture/observability.md),
[runbook](../../docs/runbooks/observability.md), and [sanitized
validation summary](../../reports/observability-validation.md)
for the complete signal model, lifecycle, evidence, and limitations.
