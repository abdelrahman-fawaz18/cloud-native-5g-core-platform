# CN5G Observability Helm Chart

This chart owns the independent Phase 6 telemetry release in the
`cn5g-observability` namespace. It does not own the 5G network functions,
subscriber Secrets, MongoDB claim, kind cluster, or host networking.

## Components

| Component | Purpose | Persistent state |
| --- | --- | --- |
| Prometheus | scrapes metrics, stores time series, evaluates alert rules | retained 2 GiB PVC |
| Grafana | renders four provisioned dashboards from two provisioned data sources | none; configuration is recreated from ConfigMaps |
| Loki | stores recent project logs for LogQL queries | retained 2 GiB PVC |
| Grafana Alloy | collects Pod logs and Events through the Kubernetes API | none |
| kube-state-metrics | translates selected Kubernetes object state into metrics | none |
| alert exercise | exposes a bounded synthetic series for safe rule-state tests | none |

Prometheus and Loki retain 24 hours of local data. Grafana is a ClusterIP-only
Service and is opened only through the loopback-bound port-forward in
`scripts/phase06-lab.sh`.

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
and three alert firing/resolution lifecycles on 2026-08-05.

See the [architecture](../../docs/architecture/phase-06-observability.md),
[runbook](../../docs/runbooks/phase-06-observability.md), and [sanitized
validation summary](../../reports/README.md#phase-6-observability-validation-summary)
for the complete signal model, lifecycle, evidence, and limitations.
