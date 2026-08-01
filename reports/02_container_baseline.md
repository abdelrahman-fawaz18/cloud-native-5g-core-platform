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

## Compose Baseline

The reviewed Compose and image definitions are present. Static rendering,
build, protocol validation, teardown/recreation, image digest recording, and
post-cleanup host comparison remain required before the Phase 2 exit gate can
pass.

