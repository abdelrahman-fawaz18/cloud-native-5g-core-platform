# ADR-0007: Version Pinning And Update Policy

## Status

Accepted

Acceptance covers the Phase 2 runtime, Phase 3 Kubernetes, Phase 4 Helm, and
Phase 6 observability inputs. Continuous Integration pins remain provisional
until their gate passes.

## Context

Tags such as `latest`, moving package repositories, installer scripts, and
unpinned Continuous Integration actions prevent reproducible evidence. Exact
versions can also become insecure, so pinning needs a deliberate update path
rather than permanent stagnation.

## Decision

- Pin host packages to exact repository version strings during installation.
- Verify downloaded binaries with official checksums or signatures.
- Pin container base and release images by human-readable version plus digest.
- Pin the kind node image by Kubernetes version and SHA-256 digest.
- Pin Helm chart dependencies and Continuous Integration actions; use commit
  SHA pins for third-party actions in the released baseline.
- Maintain one machine-readable version/provenance manifest containing source,
  version, digest/checksum, retrieval date, license, and update notes.
- Treat the Phase 1 version matrix as candidates, not final pins.
- Review updates on a planned cadence and immediately for relevant security
  advisories. Change one dependency group at a time, rebuild, scan, and rerun
  affected functional, networking, cleanup, and performance checks.
- Never use a floating `latest` tag in the verified baseline.

Phase 2 accepted Docker Engine 29.7.1, containerd 2.2.6, Buildx 0.36.0, Docker
Compose 5.3.1, Open5GS 2.7.7, UERANSIM 3.2.8, MongoDB 8.0.28, and their
recorded package versions, source checksums, base manifests, and image
identities. Phase 3 accepted kind 0.32.0 and Kubernetes/kubectl 1.36.1; Phase
4 accepted Helm 4.2.0; and Phase 6 accepted the exact Prometheus, Grafana,
Loki, Alloy, kube-state-metrics, and UE probe image identities recorded in
`versions/phase-06.env`. Later Continuous Integration inputs remain candidates
until their phase gate passes.

## Alternatives Considered

- **Always use latest:** reduces manual selection but makes a commit's behavior
  change over time.
- **Version tags without digests:** readable but registry tags can move.
- **Never update:** reproducible only temporarily and accumulates known defects
  and vulnerabilities.

## Evidence

- [kind releases](https://github.com/kubernetes-sigs/kind/releases) explicitly
  recommend digest-pinned node images.
- [Docker's Ubuntu instructions](https://docs.docker.com/engine/install/ubuntu/)
  document exact package-version installation.
- [Helm 4.2.0](https://github.com/helm/helm/releases/tag/v4.2.0) publishes
  per-platform checksums and signatures.
- Kubernetes currently supports the 1.36, 1.35, and 1.34 minor branches; the
  candidate remains inside the supported window.
- `versions/phase-02.env` records the accepted Docker package strings,
  application commits/checksums, base manifests, MongoDB manifest, and tested
  local image IDs.
- `versions/phase-03.env`, `versions/phase-04.env`, and
  `versions/phase-06.env` record the accepted Kubernetes, Helm, and
  observability artifacts and immutable identities.

## Consequences

Build and installation files become more verbose and updates require evidence.
In return, every result can name the exact software inputs and controlled
upgrades can be compared fairly.

## Reversal Or Migration

Rollback means restoring the previous manifest and exact artifact references,
then rerunning the affected acceptance tests. Do not remove unrelated package,
image, volume, or cluster state during rollback.
