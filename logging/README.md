# Centralized Logging

Phase 6 uses Grafana Alloy and a single-replica Loki backend. Alloy discovers
only `cn5g` and `cn5g-observability`, reads container streams and Events
through the Kubernetes API, attaches bounded cluster/namespace/Pod/container/
component context, and pushes to Loki.

No host log directory, runtime socket, or unrelated namespace is collected.
Loki uses schema `v13`, a dedicated 2 GiB PVC, and 24-hour retention. Grafana
provisions Loki and a project logs dashboard as code. Raw logs remain runtime
data and require sanitization before publication. Runtime acceptance verified
recent log ingestion and successful Grafana LogQL access without publishing
the raw streams.
