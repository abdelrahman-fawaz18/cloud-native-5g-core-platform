# ADR-0007: Version Pinning And Update Policy

## Status

Accepted

Acceptance covers Phase 2 inputs. Phase-specific Kubernetes, Helm,
observability, and Continuous Integration pins remain provisional until their
gates pass.

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
identities. kind 0.32.0, Kubernetes/kubectl 1.36.1, Helm 4.2.0, and later
observability/CI inputs remain candidates until their respective phase gates.

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

## Consequences

Build and installation files become more verbose and updates require evidence.
In return, every result can name the exact software inputs and controlled
upgrades can be compared fairly.

## Reversal Or Migration

Rollback means restoring the previous manifest and exact artifact references,
then rerunning the affected acceptance tests. Do not remove unrelated package,
image, volume, or cluster state during rollback.
