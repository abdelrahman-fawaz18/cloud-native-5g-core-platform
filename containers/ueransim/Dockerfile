# syntax=docker/dockerfile:1.18

FROM ubuntu:24.04@sha256:52df9b1ee71626e0088f7d400d5c6b5f7bb916f8f0c82b474289a4ece6cf3faf AS build

ARG DEBIAN_FRONTEND=noninteractive
ARG BUILD_JOBS=8

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        libsctp-dev \
        lksctp-tools \
    && rm -rf /var/lib/apt/lists/*

ADD --checksum=sha256:69c3162cd6f325b97b494f29a6510af14e039ce26193b7cdbc14df831a664ece \
    https://github.com/aligungr/UERANSIM/archive/ca1a66fffe282767bb08618af9f848e3b68ea47b.tar.gz \
    /tmp/ueransim.tar.gz

RUN mkdir -p /src/ueransim /out \
    && tar --extract --gzip --file=/tmp/ueransim.tar.gz \
        --directory=/src/ueransim --strip-components=1 \
    && cmake -S /src/ueransim -B /src/ueransim/build \
        -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /src/ueransim/build --parallel "$BUILD_JOBS" \
    && install -m 0755 /src/ueransim/build/nr-gnb /out/nr-gnb \
    && install -m 0755 /src/ueransim/build/nr-ue /out/nr-ue \
    && install -m 0755 /src/ueransim/build/nr-cli /out/nr-cli \
    && install -m 0755 /src/ueransim/build/libdevbnd.so /out/libdevbnd.so \
    && install -m 0755 /src/ueransim/tools/nr-binder /out/nr-binder

FROM ubuntu:24.04@sha256:52df9b1ee71626e0088f7d400d5c6b5f7bb916f8f0c82b474289a4ece6cf3faf

ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.title="Cloud-Native 5G Core UERANSIM" \
      org.opencontainers.image.description="UERANSIM gNodeB and UE runtime built from a pinned official source release" \
      org.opencontainers.image.source="https://github.com/aligungr/UERANSIM" \
      org.opencontainers.image.url="https://github.com/abdelrahman-fawaz18/cloud-native-5g-core-platform" \
      org.opencontainers.image.version="3.2.8" \
      org.opencontainers.image.revision="ca1a66fffe282767bb08618af9f848e3b68ea47b" \
      org.opencontainers.image.licenses="AGPL-3.0-only"

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        iproute2 \
        iputils-ping \
        libsctp1 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/ueransim/bin /opt/ueransim/logs

COPY --from=build /out/ /opt/ueransim/bin/
COPY --chmod=0755 containers/ueransim/entrypoint.sh /usr/local/bin/ueransim-entrypoint
COPY --chmod=0755 containers/ueransim/healthcheck.sh /usr/local/bin/ueransim-healthcheck
COPY --chmod=0444 containers/ueransim/rt_tables /opt/ueransim/share/rt_tables

ENV PATH="/opt/ueransim/bin:${PATH}"
WORKDIR /opt/ueransim

USER 65532:65532
ENTRYPOINT ["/usr/local/bin/ueransim-entrypoint"]
CMD ["gnb"]
