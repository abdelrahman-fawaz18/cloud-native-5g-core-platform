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
- `generate-phase05-subscribers.py`: validates the tracked five-UE/two-DNN
  plan, creates one ignored mode-0600 local seed, and deterministically derives
  matching UERANSIM and Open5GS material without printing authentication
  values. Check mode verifies permissions, the exact file set, and byte-level
  reproducibility. Invalid identities or service selections fail before any
  output is created.
- `phase05-lab.sh`: owns the controlled Phase 4-to-Phase 5 transition. It
  performs a resource and rendering preflight, creates or hash-verifies the
  exact Phase 5 Secret, records Helm/PVC rollback identity, prevents duplicate
  ordinal-zero execution during controller-kind migration, reconciles two
  exact kind-node return routes, validates the five-UE topology, and restores
  the accepted Phase 4 revision without deleting persistent storage.
- `phase06-lab.sh`: owns the separate observability lifecycle. It verifies the
  Phase 5 baseline and resource budget, creates or hash-verifies a restricted
  Grafana Secret, applies the bounded UE probe overlay, installs Prometheus,
  Grafana, Loki, Alloy, and kube-state-metrics, validates live metrics/logs/
  dashboards/cardinality, tests three alert firing-resolution cycles, exposes
  Grafana only on loopback, records and verifies the explicit 30-minute
  Grafana stability gate, provides an identity-checked observability-only
  hardening rollback, and performs exact retained-data cleanup.
- `phase07-lab.sh`: owns the gated performance-experiment lifecycle. It
  validates the accepted Phase 5/6 baseline, builds and identity-records one
  exact project-owned iperf3 image, loads only that image into kind, applies
  zero-capability benchmark sidecars, rejects any traffic route that bypasses
  `uesimtun0`, preserves ignored raw failures, enforces host/restart abort
  thresholds, restores five UEs after every condition, and can roll back to
  the recorded pre-Phase-7 Helm revision without deleting persistent data.
  After the accepted pilot, its resumable matrix runner executes three
  repetitions at 1, 3, and 5 concurrent UEs with separate per-UE server ports
  and aligned Prometheus evidence.
- `validate-phase05.sh`: reports each ordinal, Pod, DNN, tunnel address,
  registration/session result, intended endpoint result, and cross-DNN denial.
  It also verifies five database records, unique addresses and F-SEIDs,
  per-UE counter deltas, PFCP peer/session-programming health, and effective
  capability boundaries.
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

The Phase 4 `validate` action remains fail-closed for general protocol,
workload, persistence, routing, and user-plane errors. If and only if the
validator reaches the specific stale UPF PFCP/GTP-U evidence gate, it performs
one ordered UPF/SMF/gNB/UE session-chain reconciliation and repeats the full
validator. This handles a long-running lab whose current UPF process no longer
contains complete session-establishment evidence without masking unrelated
failures.

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

## Phase 5 Multi-UE Lifecycle

The Phase 5 workflow begins only from a currently validated Phase 4 release:

```bash
./scripts/generate-phase05-subscribers.py --generate
sudo ./scripts/phase05-lab.sh preflight
sudo ./scripts/phase05-lab.sh prepare-secret
sudo ./scripts/phase05-lab.sh upgrade
sudo ./scripts/phase05-lab.sh validate
sudo ./scripts/phase05-lab.sh test-invalid-ue
sudo ./scripts/phase05-lab.sh test-reprovision
sudo ./scripts/phase05-lab.sh observe-resources
```

`upgrade` includes complete validation; the separate `validate` action is an
idempotent repeat gate. The generator's output and Kubernetes Secret are
ignored runtime material. The derivation seed is never inserted into the
Secret. `test-invalid-ue` launches one temporary, deliberately unprovisioned
identity and proves that its failed registration attempt leaves the five valid
subscribers, Pods, and data paths intact; the exact temporary Pod and Secret
are then removed. `test-reprovision` removes one exact Phase 5-managed record,
runs the idempotent batch Job, reconciles the session chain, and repeats the
complete validator. Session reconciliation first scales the UE StatefulSet to
zero, preventing live UERANSIM processes from retaining a lost-cell state
across gNB replacement, and then recreates all five UE Pods. The Job is
retained on failure so its diagnostics remain
available; rerunning the same action is the scoped recovery path. Its resource
limit matches the accepted subscriber initialization Job, and its waiter
reports terminal Kubernetes Job failures without waiting for the timeout.
`observe-resources` first requires the full five-UE validator, then records a
ten-second cgroup CPU average plus current/peak memory for every singleton
workload and every UE ordinal alongside its declared requests and limits.

Controlled rollback is:

```bash
sudo ./scripts/phase05-lab.sh rollback
sudo ./scripts/phase05-lab.sh remove-secret --confirm
```

Rollback targets the recorded Phase 4 revision, preserves and identity-checks
the MongoDB PVC, deletes only four records carrying the Phase 5 management
marker, and runs `helm-lab.sh validate`. The Phase 5 Secret is removed only by
the separate confirmed action after the release is no longer using it.
The rollback waiter derives the restored subscriber Job from the active Helm
manifest rather than assuming that its suffix equals the new rollback
revision. Post-apply rollback and already-complete subscriber cleanup are both
verified resumable states.

## Phase 6 Observability Lifecycle

The Phase 6 workflow begins only from a validated Phase 5 release:

```bash
sudo ./scripts/phase06-lab.sh preflight
sudo ./scripts/phase06-lab.sh prepare-secret
sudo ./scripts/phase06-lab.sh install
sudo ./scripts/phase06-lab.sh test-alerts
sudo ./scripts/phase06-lab.sh validate
```

`install` upgrades the core release only to add one bounded,
least-privileged user-plane metrics sidecar per UE. All backends, dashboards,
rules, and read-only collectors belong to the separate
`cn5g-observability` release and namespace. Prometheus and Loki each use a
retained 2 GiB PVC; Grafana is reconstructed from provisioned files and its
credential is an ignored pre-created Secret.

The original accepted runtime run completed installation, repeated validation,
and three alert firing/resolution cycles on 2026-08-05. It verified 13 required
healthy Prometheus targets, five UE targets, five AMF and PFCP sessions, five
successful user-plane probes, 20 bounded custom series, recent Loki data, two
Grafana data sources, and the original four operational dashboards.

The 2026-08-06 Stage A upgrade retained the active core overlay, upgraded only
the observability release to revision 3, and passed a 2,568-second interactive
Grafana gate with zero restart increase and a 473.2 MiB peak under the 768 MiB
limit.

After Phase 7 analysis, `generate-phase07-dashboard-metrics.py --check`
verifies that the tracked 556-series reviewed-results fixture exactly matches
the accepted summary. The observability chart serves it through a restricted
exporter and provisions the fifth **Performance And Capacity Experiments**
dashboard. `phase06-lab.sh validate` now requires that exporter target, the
exact reviewed campaign contract, its cardinality bound, and all five
dashboard titles. The extension was accepted as observability revision 6 after
the full validator, all three alert lifecycles, and a 2,101-second interactive
soak passed with zero Grafana restarts and a 407.2 MiB peak.

Use `sudo ./scripts/phase06-lab.sh grafana` for a temporary
`127.0.0.1:13000` port-forward. That command also records the exact Grafana Pod
identity, restart count, and start time for the interactive stability gate. Keep
the terminal open for at least 30 minutes while inspecting the five dashboards,
then stop the forward with `Ctrl+C` and run:

```bash
sudo ./scripts/phase06-lab.sh verify-grafana-soak
```

The verifier rejects a shorter observation, a replaced Pod, any restart
increase, memory use at or above 80% of the 768 MiB limit, and runtime plugin
installation/update activity. A pass consumes the temporary soak and rollback
checkpoints. If a future hardening attempt is unhealthy, the scoped recovery
is:

```bash
sudo ./scripts/phase06-lab.sh rollback-hardening --confirm
```

That action rolls back only the observability release to its recorded prior
revision, checks that the Prometheus and Loki PVC identities were preserved,
and revalidates the Phase 5 service. Normal uninstall restores the Phase 5 core
overlay and preserves Phase 6 PVCs/credential. A separate confirmed `destroy`
action removes only those verified retained objects after the release is
absent.

## Phase 7 Controlled Benchmark Experiment

Phase 7 begins from the accepted Phase 5/6 runtime. Run each command from the
repository root, in order, and stop if any command lacks its final `pass` line:

```bash
sudo ./scripts/phase07-lab.sh preflight
sudo ./scripts/phase07-lab.sh build-image
sudo ./scripts/phase07-lab.sh load-image
sudo ./scripts/phase07-lab.sh install
sudo ./scripts/phase07-lab.sh pilot
sudo ./scripts/phase07-lab.sh run-matrix
./scripts/phase07-lab.sh analyze
```

`build-image` changes only the named local `cn5g/benchmark:0.1.0` image.
`load-image` imports only that verified image into `cn5g-control-plane`.
`install` changes the `cn5g` Helm release by adding idle client/server
sidecars and five internal TCP/UDP ports (5201-5205); it publishes no host
port. `pilot`
temporarily scales the UE StatefulSet to one, runs bounded low-load tests
through the real UE tunnel, restores five replicas, and validates the accepted
service. `run-matrix` performs or resumes the three-repetition 1/3/5-UE
campaign. It keeps failed attempts, skips already accepted conditions, and
restores five UEs after every condition. Before every measurement it restarts
both DNN benchmark servers and then performs the dependency-ordered Phase 5
session repair so the UPF policy tables contain the current endpoint addresses.
The matrix leaves forward TCP unbounded but applies a declared 10 Mbit/s
per-UE offered rate to reverse TCP; the latter is a service-load check, not a
maximum downlink-capacity claim.
This reset prevents stale session or traffic-process state from contaminating
the next condition. Raw evidence is permission-restricted and ignored.
The unprivileged `analyze` action requires an exact `raw_complete` campaign,
validates all nine accepted attempts and their restart snapshots, and writes
deterministic reviewed CSV, JSON, SVG plots, and the Phase 7 report.

The scoped recovery is:

```bash
sudo ./scripts/phase07-lab.sh rollback --confirm
```

It restores the exact recorded Helm revision and MongoDB claim identity, then
runs the Phase 5 and Phase 6 validators. It does not delete benchmark images,
subscriber state, telemetry state, the kind cluster, or unrelated resources.
