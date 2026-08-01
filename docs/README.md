# Technical Documentation

This directory contains the architecture, decision records, provenance, and
operational procedures for the platform. Documentation distinguishes verified
behavior from roadmap intent and links every accepted claim to reproducible
configuration or evidence.

## Recommended Technical Review Path

1. [Project status](project-status.md) — completed gates, current boundary, and
   what has not yet been claimed.
2. [Phase 2 Docker Compose architecture](architecture/phase-02-compose-topology.md)
   — component roles, interfaces, addressing, signalling sequence, packet
   path, health dependencies, security boundaries, and lifecycle model.
3. [Image provenance](image-provenance.md) — immutable inputs, multi-stage
   build design, identity semantics, runtime users, Linux capabilities, and
   accepted local image outputs.
4. [Docker Engine installation runbook](runbooks/docker-engine-installation.md)
   — pinned runtime installation, host impact, verification, and rollback
   boundary.
5. [Compose baseline runbook](runbooks/compose-baseline.md) — exact build,
   deployment, validation, diagnostics, persistence, recreation, and cleanup
   procedures.
6. [Phase 2 validation report](../reports/02_container_baseline.md) — acceptance
   matrix, implementation incident chronology, measured results, and host
   coexistence evidence.

## Architecture Decisions

[Architecture Decision Records](adr/README.md) document the context,
alternatives, decision status, consequences, and reversal boundary for major
platform choices. A proposed record is not an accepted production decision;
its specified evidence gate must pass first.

Current decisions cover:

- candidate local Kubernetes distribution;
- container image strategy;
- network and address model;
- MongoDB persistence;
- observability stack;
- synthetic secret handling;
- version pinning; and
- Continuous Integration privileged-test boundaries.

## Evidence Discipline

Raw logs, host snapshots, runtime state, kubeconfigs, Secrets, keys, and packet
captures remain local and ignored by default. Public reports contain only
synthetic, reviewed, concise evidence. Availability, security, scale,
performance, and recovery claims are made only after their dedicated phase
produces reproducible measurements.
