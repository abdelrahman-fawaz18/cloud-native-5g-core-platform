# Reliability and Recovery Results

## Scope

This report summarizes one reviewed local single-node kind campaign. Each
AMF, SMF, and UPF condition deleted exactly one project-owned Pod and used
three measured repetitions. The result is not evidence of high availability,
zero downtime, carrier-grade resilience, or a production Recovery Time Objective.

## Recovery Boundaries

| Component | Median MTTD | Median Pod Ready | Median MTTR | Automatic | Assisted | Median user-plane disruption |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| AMF | 0.177 s | 4.481 s | 212.187 s | 0 | 3 | 119.406 s |
| SMF | 0.177 s | 4.432 s | 210.757 s | 0 | 3 | 72.274 s |
| UPF | 0.214 s | 6.581 s | 210.866 s | 0 | 3 | 155.825 s |

MTTD is measured from the fault request to Kubernetes API detection. MTTR
ends only when the component-specific 5G service signals recover; Pod Ready
alone is reported separately. Operator-assisted restoration is labelled and
is never presented as automatic recovery.

## Evidence And Restoration

- Campaign: `20260807T050635Z-matrix`
- Accepted attempts: 9
- Every attempt preserved the MongoDB PVC identity.
- Every attempt ended with complete platform and observability validation.
- Kubernetes events, Prometheus ranges, Loki logs, and source-bound UE probes
  remain in ignored raw evidence; this report contains reviewed reductions.

## Interpretation

Kubernetes reconciliation measures infrastructure replacement. The wider gap
between Pod readiness and MTTR, where present, represents restoration of 5G
state and user-visible service rather than container startup. Because all three
network functions have one replica on one node, an interruption is expected and
the measurements must not be extrapolated to a redundant deployment.

## Reviewed Dashboard Acceptance

The sanitized summary is exposed through exactly 75 bounded
`cn5g_resilience_reviewed_*` gauges and the sixth **CN5G Reliability And
Recovery** dashboard. Runtime validation found two healthy reviewed-results
targets and all six provisioned dashboards; all three controlled alert
scenarios fired and resolved. A 2,606-second interactive Grafana soak retained
the same Ready Pod with zero restarts and measured a 468.6 MiB peak under its
768 MiB limit. Final platform and observability regression validation passed
before the local-only post-campaign host snapshot was captured.
