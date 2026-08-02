# syntax=docker/dockerfile:1.18

ARG UERANSIM_BASE_IMAGE=cn5g/ueransim:3.2.8@sha256:60de10ecd55a9b96d4863319bd102d776622fcc3211f7f1b1c1a4d8026bc7f58

FROM ubuntu:24.04@sha256:52df9b1ee71626e0088f7d400d5c6b5f7bb916f8f0c82b474289a4ece6cf3faf AS build

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY containers/feasibility-probe/probe.c /src/probe.c

RUN mkdir -p /out \
    && cc -std=c11 -O2 -Wall -Wextra -Werror \
        -o /out/cn5g-feasibility-probe /src/probe.c \
    && strip /out/cn5g-feasibility-probe

FROM ${UERANSIM_BASE_IMAGE}

LABEL org.opencontainers.image.title="Cloud-Native 5G Core Feasibility Probe" \
      org.opencontainers.image.description="Protocol, TUN, routing, and packet-observation probe for the Kubernetes feasibility gate" \
      org.opencontainers.image.source="https://github.com/abdelrahman-fawaz18/cloud-native-5g-core-platform" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.licenses="NOASSERTION"

COPY --from=build --chmod=0755 \
    /out/cn5g-feasibility-probe /usr/local/bin/cn5g-feasibility-probe

USER 65532:65532
ENTRYPOINT ["/usr/local/bin/cn5g-feasibility-probe"]
CMD ["help"]
