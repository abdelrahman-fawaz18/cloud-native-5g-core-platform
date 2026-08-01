# Docker Engine Installation Runbook

## Purpose

Install the exact Docker Engine, command-line client, containerd runtime,
Buildx builder, and Docker Compose plugin selected for the Phase 2 container
baseline.

Docker Engine manages images, container processes, networks, mounts, and
volumes. containerd manages the lower-level container lifecycle. Buildx builds
images through BuildKit. Compose reads a declarative multi-container topology
and creates its services, networks, and volumes as one named project.

## Preconditions

- Phase 0/1 passed.
- `artifacts/host-state/before-docker-complete/` exists and its checksums pass.
- The host is Ubuntu 24.04 (`noble`) on x86-64/AMD64.
- No conflicting Docker, containerd, or `runc` package is installed.
- At least 15 GiB disk and 6 GiB available memory remain.
- The operator has reviewed the exact versions in
  `versions/phase-02.env`.

## Host Impact

The installation:

- adds Docker's official Advanced Package Tool (APT) repository key and source;
- installs five pinned packages and their required dependencies;
- creates and starts `docker.service` and `containerd.service`;
- normally enables those services at boot;
- creates state under `/var/lib/docker` and `/var/lib/containerd`;
- creates the Docker Unix socket;
- may create `docker0`, routes, and iptables/nftables-compatible chains; and
- consumes disk for images, build cache, writable layers, and volumes.

The installer does not add an account to the `docker` group. Membership in
that group grants root-equivalent control through the Docker daemon and
requires a separate decision.

## Procedure

Read-only validation:

```bash
./scripts/install-docker-engine.sh --check
```

Installation after explicit approval:

```bash
sudo ./scripts/install-docker-engine.sh --install
```

The script follows Docker's official Ubuntu repository method and uses exact
versions from the project manifest. It refuses to remove conflicting packages
or modify an existing mismatched Docker installation.

## Expected Result

- all five package versions match the manifest;
- Docker and containerd services are active;
- Docker is enabled at boot by its package installation;
- `docker version`, `docker compose version`, and `docker buildx version`
  succeed as root; and
- the script prints `install_result=pass`.

## Required Post-Installation Verification

Create `artifacts/host-state/after-docker-install/` with the host-state capture
script. Compare it with the pre-install snapshot and confirm:

- LXC's nftables tables and `10.0.3.0/24` network remain;
- the `ogstun` interface and `10.45.0.0/16` route remain;
- Open5GS and MongoDB services remain active;
- Docker owns only expected new services, interfaces, routes, and firewall
  chains;
- no project container, custom network, or volume exists yet; and
- disk and memory remain above the guardrails.

## Rollback Boundary

Routine project cleanup must not uninstall Docker or delete global Docker
state. If installation itself must be reversed, first capture the current
state and list exact packages, images, containers, networks, volumes, and data
directories. Package removal and deletion of `/var/lib/docker` or
`/var/lib/containerd` require a separate reviewed procedure because those
locations may later contain resources owned by other projects.

Never use `docker system prune`, `docker volume prune`, wildcard deletion, or
firewall reset as rollback.

## Authoritative Source

- [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
