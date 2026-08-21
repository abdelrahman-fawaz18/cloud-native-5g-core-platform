# Architecture Decision Records

Architecture Decision Records (ADRs) preserve significant technical choices.
Use sequential names such as:

```text
0001-local-kubernetes-distribution.md
0002-container-image-strategy.md
```

Each ADR should contain:

```markdown
# ADR-NNNN: Decision title

## Status

Proposed | Accepted | Superseded | Rejected

## Context

What technical problem and constraints require a decision?

## Decision

What was selected?

## Alternatives Considered

What other choices were evaluated?

## Evidence

Which tests, measurements, or authoritative sources support the decision?

## Consequences

What improves, what becomes harder, and what risks remain?

## Reversal Or Migration

How can the decision be changed safely?
```

## Current Decisions

- [ADR-0001: Local Kubernetes distribution](0001-local-kubernetes-distribution.md)
- [ADR-0002: Container image source and build strategy](0002-container-image-strategy.md)
- [ADR-0003: Pod and 5G interface network model](0003-network-model.md)
- [ADR-0004: MongoDB persistence strategy](0004-mongodb-persistence.md)
- [ADR-0005: Metrics, logs, dashboards, and alerts stack](0005-observability-stack.md)
- [ADR-0006: Synthetic secret handling](0006-synthetic-secret-handling.md)
- [ADR-0007: Version pinning and update policy](0007-version-pinning-policy.md)
- [ADR-0008: Continuous Integration and privileged test boundary](0008-ci-privileged-test-boundary.md)
- [ADR-0009: performance campaign benchmark traffic path and tooling](0009-performance-traffic-path.md)
- [ADR-0010: Reviewed performance evidence in the operational dashboard](0010-reviewed-performance-dashboard.md)
- [ADR-0011: resilience campaign controlled fault model](0011-resilience-fault-model.md)
- [ADR-0012: Reviewed reliability evidence in the operational dashboard](0012-reviewed-reliability-dashboard.md)
