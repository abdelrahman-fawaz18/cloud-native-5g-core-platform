# syntax=docker/dockerfile:1.18

FROM ubuntu:24.04@sha256:52df9b1ee71626e0088f7d400d5c6b5f7bb916f8f0c82b474289a4ece6cf3faf AS build

ARG DEBIAN_FRONTEND=noninteractive
ARG BUILD_JOBS=8

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        bison \
        build-essential \
        ca-certificates \
        cmake \
        flex \
        git \
        libbson-dev \
        libcurl4-gnutls-dev \
        libgcrypt20-dev \
        libgnutls28-dev \
        libidn-dev \
        libmicrohttpd-dev \
        libmongoc-dev \
        libnghttp2-dev \
        libsctp-dev \
        libssl-dev \
        libtalloc-dev \
        libtins-dev \
        libyaml-dev \
        meson \
        ninja-build \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

ADD --checksum=sha256:a1b47110982a00fa66b639e08ad124803c72fc8228c0f7fb886abbb059752c58 \
    https://github.com/open5gs/open5gs/archive/318eeb49a7dcdff733dec60e02d9c60aefca2fb9.tar.gz \
    /tmp/open5gs.tar.gz

RUN mkdir -p /src/open5gs /stage \
    && tar --extract --gzip --file=/tmp/open5gs.tar.gz \
        --directory=/src/open5gs --strip-components=1 \
    && meson setup /src/open5gs/build /src/open5gs \
        --buildtype=release --prefix=/opt/open5gs \
    && ninja -C /src/open5gs/build -j "$BUILD_JOBS" \
    && DESTDIR=/stage ninja -C /src/open5gs/build install

FROM ubuntu:24.04@sha256:52df9b1ee71626e0088f7d400d5c6b5f7bb916f8f0c82b474289a4ece6cf3faf

ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.title="Cloud-Native 5G Core Open5GS" \
      org.opencontainers.image.description="Open5GS network-function runtime built from a pinned official source release" \
      org.opencontainers.image.source="https://github.com/open5gs/open5gs" \
      org.opencontainers.image.url="https://github.com/abdelrahman-fawaz18/cloud-native-5g-core-platform" \
      org.opencontainers.image.version="2.7.7" \
      org.opencontainers.image.revision="318eeb49a7dcdff733dec60e02d9c60aefca2fb9" \
      org.opencontainers.image.licenses="AGPL-3.0-only"

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        iproute2 \
        libbson-1.0-0 \
        libcurl3t64-gnutls \
        libmicrohttpd12t64 \
        libmongoc-1.0-0 \
        libnghttp2-14 \
        libsctp1 \
        libssl3t64 \
        libtalloc2 \
        libtins4.5 \
        libyaml-0-2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /stage/opt/open5gs /opt/open5gs
COPY --chmod=0755 containers/open5gs/entrypoint.sh /usr/local/bin/open5gs-entrypoint
COPY --chmod=0755 containers/open5gs/healthcheck.sh /usr/local/bin/open5gs-healthcheck

RUN printf '%s\n' /opt/open5gs/lib/x86_64-linux-gnu > /etc/ld.so.conf.d/open5gs.conf \
    && ldconfig

ENV PATH="/opt/open5gs/bin:/opt/open5gs/sbin:${PATH}"

USER 65532:65532
ENTRYPOINT ["/usr/local/bin/open5gs-entrypoint"]
CMD ["nrf"]
