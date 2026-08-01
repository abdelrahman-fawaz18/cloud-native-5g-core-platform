# ADR-0004: MongoDB Persistence Strategy

## Status

Proposed

## Context

MongoDB stores synthetic subscriber and authentication state. Pod or container
replacement must not silently erase that state, while cluster deletion must
remain understandable and reversible. The local single-node platform does not
provide production-grade distributed storage or high availability.

## Decision

- Use a named Compose volume for the container baseline.
- Use one MongoDB StatefulSet with one PersistentVolumeClaim for the
  Helm-managed local baseline after storage behavior is tested.
- Treat persistence across Pod recreation as required; persistence across
  complete kind-cluster deletion is not assumed.
- Keep subscriber definitions deterministic and re-provisionable from
  synthetic source data so a new environment can reconstruct the database.
- Define explicit backup/export and restore validation before any experiment
  that deletes the cluster or persistent volume.
- Keep database access inside project networks; do not publish TCP/27017 on the
  host.

## Alternatives Considered

- **Ephemeral database only:** simplest cleanup, but cannot prove stateful Pod
  recovery and risks confusing restart behavior with data loss.
- **Host bind mount:** easy to inspect, but couples containers to a local path
  and increases permission and accidental-deletion risk.
- **External host MongoDB:** already available, but would couple the new
  topology to the predecessor lab and weaken reproducibility.
- **Replica set/operator:** unnecessary complexity for the first local release
  and would not create real host-level high availability on one machine.

## Evidence

- Host MongoDB is active and must not be reused or stopped by default.
- The project requires persistence and recovery tests but makes no
  high-availability claim.
- The selected kind storage class and reclaim behavior have not yet been
  tested, so this ADR cannot be accepted in Phase 1.

## Consequences

State survives routine process or Pod replacement, while full cluster deletion
requires a deliberate data lifecycle decision. Deterministic provisioning
limits dependence on irreplaceable local database state.

## Reversal Or Migration

Inspect the exact volume or PersistentVolumeClaim and export required synthetic
state before changing storage. A different storage class or external database
requires restore testing and an updated ADR. Never delete all Docker volumes or
all cluster storage.
