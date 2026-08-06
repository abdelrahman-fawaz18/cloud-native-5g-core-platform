# syntax=docker/dockerfile:1.18

FROM alpine:3.22.1@sha256:eafc1edb577d2e9b458664a15f23ea1c370214193226069eb22921169fc7e43f

LABEL org.opencontainers.image.title="CN5G Controlled Benchmark Tool" \
      org.opencontainers.image.description="Pinned iperf3 and network diagnostics for Phase 7 experiments" \
      org.opencontainers.image.source="https://github.com/abdelrahman-fawaz18/cloud-native-5g-core-platform" \
      org.opencontainers.image.url="https://github.com/abdelrahman-fawaz18/cloud-native-5g-core-platform" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.licenses="Apache-2.0" \
      cn5g.io/phase="07" \
      cn5g.io/iperf3-version="3.19.1-r0"

RUN apk add --no-cache \
      iperf3=3.19.1-r0 \
      iproute2=6.15.0-r0 \
      iputils=20240905-r0 \
    && addgroup -g 65532 -S cn5g \
    && adduser -u 65532 -S -D -H -G cn5g cn5g

USER 65532:65532
ENTRYPOINT ["iperf3"]
