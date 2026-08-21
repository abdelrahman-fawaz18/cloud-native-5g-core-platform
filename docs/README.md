# Documentation

This documentation is organized by the questions an operator or reviewer is
likely to ask. The default deployment is the complete five-UE, two-DNN
platform with observability enabled; smaller profiles are compatibility and
diagnostic options, not prerequisites.

## Start here

| Goal | Recommended document |
| --- | --- |
| Understand the complete system | [Complete system architecture](architecture/complete-system-architecture.md) |
| Deploy or operate the platform | [Platform operations](platform-operations.md) |
| Inspect Grafana evidence | [Dashboard gallery](dashboard-gallery.md) |
| Review accepted measurements | [Evidence reports](../reports/README.md) |
| Understand design trade-offs | [Architecture decision records](adr/README.md) |

## Architecture

- [Complete system architecture](architecture/complete-system-architecture.md)
  connects Helm ownership, Kubernetes execution, 5G signalling, user traffic,
  telemetry, addresses, and ports.
- [Compose reference](architecture/compose-reference.md) documents the
  protocol-correct container baseline used to qualify application behavior.
- [Observability](architecture/observability.md) describes Prometheus,
  Grafana, Loki, Alloy, kube-state-metrics, probes, and alert evaluation.
- [Dashboard design](architecture/dashboard-design.md) defines the panel,
  cardinality, visual, runtime-hardening, and screenshot evidence standards.
- [Performance engineering](architecture/performance-engineering.md) defines
  the controlled 1/3/5-UE traffic experiment and its claim boundary.
- [Resilience engineering](architecture/resilience-engineering.md) defines
  AMF, SMF, and UPF fault injection and recovery measurements.
- [Supply-chain security](architecture/supply-chain-security.md) describes
  source pinning, image scanning, Software Bills of Materials (SBOMs), policy,
  and the split between hosted and privileged local checks.
- [Release qualification](architecture/release-qualification.md) records how
  a clean deployment and exact teardown were proven.

## Operations

- [Platform operations](platform-operations.md) is the primary deployment,
  validation, troubleshooting, profile, and cleanup guide.
- [Observability runbook](runbooks/observability.md) covers dashboards,
  alert exercises, logs, and the local Grafana port-forward.
- [Performance campaign guide](../benchmarks/README.md) covers pilot and
  repeated load experiments.
- [Resilience test runbook](runbooks/resilience-testing.md) covers scoped
  component deletion and operator-assisted restoration.
- [Supply-chain assurance runbook](runbooks/supply-chain-assurance.md) covers
  scanners, SBOM generation, policy checks, and local promotion gates.
- [Release qualification runbook](runbooks/release-qualification.md) covers
  the final clean-runtime acceptance workflow.

## Evidence and status

- [Project status](project-status.md) distinguishes accepted capability from
  the current local runtime state.
- [Dashboard gallery](dashboard-gallery.md) contains sanitized, source-bound
  screenshots and explains what each panel proves.
- [Reports](../reports/README.md) contain reviewed performance, resilience,
  supply-chain, and release evidence.
- [Image provenance](image-provenance.md) records upstream source and local
  image identity controls.

## Reference material

The [engineering handbook](platform-handbook.md) retains detailed protocol,
Kubernetes, lifecycle, and validation explanations. It is a reference, not a
required sequence of deployment steps.
