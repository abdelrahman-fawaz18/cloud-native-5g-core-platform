# Container Definitions

This directory will contain reviewed Dockerfiles and build metadata. Each
image must record its upstream source, pinned base, build arguments, version,
digest, license considerations, exposed ports, runtime user, health behavior,
and required Linux capabilities.

Runtime secrets and host-specific configuration must not be built into image
layers.
