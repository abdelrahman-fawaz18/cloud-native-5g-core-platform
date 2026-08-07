# Tests

The current test suite covers repository, Compose, Phase 3 feasibility, Phase
4 static contracts, Phase 5 identity/chart/lifecycle contracts, Phase 6
observability architecture/security/lifecycle contracts, and Phase 7
experiment, analyzer, reviewed-metric, and dashboard contracts. Later phases
extend it with reliability and release automation.

Current Phase 4 coverage includes:

- configuration and schema validation;
- subscriber uniqueness and cross-component consistency;
- container and Helm artifact validation;
- deterministic Phase 4 Helm rendering, values-schema rejection, workload
  mapping, secret boundaries, least-privilege security, and storage contracts;
- unit tests for automation and reporting;
- strict NRF collection parsing and service-discovery convergence;
- controlled session-chain, upgrade, rollback, persistence, and uninstall
  contracts;
- full Kubernetes validation-script protocol, route, counter, and capability
  gates; and
- negative checks for unsafe cleanup, embedded local identity, broad host
  network mutation, and committed subscriber material.

Planned later-phase coverage includes:

- performance methodology;
- controlled failure and recovery;
- cleanup and repeatability.

Tests that require privileged networking must be clearly separated from tests
safe for hosted Continuous Integration runners.

Current Phase 5 safe coverage includes deterministic/idempotent generation,
duplicate and unsupported-DNN rejection, output-tamper detection, values-
schema drift rejection, five-ordinal StatefulSet mapping, two-DNN Open5GS
rendering, UPF policy-route isolation, Secret boundaries, controller-kind
migration, exact route ownership, PVC-preserving rollback, per-UE acceptance
markers, and capability checks. These tests validate code contracts; they do
not replace the privileged local five-UE runtime gate.

The privileged local Phase 5 gate passed on 2026-08-05. It validated five
concurrent ordinal-bound UEs, two DNN address pools, unique F-SEIDs and session
addresses, intended HTTP/ICMP paths, cross-DNN denial, per-UE bidirectional
TUN counters, an isolated invalid UE, partial-subscriber reprovision recovery,
PVC-preserving rollback, and repeat migration. Those runtime checks remain
separate from hosted Continuous Integration because they require kind, SCTP,
TUN devices, and narrowly scoped network capabilities.

Phase 6 static coverage verifies immutable image pins, deterministic rendering,
the separate-release boundary, bounded UE metric labels, exact scrape jobs,
four alert definitions, five valid dashboard models, 24-hour retention,
API-based log collection, least-privilege security/RBAC, local-only Grafana
access, scoped cleanup, and absence of committed credentials. The privileged
runtime gate passed on 2026-08-05 with 13 required healthy targets, five UE
targets, matching five-session AMF/PFCP state, five successful probes, recent
Loki ingestion, two data sources, four dashboards, bounded cardinality, and
three alert firing/resolution lifecycles.

Phase 7 coverage verifies the benchmark image and packages, temporary sidecar
security, DNN port boundary, route enforcement, reset and resume behavior,
repetition contract, deterministic analysis, and rollback safety. The
post-analysis dashboard tests additionally require the tracked summary to
generate exactly 556 bounded sanitized gauges, a token-free restricted
reviewed-results exporter, one Prometheus scrape job, the fixed 1/3/5 UE
selector, required performance/procedure/resource panels, five-dashboard
navigation, and explicit non-production limitations. Repository-wide static
acceptance passed 164 tests before observability revision 6 completed the live
validator, alert, and interactive-soak gates.
