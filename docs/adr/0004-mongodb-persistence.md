# ADR-0004: MongoDB Persistence Strategy

## Status

Accepted on 2026-08-04 for the Compose and local Kubernetes baselines

## Context

MongoDB stores synthetic subscriber and authentication state. Pod or container
replacement must not silently erase that state, while cluster deletion must
remain understandable and reversible. The local single-node platform does not
provide production-grade distributed storage or high availability.

## Decision

- Use a named Compose volume for the container baseline.
- Use one MongoDB StatefulSet with one retained 2 GiB PersistentVolumeClaim
  for the Helm-managed local baseline.
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
- Compose reference proved that the two named MongoDB volumes survive container/network
  teardown, preserve an independent synthetic marker, and support a complete
  protocol revalidation after recreation.
- Confirmed cleanup removed only the two project volumes and left host MongoDB
  active.
- The kind local-path provisioner bound the `standard` StorageClass claim and
  reused the exact claim UID and backing volume after MongoDB Pod recreation.
- A synthetic database marker survived a complete Helm uninstall/reinstall;
  the lifecycle helper then removed only its dedicated evidence collection.
- Controlled upgrade to revision 10 and rollback to the accepted revision-7
  configuration as revision 11 preserved the exact claim identity.
- Scoped uninstall removed release resources and verified historical Jobs but
  retained the bound claim, namespace, and subscriber Secret. Reinstall
  converged as a new revision-1 release against that retained storage.

## Consequences

State survives routine Pod replacement and Helm release uninstall/reinstall.
Full kind-cluster deletion still removes local-path backing storage and
therefore requires a deliberate export or data-lifecycle decision.
Deterministic provisioning limits dependence on irreplaceable local database
state. This single replica does not provide high availability.

## Reversal Or Migration

Inspect the exact volume or PersistentVolumeClaim and export required synthetic
state before changing storage. A different storage class or external database
requires restore testing and an updated ADR. Never delete all Docker volumes or
all cluster storage.
