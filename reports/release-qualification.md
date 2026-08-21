# Release Qualification

## Decision

Release decision: READY

This decision is valid only when `scripts/release-qualification.sh release-audit` passes
for the same commit. The audit is fail-closed and rejects stale local evidence,
an unaccepted claim contract, altered dashboard captures, or missing gates.

## Accepted Evidence

| Boundary | Accepted result |
| --- | --- |
| Repository quality | Shell, Python, JSON, YAML, Helm, documentation links, policy, privacy, and 202 automated tests passed |
| Claim traceability | Seven bounded release claims link to sixteen tracked evidence files with an explicit scope limit for every claim |
| Clean checkout | A new local clone of the exact release commit reproduced deterministic quality and manifest gates without untracked implementation files |
| Clean deployment | A different kind-node identity was created after reviewed deletion; the default platform installed from tracked lifecycle inputs and new local-path volumes |
| 5G service | Five synthetic UEs registered, established unique sessions across two DNNs, passed bidirectional traffic, and remained cross-DNN isolated |
| Observability | Required Prometheus targets, bounded telecom/result metrics, Loki ingestion, two data sources, and six provisioned dashboards passed |
| Local privileged gate | Platform integration, image evidence, and the nine accepted performance plus nine accepted resilience conditions were revalidated |
| Visual evidence | Four 1265x712 Grafana captures passed dashboard-UID, checksum, role, size, and PNG metadata checks |
| Scoped teardown | Observability data and credentials, core lifecycle resources, the named kind node, project kubeconfig, and empty owned network were removed in dependency order |
| Host coexistence | The unrelated host Open5GS and MongoDB services remained active after scoped teardown |

## Clean-Runtime Findings

The fresh-cluster exercise exposed ignored platform and observability stack checkpoints
whose Helm revisions and Persistent Volume Claim identities belonged to the
deleted node. The lifecycle correctly stopped instead of accepting the old
state. New guarded actions prove a different live lineage and archive the old
mode-0600 files; they neither alter Kubernetes resources nor erase the prior
record. The kind cleanup gate also distinguishes RAN processes inside the
exact owned node cgroup from unrelated host processes.

These corrections are part of the accepted source and are covered by the
quality suite. The clean deployment was resumed only after the evidence record
was rebound to a clean descendant commit while preserving the original
reviewed node identity.

## Scope And Limitations

The result covers one Linux/AMD64 workstation, one disposable kind node, one
gNB, one UPF, single-replica network functions, five synthetic UEs, two DNNs,
local-path storage, and loopback-only Grafana access. It does not establish
carrier scale, external-radio performance, multi-node availability,
production storage, automatic stateful failover, a production security
posture, or a service-level objective.

Reviewed performance campaign throughput is controlled local experimental evidence, not a
capacity claim. resilience campaign restoration was operator-assisted and is not high
availability. Raw logs, credentials, kubeconfigs, scanner reports, Software
Bills of Materials, and host snapshots remain local and ignored.

## Publication Boundary

Readiness does not itself create a version tag, GitHub release, or public
container image. Those are separate externally visible actions and require
explicit authorization after the commit-bound audit and hosted workflow pass.
