# syntax=docker/dockerfile:1.18

FROM alpine:3.22.5@sha256:7c8cb692ae09657cbc4a3f3cbd0e8d5a2690ba38386aaaf252dbb060bf5eb2e6

LABEL org.opencontainers.image.title="Cloud-Native 5G Core Data Network Endpoint" \
      org.opencontainers.image.description="Controlled HTTP endpoint for the Compose N6 user-plane test" \
      org.opencontainers.image.source="https://github.com/abdelrahman-fawaz18/cloud-native-5g-core-platform" \
      org.opencontainers.image.url="https://github.com/abdelrahman-fawaz18/cloud-native-5g-core-platform" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.licenses="Apache-2.0"

# The base digest and accepted image ID preserve the Phase 9 security rebuild;
# Trivy scans the actual installed package set before local acceptance.
# hadolint ignore=DL3018
RUN apk add --no-cache busybox-extras=1.37.0-r20 iproute2 su-exec \
    && addgroup -g 65532 -S cn5g \
    && adduser -u 65532 -S -D -H -G cn5g cn5g \
    && mkdir -p /srv

COPY --chmod=0755 containers/data-network/entrypoint.sh /usr/local/bin/data-network-entrypoint
COPY --chmod=0444 containers/data-network/healthz /srv/healthz

# Compose grants only route setup and identity-drop capabilities; the
# entrypoint immediately execs the server as UID/GID 65532. Kubernetes
# overrides this entrypoint and enforces non-root directly.
# hadolint ignore=DL3002
USER 0:0
ENTRYPOINT ["/usr/local/bin/data-network-entrypoint"]

# The health expression requires a pipeline and therefore the shell form.
# hadolint ignore=DL3025
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=12 \
    CMD wget -q -O - http://127.0.0.1:8080/healthz | grep -q '^cn5g-data-network-ok$'
