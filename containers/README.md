# Container Definitions

This directory will contain reviewed Dockerfiles and build metadata. Each
image must record its upstream source, pinned base, build arguments, version,
digest, license considerations, exposed ports, runtime user, health behavior,
and required Linux capabilities.

Runtime secrets and host-specific configuration must not be built into image
layers.

## Phase 2 Images

- `open5gs/` builds the Open5GS Network Function runtime from the official
  `v2.7.7` source commit.
- `ueransim/` builds the simulated gNodeB and User Equipment runtime from the
  official `v3.2.8` source commit.
- `data-network/` provides the controlled HTTP endpoint used to validate the
  N6 user-plane path.

Remote source archives have SHA-256 checksums, base images use
architecture-specific immutable digests, and `.dockerignore` uses a
default-deny allowlist. See [image provenance](../docs/image-provenance.md) for
the source and license record.
