# Observability Validation

Status: **accepted**

## Scope

The `cn5g-observability` Helm release provides Prometheus, Grafana, Loki,
Grafana Alloy, project-scoped kube-state-metrics, an alert fixture, and
reviewed performance and resilience result exporters. Grafana remains
cluster-internal and is reached only through an explicit loopback port-forward.

## Result

| Gate | Accepted evidence |
| --- | --- |
| Scrape health | all required live and reviewed-result targets healthy, including 5 UE targets |
| Telecom state | 5 registered UEs and 5 active PFCP sessions |
| User-plane probes | 5 source-bound probes passed through the real UE session paths |
| Cardinality | 20 custom UE series under limit 30; reviewed performance 556/600; resilience 75/100 |
| Kubernetes metrics | node and container resource metrics queryable through the API proxy |
| Logs | recent project Pod logs and Events queryable in Loki |
| Grafana | 2 provisioned datasources and 6 Git-controlled dashboards |
| Alerts | target down, UE-count mismatch, and user-plane failure each fired and resolved |
| Interactive stability | 2,606-second soak, zero restart increase, 468.6 MiB peak under 768 MiB limit |

## Evidence model

The service dashboards use current Prometheus and Loki data. Performance and
recovery dashboards use bounded metrics generated deterministically from
accepted summaries, so historical evidence remains visible without implying
that a load or fault test is currently running.

## Limitations

This is a 24-hour, single-node, single-replica observability baseline. It does
not prove backend high availability, external alert delivery, long-term
retention, production access control, or general monitoring scale.
