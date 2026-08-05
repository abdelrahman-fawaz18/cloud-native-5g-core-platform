# Tests

The current test suite covers repository, Compose, Phase 3 feasibility, and
Phase 4 static contracts. Later phases extend it with multi-UE,
observability, performance, reliability, and release automation.

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

- multi-UE integration;
- differentiated DNN or slice behavior;
- observability and alert behavior;
- performance methodology;
- controlled failure and recovery;
- cleanup and repeatability.

Tests that require privileged networking must be clearly separated from tests
safe for hosted Continuous Integration runners.
