# Helm Charts

The `cn5g/` chart packages the accepted single-UE Open5GS, MongoDB, UERANSIM,
and controlled data-network baseline. Its default values passed Phase 4
runtime, lifecycle, persistence, resource-observation, and scoped cleanup
gates.

Required chart quality includes documented values, consistent labels,
meaningful probes, resource settings, least-privilege security contexts,
deterministic rendering, linting, upgrade, rollback, and scoped uninstall.

The `cn5g-observability/` chart is an independent Phase 6 release containing
Prometheus, Grafana, Loki, Grafana Alloy, kube-state-metrics, provisioned
dashboards, alert rules, exact RBAC, bounded retention, and a controlled alert
exercise endpoint. Its lifecycle and storage remain separate from the 5G
workload release. The chart passed strict linting, deterministic rendering,
server-side dry-run, live install/upgrade, target and dashboard validation,
bounded-cardinality validation, and three alert firing/resolution exercises.
