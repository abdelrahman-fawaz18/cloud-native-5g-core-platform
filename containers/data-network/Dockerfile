# syntax=docker/dockerfile:1.18

FROM alpine:3.22.1@sha256:eafc1edb577d2e9b458664a15f23ea1c370214193226069eb22921169fc7e43f

LABEL org.opencontainers.image.title="Cloud-Native 5G Core Data Network Endpoint" \
      org.opencontainers.image.description="Controlled HTTP endpoint for the Compose N6 user-plane test" \
      org.opencontainers.image.source="https://github.com/abdelrahman-fawaz18/cloud-native-5g-core-platform" \
      org.opencontainers.image.url="https://github.com/abdelrahman-fawaz18/cloud-native-5g-core-platform" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN apk add --no-cache busybox-extras=1.37.0-r20 iproute2 su-exec \
    && addgroup -g 65532 -S cn5g \
    && adduser -u 65532 -S -D -H -G cn5g cn5g \
    && mkdir -p /srv

COPY --chmod=0755 containers/data-network/entrypoint.sh /usr/local/bin/data-network-entrypoint
COPY --chmod=0444 containers/data-network/healthz /srv/healthz

USER 0:0
ENTRYPOINT ["/usr/local/bin/data-network-entrypoint"]

HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=12 \
    CMD wget -q -O - http://127.0.0.1:8080/healthz | grep -q '^cn5g-data-network-ok$'
