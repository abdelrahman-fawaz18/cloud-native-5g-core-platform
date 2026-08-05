# Metrics And Dashboards

Phase 6 implements Prometheus configuration and alert rules plus Grafana data
source/dashboard provisioning in the `cn5g-observability` Helm chart. Four
dashboards cover platform overview, 5G control/user planes, Kubernetes
resources, and correlated project logs.

Native Open5GS metrics remain authoritative for registrations and sessions. A
bounded per-ordinal/DNN sidecar metric fills the user-plane reachability gap.
Node/container metrics come from kubelet/cAdvisor; Kubernetes object state
comes from project-scoped kube-state-metrics.

All versions, retention, scrape intervals, dashboards, and rules are declared
in Git. Runtime validation rejects missing targets, stale 5G counts, failed
probes, absent provisioned views, and more than 30 custom UE series. Runtime
acceptance verified 13 required targets, five UE targets, five AMF sessions,
five PFCP sessions, 20 custom UE series, and three actionable alert rules each
firing and resolving.
