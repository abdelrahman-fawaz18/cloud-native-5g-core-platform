# Phase 2 Container Baseline Report

**Status:** In progress

## Runtime Installation And Coexistence

Docker Engine `29.7.1`, containerd `2.2.6`, Docker Buildx `0.36.0`, and Docker
Compose `5.3.1` were installed from Docker's official Ubuntu repository using
exact package versions. The interactive user was not added to the `docker`
group.

Integrity-checked snapshots were captured immediately before and after the
installation. The comparison found:

- the expected `docker0` bridge and `172.17.0.0/16` route;
- Docker-owned `iptables-nft` chains and masquerading for its bridge;
- preserved LXC firewall rules and `10.0.3.0/24` bridge;
- preserved host Open5GS `ogstun` and `10.45.0.0/16` routes;
- active host Open5GS, MongoDB, and LXC services;
- unchanged SCTP, GTP, TUN, IPv4 forwarding, cgroup v2, and AppArmor support;
- no containers, images, or user-created volumes immediately after install.

Raw snapshots remain permission-restricted under the ignored `artifacts/`
tree and are not publication artifacts.

## Existing Host Software Review

The host already runs Open5GS `2.8.0` and MongoDB `8.0.28`; its UERANSIM
source build is version `3.3.0`. These installations remain owned by the
predecessor lab and are not copied into the container images. The container
baseline instead uses official tagged Open5GS `2.7.7` and UERANSIM `3.2.8`
source commits plus an isolated MongoDB container and named volumes.

This intentional duplication prevents the new topology from changing the
host subscriber database or depending on host library state. Multi-stage
builds keep compilers and source trees out of final images, and Docker cache
reuses unchanged layers on repeat builds. Broad cache pruning remains
prohibited because the default builder cache may be shared by other projects.

## Compose Baseline

The reviewed Compose and image definitions are present. Static rendering,
build, protocol validation, teardown/recreation, image digest recording, and
post-cleanup host comparison remain required before the Phase 2 exit gate can
pass.
