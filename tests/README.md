# Tests

The current test suite covers repository, Compose, Phase 3 feasibility, Phase
4 static contracts, Phase 5 identity/chart/lifecycle contracts, Phase 6
observability architecture/security/lifecycle contracts, Phase 7 experiment
and dashboard contracts, Phase 8 recovery and reviewed-metric contracts,
Phase 9 Continuous Integration and supply-chain controls, and Phase 10
release-readiness contracts.

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
four alert definitions, six valid dashboard models, 24-hour retention,
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
selector, required performance/procedure/resource panels, six-dashboard
navigation, and explicit non-production limitations. Repository-wide static
acceptance passed 164 tests before observability revision 6 completed the live
validator, alert, and interactive-soak gates.

Phase 8 static coverage verifies the exact AMF/SMF/UPF one-Pod fault contract,
three-repetition/pilot gates, strict resource and baseline preconditions,
automatic-versus-assisted timing boundary, raw-evidence privacy, resumable
attempt state, emergency restoration, MongoDB PVC preservation, invalid Helm
and API-server dry-run rejection, and deterministic analysis helpers. The
post-analysis extension additionally requires exactly 75 sanitized reviewed
series, a token-free exporter, a dedicated scrape target, six-dashboard
navigation, and separate detection/Pod-readiness/service-recovery panels. The
privileged local pilots, nine-condition matrix, MongoDB recreation, negative
configuration test, and deterministic analysis all passed on 2026-08-07; the
live dashboard gate subsequently passed with two reviewed-results targets,
exactly 75 Phase 8 series, six provisioned dashboards, all three alert
lifecycles, a 2,606-second zero-restart Grafana soak, and the final Phase 5/6
regression.

Phase 9 coverage verifies immutable workflow/tool/image identities, read-only
hosted permissions, pinned dependency installation, Kubernetes schema and
policy-as-code enforcement, secret and vulnerability scanning, five SPDX
Software Bills of Materials, four negative-control failure classes, narrow
privilege exceptions, controlled image promotion, and exact rollback state.
The live 5G regression remains a separate local privileged gate.

Phase 10 coverage verifies a bounded claim-to-evidence contract, repository
privacy and publication boundaries, license and third-party notices, clean-
clone and local-evidence commit binding, and fail-closed visual evidence. The
visual gate requires four source-UID-bound PNGs with exact checksums, minimum
dimensions, capture context, and no text or EXIF metadata. Final release tests
cannot pass while the evidence contract is a candidate or the readiness
report lacks an explicit decision.
