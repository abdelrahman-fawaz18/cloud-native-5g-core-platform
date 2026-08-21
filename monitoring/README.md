# Metrics And Dashboards

The `cn5g-observability` Helm chart manages Prometheus configuration and alert
rules together with Grafana data sources and six provisioned dashboards. The
views cover service health, 5G control and user planes, Kubernetes resources,
correlated logs, reviewed performance, and reviewed recovery evidence.

Native Open5GS metrics remain authoritative for registrations and sessions. A
bounded per-ordinal/DNN sidecar metric fills the user-plane reachability gap.
Node/container metrics come from kubelet/cAdvisor; Kubernetes object state
comes from project-scoped kube-state-metrics.

All versions, retention, scrape intervals, dashboards, and rules are declared
in Git. Runtime validation rejects missing targets, stale 5G counts, failed
probes, absent provisioned views, and more than 30 custom UE series. Runtime
acceptance verified every required target, five UE targets, five AMF sessions,
five PFCP sessions, 20 custom UE series, and three actionable alert rules each
firing and resolving.
