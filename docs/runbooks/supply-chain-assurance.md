# Supply-Chain Assurance Runbook

## Safety Boundary

Run commands from the repository root on the Ubuntu host. Safe checks write
only ignored reports and checksum-verified tools below `artifacts/`. Docker
actions build local `cn5g/*:assurance` verification images but do not push them.
The privileged gate reads the existing project cluster and runs the accepted
Platform and observability stack validators; it does not create a CI runner or deploy from
GitHub.

## Before Snapshot

```bash
cd ~/projects/cloud-native-5g-core-platform
sudo -v
./scripts/capture-host-state.sh before-supply-chain
```

Expected result:

```text
snapshot created: .../artifacts/host-state/before-supply-chain
```

Do not proceed to Docker builds or cluster changes if the snapshot fails.

## Safe Local Gates

Run as the normal user:

```bash
./scripts/supply-chain-assurance.sh preflight
./scripts/supply-chain-assurance.sh bootstrap-tools
./scripts/supply-chain-assurance.sh quality
./scripts/supply-chain-assurance.sh manifests
./scripts/supply-chain-assurance.sh scan-repository
./scripts/supply-chain-assurance.sh test-controls
```

The final markers are respectively:

```text
assurance_preflight=pass
assurance_tool_bootstrap=pass tools=11 checksums=verified
assurance_quality_gate=pass
assurance_manifest_gate=pass charts=2 schema=kubernetes-1.36 policy=conftest
assurance_repository_scan=pass secrets=absent severity=high-critical
assurance_negative_controls=pass workflow=unpinned image=floating manifest=privileged secret=synthetic
```

`safe-gate` runs the same sequence in one command. A finding is a stop signal:
review the retained report, fix or narrowly document it, and rerun the gate.
Never lower the severity or broadly exclude a directory merely to obtain a
pass.

## Image Supply-Chain Gate

Docker access on this host is intentionally through `sudo`:

```bash
sudo ./scripts/supply-chain-assurance.sh image-gate
```

This builds five verification images, rejects fixed high/critical image
findings, and creates five SPDX JSON SBOMs. Expected final markers:

```text
assurance_image_build=pass images=5 registry_push=none
assurance_image_scans=pass images=5 severity=high-critical
assurance_sbom=pass format=spdx-json images=5
assurance_image_gate=pass
```

The command can take tens of minutes when Docker layers or vulnerability data
are not cached. It never pushes an image or prunes existing images and caches.

## Controlled Image Promotion And Live Regression

The Alpine update changes the active data-network endpoint. Promotion is
therefore a separate local action after its scan and SBOM pass. It records the
current Helm revision and exact previous image, retags only the accepted
Supply-chain assurance endpoint, loads it into the project-owned kind node, performs a
server-side Helm dry run, and validates capabilities 5 and 6. The reviewed benchmark
image remains under `cn5g/benchmark:assurance` because performance campaign is disabled.
The action is resumable: when the exact accepted image is already active and
both endpoint Deployments are Ready, it skips a second core Helm upgrade and
continues with validation.

```bash
sudo ./scripts/supply-chain-assurance.sh promote-images
```

Required markers include:

```text
assurance_alpine_image_identity=pass images=2
assurance_image_evidence=pass scans=5 sboms=5
server_side_assurance_promotion_dry_run=pass
kubernetes_node_container_metrics=pass
prometheus_target_health=pass
observability_validation=pass
assurance_image_promotion=pass image=cn5g/data-network:0.1.0
```

If the node or cAdvisor target is unhealthy, stop and inspect its Prometheus
target error. Do not broaden the proxy verbs or bypass Transport Layer Security
(TLS) without reviewing the exact failure.

## Local Privileged Release Gate

After platform and observability stack are healthy:

```bash
sudo ./scripts/supply-chain-assurance.sh privileged-gate
```

Expected result:

```text
assurance_privileged_gate=pass scope=local-only report=.../local-privileged-gate.json
```

This report is permission-restricted and ignored by Git. It complements, but
does not replace, the hosted workflow.

## Hosted Workflow

After local acceptance, review the diff and open the feature branch as a pull
request. The GitHub Actions workflow runs two independent jobs: safe
deterministic checks and the image supply-chain gate. Merge only after both
jobs and the final hosted gate pass, and after the local privileged evidence is
reviewed. Publishing the branch and opening the pull request require explicit
authorization.

## Failure And Recovery

- Safe checks change no cluster or host networking state; fix the input and
  rerun the same command.
- Failed image scans retain reports under `artifacts/supply-chain/scans/images/`.
  Fix the image source or document one narrow, expiring exception.
- A failed or rejected data-network promotion retains its exact rollback state
  under ignored, permission-restricted supply-chain assurance artifacts. After reviewing the
  failure, restore the retained image and Helm revision with:

  ```bash
  sudo ./scripts/supply-chain-assurance.sh rollback-images --confirm
  ```

  Success ends with `assurance_image_promotion_rollback=pass`. The action does
  not remove volumes, namespaces, images, routes, or the cluster.
- A failed live validation uses the existing platform or observability stack scoped
  recovery actions; do not delete namespaces, volumes, or the kind cluster.
- The temporary branch can be abandoned without changing `main`. Ignored
  supply-chain assurance reports and local verification images may remain safely; no broad
  Docker cleanup is part of rollback.

## Final Snapshot

After hosted and local gates are accepted:

```bash
./scripts/capture-host-state.sh after-supply-chain
```
