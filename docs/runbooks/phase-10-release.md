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
clean-clone, local privileged, and visual evidence. It does not itself create
a tag, GitHub release, or public image. Those remain separately confirmed
publication actions.
