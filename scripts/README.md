# Automation Scripts

This directory contains idempotent helpers for environment inspection, image
builds, cluster creation, deployment, validation, experiments, status,
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
- `helm-lab.sh`: owns the Phase 4 release lifecycle. It verifies accepted
  image identities and the file-backed Secret, loads only accepted images,
  performs server-side dry runs, installs and converges the namespace-scoped
  release, validates real 5G operation, samples cgroup resources, proves
  persistence, performs controlled upgrade and rollback, and uninstalls only
  identity-checked release resources while retaining the bound MongoDB claim.
  Interrupted upgrade, rollback, and uninstall operations use ignored,
  permission-restricted state files so a retry verifies the exact release and
  storage identities before resuming. Cluster lifecycle remains delegated to
  `kind-feasibility.sh`.
- `validate-kubernetes.sh`: independently validates the deployed Phase 4
  release. It proves Helm and workload readiness, subscriber state, stable SBI
  identities, N2 SCTP/NGAP, 5G-AKA, NAS security, registration, PDU session,
  N4 PFCP, N3 GTP-U, the exact N6 return route, HTTP/ICMP traffic, positive
  bidirectional UE/UPF tunnel-counter deltas, and effective capability masks.
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

## Helm-Managed Single-UE Lifecycle

Phase 4 uses one repository-local kubeconfig and one exact release/namespace
pair. The normal lifecycle is:

```bash
sudo ./scripts/helm-lab.sh preflight
sudo ./scripts/kind-feasibility.sh create
sudo ./scripts/helm-lab.sh load-images
sudo ./scripts/helm-lab.sh prepare-secret
sudo ./scripts/helm-lab.sh install
sudo ./scripts/helm-lab.sh validate
```

Synthetic subscriber files must already exist in the ignored Phase 4 secrets
directory. `prepare-secret` creates or verifies only the `cn5g` namespace and
`cn5g-subscriber` Secret; it never prints their values. `install` first checks
the Docker and kind-node runtime image identities, then performs a Helm
server-side dry run. API acceptance is followed by ordered workload waits,
nine-profile NRF convergence, deterministic UPF/SMF/gNB/UE session-chain
reconciliation, and the exact kind-node N6 return route.

Read-only status and measurement operations are:

```bash
sudo ./scripts/helm-lab.sh status
sudo ./scripts/helm-lab.sh observe-resources
```

`observe-resources` samples cgroup v2 CPU and memory inside each container for
ten seconds and prints the result beside declared requests and limits. It is a
single-UE steady-state observation, not a load test.

The accepted persistence and release-revision gates are:

```bash
sudo ./scripts/helm-lab.sh test-persistence
sudo ./scripts/helm-lab.sh upgrade
sudo ./scripts/helm-lab.sh rollback
sudo ./scripts/helm-lab.sh uninstall --confirm
sudo ./scripts/helm-lab.sh install
sudo ./scripts/helm-lab.sh verify-reinstall
sudo ./scripts/helm-lab.sh validate
```

`test-persistence` recreates only the MongoDB Pod and verifies a temporary
marker and unchanged claim identity. Upgrade and rollback preserve the bound
claim, wait for the exact revision-scoped subscriber Job, and run complete 5G
validation. Uninstall requires confirmation, records the claim UID and backing
volume, removes the exact owned N6 route and Helm release, removes only
completed historical Jobs with matching Helm labels and annotations, and
retains the namespace, Secret, and bound claim. `verify-reinstall` proves the
saved marker and identities before deleting only the temporary evidence
collection and lifecycle state.

The helper never uses a default kubeconfig, host-level route mutation,
wildcard deletion, `docker system prune`, privileged Pods, or deletion of a
bound PersistentVolumeClaim. Cluster deletion is a separate, explicitly
confirmed operation because the local-path volume does not survive deletion
of the kind node.
