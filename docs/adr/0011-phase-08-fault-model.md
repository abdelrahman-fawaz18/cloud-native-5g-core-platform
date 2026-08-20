# ADR-0011: Phase 8 Controlled Fault Model

- Status: Accepted
- Date: 2026-08-06

## Context

Phase 8 must measure recovery of the accepted five-UE platform without
introducing a second orchestration system, broad host mutation, or an
unsupported availability claim. The current AMF, SMF, and UPF each have one
replica. Kubernetes can replace their Pods, but replacement does not prove
that 5G signalling, PFCP state, GTP-U forwarding, or UE traffic recovered.

## Decision

The primary experiment matrix deletes exactly one project-owned AMF, SMF, or
UPF Pod at a time and lets the existing Deployment controller create its
replacement. Each component has one pilot followed by three measured
repetitions. MongoDB recreation and invalid-configuration rejection remain
separate safety tests because they answer different questions and must not be
mixed into the recovery timing distributions.

Every attempt separates four boundaries:

1. fault request;
2. Kubernetes detection;
3. replacement Pod readiness; and
4. end-to-end 5G service recovery.

The experiment records automatic recovery during a bounded observation
window. Dependency-ordered session repair is then an explicitly labelled
operator remediation and baseline-restoration action. Its time is never
reported as automatic recovery. Raw evidence is retained locally; only a
complete, reviewed campaign can generate public results or dashboard metrics.

## Consequences

- The mechanism is understandable and uses no new cluster-wide privileges.
- One intended fault is attributable to one component in each attempt.
- Pod readiness and service recovery cannot be confused.
- Results describe single-replica recovery, not high availability or
  zero-downtime behavior.
- A node-loss or chaos-framework study remains deferred beyond the minimum
  release scope.

## Safety Boundary

The runner refuses an unhealthy baseline, multiple selected Pods, changed
replica counts, insufficient host resources, or changed experiment identity.
It never deletes a Deployment, StatefulSet, Service, Secret, namespace,
PersistentVolumeClaim, route, image, or host resource.

## References

- [Kubernetes workloads](https://kubernetes.io/docs/concepts/workloads/)
- [Kubernetes probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/)
- [Prometheus HTTP API](https://prometheus.io/docs/prometheus/3.5/querying/api/)
