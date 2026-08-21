# Phase 10 Release Runbook

## Safety Boundary

Run every command from the repository root. Candidate and clean-clone checks
write only below ignored `artifacts/phase-10/`. The local privileged gate
queries the existing project-owned cluster and runs the accepted Phase 5,
Phase 6, and Phase 9 validators. It does not delete a namespace, Persistent
Volume Claim, image, route, or cluster.

The full clean deployment/teardown exercise is intentionally separate. It can
remove the project-owned kind node and its local-path data, so it requires a
fresh host snapshot, exact resource inspection, and explicit confirmation at
the time it is performed.

## Candidate Gates

```bash
cd ~/projects/cloud-native-5g-core-platform
./scripts/phase10-lab.sh preflight
./scripts/phase10-lab.sh quality
```

Expected final markers are `phase10_preflight=pass` and
`phase10_quality=pass`. A failure is a stop signal; fix the named source or
evidence issue and rerun the same action.

## Clean-Clone Reproduction

Commit the candidate branch and ensure `git status --short` is empty, then run:

```bash
./scripts/phase10-lab.sh clean-checkout
```

The helper clones the current branch into a new ignored directory, runs the
Phase 9 quality and manifest gates plus the Phase 10 candidate checks, and
records the exact commit. It never deletes an earlier reproduction directory.

## Dashboard Capture

Start the existing loopback-only Grafana session:

```bash
sudo ./scripts/phase06-lab.sh grafana
```

Capture the service overview, telecom/DNN view, reviewed performance view, and
reviewed recovery view. Keep Grafana in kiosk or full-screen mode, exclude
browser chrome, and use a time range that visibly contains the accepted data.
Provide the local image paths for inspection. The images are not accepted
until they are cropped if necessary, stripped of metadata, copied into
`docs/images/dashboards/`, checksum-recorded, and passed by:

```bash
./scripts/phase10-lab.sh verify-visuals
```

## Local Privileged Gate

Capture a host snapshot first, then run:

```bash
sudo -v
./scripts/capture-host-state.sh before-phase-10-release-gate
sudo ./scripts/phase10-lab.sh privileged-gate
```

The final marker is `phase10_privileged_gate=pass`. If a dependency validator
fails, use only its scoped recovery action and rerun this gate.

## Final Audit

After the public evidence contract and readiness report are accepted:

```bash
./scripts/phase10-lab.sh release-audit
./scripts/capture-host-state.sh after-phase-10
```

`phase10_release_audit=pass` means the current commit has matching public,
clean-clone, clean-runtime, local privileged, and visual evidence. It does not
itself create a tag, GitHub release, or public image. Those remain separately
confirmed publication actions.

## Clean Deployment And Teardown Exit Gate

This exercise permanently removes the current `cn5g` kind node and all
project-owned local-path data inside it. Reviewed Phase 7/8 results, scanner
evidence, generated Secret material, and dashboard captures are stored outside
the node and remain available. Do not run these commands without a fresh host
snapshot and explicit confirmation.

First record the exact targets:

```bash
sudo ./scripts/phase10-lab.sh clean-runtime-preflight
```

The output must name only cluster `cn5g`, node `cn5g-control-plane`, and the
reviewed project PVC count. Then remove the old project cluster and verify its
absence:

```bash
sudo ./scripts/kind-feasibility.sh delete --confirm
sudo ./scripts/kind-feasibility.sh verify-delete
```

Create a new node and deploy the final stack from tracked inputs and retained
local Secret material:

```bash
sudo ./scripts/kind-feasibility.sh preflight
sudo ./scripts/kind-feasibility.sh create
sudo ./scripts/helm-lab.sh load-images
sudo ./scripts/helm-lab.sh prepare-secret
sudo ./scripts/helm-lab.sh install
sudo ./scripts/phase05-lab.sh prepare-secret
sudo ./scripts/phase05-lab.sh upgrade
sudo ./scripts/phase06-lab.sh prepare-secret
sudo ./scripts/phase06-lab.sh install
sudo ./scripts/phase10-lab.sh verify-clean-deployment
```

The verifier requires a different kind-node container identity and ends with
`phase10_clean_deployment=pass`. It also refreshes the commit-bound privileged
evidence.

Finally exercise cleanup in dependency order:

```bash
sudo ./scripts/phase06-lab.sh uninstall --confirm
sudo ./scripts/phase06-lab.sh destroy --confirm
sudo ./scripts/phase05-lab.sh rollback
sudo ./scripts/phase05-lab.sh remove-secret --confirm
sudo ./scripts/helm-lab.sh uninstall --confirm
sudo ./scripts/kind-feasibility.sh delete --confirm
sudo ./scripts/kind-feasibility.sh verify-delete
sudo ./scripts/phase10-lab.sh verify-clean-teardown
```

The final marker is
`phase10_clean_runtime=pass deployment=pass teardown=pass`. If a command
fails, preserve its output and resume only through that component's documented
recovery action; do not skip forward or use broad Docker/Kubernetes cleanup.
