# Automation Scripts

This directory will contain idempotent helpers for environment inspection,
image builds, cluster creation, deployment, validation, experiments, status,
rollback, and scoped cleanup.

Scripts must fail clearly, avoid broad destructive actions, inspect exact
targets, and support a dry-run or read-only mode where practical.

## Current Scripts

- `capture-host-state.sh`: records a permission-restricted, ignored before/after
  host snapshot and refuses to overwrite evidence.
- `install-docker-engine.sh`: validates or installs the exact Phase 2 Docker
  package set from Docker's official Ubuntu repository.
- `install-kubernetes-tools.sh`: validates or checksum-verifies and installs
  only the pinned Phase 3 `kind` and `kubectl` binaries; it does not create a
  cluster, service, package repository, or kubeconfig.
- `install-helm.sh`: validates or checksum-verifies and installs only the
  pinned Phase 4 Helm binary; it does not access or create a cluster, alter a
  service, configure a package repository, or overwrite an unrecognized
  executable.
- `generate-subscriber-secret.sh`: renders random synthetic subscriber
  authentication material from public placeholder templates into an ignored
  mode-0700 directory containing only mode-0600 files. It validates consistency
  without printing subscriber identifiers or authentication values and refuses
  to overwrite existing material.
- `helm-lab.sh`: verifies accepted local images and the file-backed Secret,
  loads only those images into the named kind node, performs a server-side Helm
  dry run, installs the namespace-scoped release with readiness and Job waits,
  and reports scoped workload state. Cluster lifecycle remains delegated to
  the accepted `kind-feasibility.sh` ownership boundary.
- `kind-feasibility.sh`: performs collision and resource preflight, then
  creates, inspects, or deletes only the named `cn5g` kind feasibility cluster
  through a repository-local kubeconfig. Destructive cleanup requires an
  explicit confirmation argument and never invokes a Docker prune operation.
  It removes the residual `kind` bridge only after verifying that no cluster
  or attached container remains and that the exact driver, scope, labels, and
  IPv4/IPv6 address contract match the project-owned network.
- `kind-probes.sh`: builds, verifies, and loads the project-owned Phase 3
  protocol probe image; deploys and validates transport, TUN/capability, and
  synthetic routed-N6 probes; and performs exact per-probe cleanup without a
  registry, host port publication, or broad Docker cleanup.
- `compose-lab.sh`: controls only the named `cn5g-compose` project, including
  build preflight, rendering, build, startup, health wait, status, logs,
  validation, scoped cleanup, and verification that persistent volumes are
  retained by a non-destructive teardown. Its recreation test uses one
  synthetic MongoDB marker and removes the dedicated evidence collection after
  successful verification.
- `validate-compose.sh`: proves the synthetic subscriber record, NG Setup,
  registration, IPv4 PDU session, UPF tunnel, controlled HTTP path, ICMP path,
  N6 return route, and positive bidirectional packet-counter changes on the
  private UPF tunnel.

## Kubernetes Feasibility Lifecycle

The accepted Phase 3 gate is reproducible with the following scoped sequence:

```bash
sudo ./scripts/kind-feasibility.sh preflight
sudo ./scripts/kind-feasibility.sh create

sudo ./scripts/kind-probes.sh build-image
sudo ./scripts/kind-probes.sh load-image

sudo ./scripts/kind-probes.sh deploy-transport
sudo ./scripts/kind-probes.sh validate-transport
sudo ./scripts/kind-probes.sh cleanup-transport --confirm

sudo ./scripts/kind-probes.sh deploy-tun
sudo ./scripts/kind-probes.sh validate-tun
sudo ./scripts/kind-probes.sh cleanup-tun --confirm

sudo ./scripts/kind-probes.sh deploy-n6
sudo ./scripts/kind-probes.sh validate-n6
sudo ./scripts/kind-probes.sh cleanup-n6 --confirm

sudo ./scripts/kind-feasibility.sh delete --confirm
sudo ./scripts/kind-feasibility.sh verify-delete
```

The expected terminal gates are `transport_validation=pass`,
`tun_validation=pass`, `n6_validation=pass`, and
`scoped_cluster_cleanup=pass`. The N6 validation uses a synthetic
IP-over-UDP/2152 relay to test Kubernetes networking mechanics; it is not a
GTP-U protocol implementation.
