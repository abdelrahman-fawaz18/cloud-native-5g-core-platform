# ADR-0002: Container Image Source And Build Strategy

## Status

Accepted

Acceptance covers the Docker Compose reference baseline. Public image release scanning
and distribution controls remain pending.

## Context

Open5GS and UERANSIM require telecom-specific configuration and elevated
network behavior. Opaque third-party images could hide source, patches,
licenses, users, capabilities, and dependency versions. Reproducibility also
requires more than a movable image tag.

## Decision

- Build Open5GS and UERANSIM images from their official tagged source releases
  using reviewed multi-stage Dockerfiles.
- Start compatibility work with Open5GS 2.7.7 and UERANSIM 3.2.8.
- Pin build and runtime base images by version and release-baseline digest.
- Use the official MongoDB image from the 8.0 series only after selecting an
  exact patch and digest and validating it with Open5GS.
- Record source URL, commit/tag, checksums, image digest, build arguments,
  license, runtime user, exposed ports, health behavior, packages, and required
  capabilities in a version manifest.
- Prefer a non-root runtime user. Any exception must be component-specific and
  backed by a failing/passing test.
- Generate a Software Bill of Materials and scan each released image; findings
  require triage rather than a claim of zero vulnerabilities.

## Alternatives Considered

- **Unreviewed community images:** faster initially, but weak provenance and
  redistribution evidence.
- **Host package extraction:** closely resembles the predecessor lab but mixes
  host-distribution packaging assumptions into immutable images.
- **Build from a moving branch:** may include fixes but cannot reproduce a
  stable baseline.

## Evidence

- [Open5GS releases](https://github.com/open5gs/open5gs/releases) identify
  2.7.7 as the current tagged upstream release reviewed during Host baseline.
- [UERANSIM releases](https://github.com/aligungr/UERANSIM/releases) identify
  3.2.8 as the current tagged upstream release reviewed during Host baseline.
- Both projects use the GNU Affero General Public License; source and image
  distribution obligations must be reviewed before public release.
- The host package versions are evidence about the predecessor topology, not a
  valid image provenance record for this topology.
- Compose reference built Open5GS 2.7.7 and UERANSIM 3.2.8 from checksummed source
  archives on digest-pinned Ubuntu, used a digest-pinned MongoDB 8.0.28 image,
  and recorded the accepted local image IDs and sizes.
- The complete Compose health, registration, PDU-session, user-plane,
  persistence, recreation, and cleanup gates passed with these images.
- Runtime users, Linux capability exceptions, device mounts, host-port absence,
  and upstream licenses are recorded in `docs/image-provenance.md`.
- A Software Bill of Materials and vulnerability scan remain mandatory before
  any project-built image is published to a registry.

## Consequences

Builds take longer and the project owns dependency and license documentation.
In return, the runtime contents and privileges are inspectable, rebuildable,
and suitable for security and supply-chain checks.

## Reversal Or Migration

A reviewed upstream image may replace a local build only through a new ADR or
an update to this ADR that compares contents, provenance, license, digest,
capabilities, and functional tests. Existing image references remain pinned
until the replacement passes regression tests.
