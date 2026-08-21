# Release Qualification Runbook

## Safety Boundary

Run every command from the repository root. Candidate and clean-clone checks
write only below ignored `artifacts/release/`. The local privileged gate
queries the existing project-owned cluster and runs the accepted platform,
Observability stack, and supply-chain assurance validators. It does not delete a namespace, Persistent
Volume Claim, image, route, or cluster.

The full clean deployment/teardown exercise is intentionally separate. It can
remove the project-owned kind node and its local-path data, so it requires a
fresh host snapshot, exact resource inspection, and explicit confirmation at
the time it is performed.

## Candidate Gates

```bash
cd ~/projects/cloud-native-5g-core-platform
./scripts/release-qualification.sh preflight
./scripts/release-qualification.sh quality
```

Expected final markers are `release_preflight=pass` and
`release_quality=pass`. A failure is a stop signal; fix the named source or
evidence issue and rerun the same action.

## Clean-Clone Reproduction

Commit the candidate branch and ensure `git status --short` is empty, then run:

```bash
./scripts/release-qualification.sh clean-checkout
```

The helper clones the current branch into a new ignored directory, runs the
Supply-chain assurance quality and manifest gates plus the release qualification candidate checks, and
records the exact commit. It never deletes an earlier reproduction directory.

## Dashboard Capture

Start the existing loopback-only Grafana session:

```bash
sudo ./scripts/observability-lifecycle.sh grafana
```

Capture the service overview, telecom/DNN view, reviewed performance view, and
reviewed recovery view. Keep Grafana in kiosk or full-screen mode, exclude
browser chrome, and use a time range that visibly contains the accepted data.
Provide the local image paths for inspection. The images are not accepted
until they are cropped if necessary, stripped of metadata, copied into
`docs/images/dashboards/`, checksum-recorded, and passed by:

```bash
./scripts/release-qualification.sh verify-visuals
```

## Local Privileged Gate

Capture a host snapshot first, then run:

```bash
sudo -v
./scripts/capture-host-state.sh before-release-qualification
sudo ./scripts/release-qualification.sh privileged-gate
```

The final marker is `release_privileged_gate=pass`. If a dependency validator
fails, use only its scoped recovery action and rerun this gate.

## Final Audit

After the public evidence contract and readiness report are accepted:

```bash
./scripts/release-qualification.sh release-audit
./scripts/capture-host-state.sh after-release-qualification
```

`release_audit=pass` means the current commit has matching public,
clean-clone, clean-runtime, local privileged, and visual evidence. It does not
itself create a tag, GitHub release, or public image. Those remain separately
confirmed publication actions.

## Clean Deployment And Teardown Exit Gate

This exercise permanently removes the current `cn5g` kind node and all
project-owned local-path data inside it. Reviewed performance and recovery results, scanner
evidence, generated Secret material, and dashboard captures are stored outside
the node and remain available. Do not run these commands without a fresh host
snapshot and explicit confirmation.

First record the exact targets:

```bash
sudo ./scripts/release-qualification.sh clean-runtime-preflight
```

The output must name only cluster `cn5g`, node `cn5g-control-plane`, and the
reviewed project PVC count. Then remove the old project cluster and verify its
absence:

```bash
sudo ./scripts/cluster-lifecycle.sh delete --confirm
sudo ./scripts/cluster-lifecycle.sh verify-delete
```

If the clean exercise stops because it exposes a repository defect, correct
and commit that defect before continuing. The restricted target record still
contains the deleted node identity. Rebind it only to a clean descendant
commit after a different replacement node exists:

```bash
sudo ./scripts/release-qualification.sh rebind-clean-runtime
```

The action rejects a dirty tree, a non-descendant commit, a source node that
still exists, or an unchanged replacement-node identity.

If the fresh platform or observability stack lifecycle detects an ignored checkpoint from
the deleted cluster, archive the checkpoint only through its guarded action:

```bash
sudo ./scripts/platform-lifecycle.sh reset-stale-state --confirm
sudo ./scripts/observability-lifecycle.sh reset-stale-state --confirm
```

Both actions require proof that the live release and persistent-volume
lineage differ from the retained state; neither action changes the live stack.

Create a new node and deploy the final stack through the public platform
interface. The command builds or loads the pinned images, generates local
synthetic subscriber material, and installs both Helm releases:

```bash
sudo ./scripts/cn5g-platform.sh preflight
sudo ./scripts/cn5g-platform.sh deploy
sudo ./scripts/cn5g-platform.sh validate
sudo ./scripts/release-qualification.sh verify-clean-deployment
```

The verifier requires a different kind-node container identity and ends with
`release_clean_deployment=pass`. It also refreshes the commit-bound privileged
evidence.

Finally exercise the public, ownership-checked cleanup and then validate the
release-specific teardown evidence:

```bash
sudo ./scripts/cn5g-platform.sh destroy --confirm
sudo ./scripts/release-qualification.sh verify-clean-teardown
```

The final marker is
`release_clean_runtime=pass deployment=pass teardown=pass`. If a command
fails, preserve its output and resume only through that component's documented
recovery action; do not skip forward or use broad Docker/Kubernetes cleanup.
