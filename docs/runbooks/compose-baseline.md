# Docker Compose Baseline Runbook

## Objective

This runbook builds, starts, validates, inspects, recreates, and removes the
Compose reference `cn5g-compose` integration environment. It operates only on resources
declared in `compose.yaml` and preserves the host-based Open5GS/UERANSIM lab.

The baseline contains 15 services: MongoDB, a one-shot subscriber initializer,
ten Open5GS control/user-plane functions, one UERANSIM gNodeB, one UERANSIM
User Equipment (UE), and one controlled data-network endpoint.

## Safety Contract

- Run every command from the repository root.
- Docker daemon access uses `sudo`; the interactive account is intentionally
  not a member of the root-equivalent `docker` group.
- The Compose project name is fixed to `cn5g-compose`.
- No Compose service publishes a host port or uses host networking.
- `up` rechecks all three address ranges against live host routes and Docker
  networks before creating resources.
- `down` removes only project containers and networks and preserves database
  volumes.
- `destroy --confirm` additionally removes exactly the two project MongoDB
  volumes.
- `remove-images --confirm` removes only the three exact project image tags and
  refuses to run while project containers exist.
- No lifecycle action runs a global image, network, volume, or builder prune.

Container creation changes host bridge and firewall state while the topology
is running. Final cleanup must therefore include both Docker resource
verification and a host-state comparison.

## Prerequisites

1. Docker Engine, containerd, Buildx, and Docker Compose match
   `versions/compose-runtime.env`.
2. `/dev/net/tun`, Stream Control Transmission Protocol (SCTP), and required
   kernel networking primitives passed the host preflight.
3. Existing host Open5GS and MongoDB services are active.
4. No host UERANSIM or ns-3 process is running during a project build.
5. At least 12 GiB is available on Docker's filesystem for the initial source
   build and cache.
6. The three candidate networks do not overlap a host route or existing Docker
   network:
   - core: `172.28.0.0/24`;
   - UE session pool: `10.60.0.0/24`;
   - controlled N6 network: `10.62.0.0/24`.

## Lifecycle Command Map

| Command | Changes state? | Intended result |
| --- | --- | --- |
| `preflight-build` | No | Proves host-lab health, simulator idleness, disk headroom, and image-tag ownership |
| `config` | No | Renders and validates the Compose model and lists referenced images |
| `build` | Yes: images/cache | Builds three project images from pinned inputs |
| `verify-images` | No | Records image identity/platform/user/size and requires zero deployment resources |
| `up` | Yes: containers/networks/volumes | Creates the lab and waits for meaningful health gates |
| `status` | No | Shows all project container states, including completed/failed one-shot services |
| `validate` | Sends controlled traffic | Proves subscriber, signalling, session, routing, HTTP, ICMP, and tunnel counters |
| `logs` | No | Emits the last 200 lines per project service |
| `prepare-persistence` | Yes: project database | Adds one deterministic synthetic evidence marker |
| `down` | Yes: scoped removal | Removes project containers and networks; retains named volumes |
| `verify-down` | No | Requires no project container/network and exactly two retained volumes |
| `verify-persistence` | Yes: project database | Proves the marker survived and drops its evidence collection |
| `destroy --confirm` | Yes: destructive, scoped | Removes project containers, networks, and two database volumes |
| `remove-images --confirm` | Yes: destructive, scoped | Removes the three exact local project image tags |

## 1. Render The Configuration

```bash
sudo ./scripts/compose-reference.sh config
```

This runs `docker compose config --quiet` before listing image references. It
resolves anchors, inheritance, dependency conditions, networks, mounts,
capabilities, devices, and health checks without creating a Docker resource.

Success: exit status zero and the service image references. Repeated references
resolve to four distinct identities—three local project images plus the
digest-pinned MongoDB image.

Failure means the declarative model is invalid. Do not build or start the lab;
inspect the first Compose error and correct the source YAML.

## 2. Run The Read-Only Build Preflight

```bash
sudo ./scripts/compose-reference.sh preflight-build
```

Expected markers:

```text
host_reference_services=active
host_ran_or_simulation_processes=none
project_image_tag_conflicts=none
host_software_reuse=disabled_for_isolation
build_preflight=pass
```

The host-process check compares Linux Process Identifier (PID) namespaces. A
UERANSIM process inside `cn5g-compose` is recognized as project-owned, while a
matching process in the host namespace or another container blocks the build.

Failure interpretation:

| Message | Meaning | Safe response |
| --- | --- | --- |
| Existing host service is inactive | The known-good host lab is not in its preflight state | Diagnose that host service; do not alter it merely to satisfy this project |
| Host `nr-gnb`, `nr-ue`, `ns3`, or `waf` is running | Another simulation could contend for resources or make evidence ambiguous | Stop only the exact process if it belongs to the operator's active work; otherwise wait |
| Less than 12 GiB available | Source compilation may exhaust Docker storage | Review exact filesystem usage; do not run a broad prune |
| Image tag is not project-owned | Building would overwrite a tag whose ownership is uncertain | Inspect the image labels and choose an explicit disposition; never delete by tag assumption |

## 3. Build Reproducible Images

```bash
sudo ./scripts/compose-reference.sh build
```

The build creates:

- `cn5g/open5gs:2.7.7` from a checksummed Open5GS source archive;
- `cn5g/ueransim:3.2.8` from a checksummed UERANSIM source archive; and
- `cn5g/data-network:0.1.0` from a digest-pinned Alpine base.

Open5GS and UERANSIM use multi-stage Dockerfiles. Build stages contain
compilers, headers, source, and build systems; runtime stages receive only the
installed runtime artifacts and required shared libraries. The host's existing
5G binaries and libraries are neither copied nor mounted into the images.

An initial build can take several minutes and consume several gigabytes of
cache. A repeat build should reuse unchanged layers. A nonzero exit status
means deployment must not begin; retain the first failing build step because
later parallel output may be a secondary cancellation.

### Scoped BuildKit Cache Recovery

If BuildKit reports a missing cached snapshot while finalizing only the named
Open5GS `runtime` stage, bypass that stage's cache without deleting shared
builder data:

```bash
sudo docker buildx build \
  --file containers/open5gs/Dockerfile \
  --platform linux/amd64 \
  --no-cache-filter runtime \
  --tag cn5g/open5gs:2.7.7 \
  --load \
  .
```

This recovery is appropriate only after the normal preflight passes and the
error identifies the runtime-stage snapshot. It preserves the expensive
compiled build stage. Do not substitute `docker builder prune` or
`docker system prune`.

## 4. Verify Image Outputs

Before deployment, with no project resources present:

```bash
sudo ./scripts/compose-reference.sh verify-images
```

For each project image, the helper records:

- Open Container Initiative (OCI) image identifier;
- unpacked size;
- `linux/amd64` platform;
- configured default user; and
- project ownership label.

It then requires zero `cn5g-compose` containers, networks, and volumes.
Expected final line:

```text
image_verification=pass
```

The output identity can change after an intentional image rebuild because
BuildKit includes provenance metadata. The pinned source commit, archive
checksum, base manifest, Dockerfile, configuration, and accepted validation
are the reproducibility contract; the tested export identity is recorded in
`versions/compose-runtime.env` and `docs/image-provenance.md`.

## 5. Start And Wait For Readiness

```bash
sudo ./scripts/compose-reference.sh up
```

The helper:

1. rejects overlapping subnets;
2. validates the Compose model;
3. creates two internal Docker networks and two MongoDB volumes;
4. starts dependencies in health order; and
5. waits up to 240 seconds for 14 long-running services to become healthy and
   the subscriber initializer to complete successfully.

Successful output reports all long-running containers as `Healthy` and
`subscriber-init` as `Exited` without an error. `Exited` is correct for that
one-shot service; a nonzero exit code is not.

If startup fails, do not repeatedly recreate the topology. Inspect state and
the first unhealthy dependency:

```bash
sudo ./scripts/compose-reference.sh status
sudo docker compose \
  --project-name cn5g-compose \
  --file compose.yaml \
  logs --no-color --tail 120 SERVICE
```

Replace `SERVICE` with the exact failing service name. A dependency failure
often means the downstream container was intentionally never started.

## 6. Validate The 5G Control And User Planes

```bash
sudo ./scripts/compose-reference.sh validate
```

The validator fails on the first broken contract. A complete pass includes:

| Output | What it proves |
| --- | --- |
| `subscriber_record=pass` | MongoDB contains exactly one managed synthetic subscriber |
| `ng_setup=pass` | The gNodeB established N2 and completed NG Setup with the Access and Mobility Management Function (AMF) |
| `registration=pass` | Authentication, security, and initial registration completed |
| `pdu_session=pass` | The Session Management Function (SMF) and UPF established an IPv4 Protocol Data Unit session |
| `ue_tunnel_address=10.60.0.x/24` | The UE received an address from the configured session pool |
| `http_user_plane=pass` | Application traffic reached the controlled endpoint through `uesimtun0` and the UPF |
| `icmp_user_plane=pass` | Bidirectional IP reachability works independently of HTTP |
| `n6_return_route=pass` | The endpoint returns UE-subnet traffic through UPF address `10.62.0.2` |
| `upf_tunnel=pass` | `ogstun` exists with the expected `10.60.0.1/24` gateway |
| positive receive/transmit deltas | Packets crossed `ogstun` in both directions during the controlled test |
| `compose_validation=pass` | Every preceding contract passed |

The UE address can change between clean deployments; any address inside
`10.60.0.0/24` is valid. HTTP uses `--interface uesimtun0`, and ICMP uses
`-I uesimtun0`, so ordinary Compose connectivity cannot produce a false pass.
The counter evidence avoids publishing a raw packet capture.

## 7. Inspect Runtime State

```bash
sudo ./scripts/compose-reference.sh status
sudo ./scripts/compose-reference.sh logs
```

`status` includes stopped and one-shot containers. `logs` limits output to the
last 200 lines per service. Raw output is local diagnostic evidence and must be
reviewed before any selected excerpt is published.

Useful focused inspections:

```bash
sudo docker compose \
  --project-name cn5g-compose \
  --file compose.yaml \
  exec -T ue ip -4 rule show

sudo docker compose \
  --project-name cn5g-compose \
  --file compose.yaml \
  exec -T ue ip -4 route show table rt_uesimtun0

sudo docker compose \
  --project-name cn5g-compose \
  --file compose.yaml \
  exec -T upf ip -4 address show dev ogstun
```

These commands read container state. The expected UE policy rule selects
`rt_uesimtun0` for the assigned `10.60.0.x` source, that table has a default
route through `uesimtun0`, and `ogstun` owns `10.60.0.1/24`.

## 8. Prove Persistence Across Recreation

Create one synthetic marker in a dedicated MongoDB evidence collection:

```bash
sudo ./scripts/compose-reference.sh prepare-persistence
```

Remove project containers and networks while retaining volumes:

```bash
sudo ./scripts/compose-reference.sh down
sudo ./scripts/compose-reference.sh verify-down
```

`verify-down` requires:

```text
project_containers=none
project_networks=none
preserved_volume=cn5g-compose_mongodb-config
preserved_volume=cn5g-compose_mongodb-data
scoped_down_verification=pass
```

Recreate and verify the retained database state:

```bash
sudo ./scripts/compose-reference.sh up
sudo ./scripts/compose-reference.sh verify-persistence
sudo ./scripts/compose-reference.sh validate
```

`verify-persistence` must find the pre-teardown marker, then drops the dedicated
evidence collection. Repeating the full validator proves that persistent state
and the recreated protocol topology are both operational.

## 9. Perform Complete Scoped Cleanup

The destructive action below deletes the two project MongoDB volumes and their
synthetic contents. It does not remove images or build cache:

```bash
sudo ./scripts/compose-reference.sh destroy --confirm
```

Expected removal scope is 15 containers, two networks, and these exact volumes:

- `cn5g-compose_mongodb-config`;
- `cn5g-compose_mongodb-data`.

Verify absence of all deployment resources while retaining verified images:

```bash
sudo ./scripts/compose-reference.sh verify-images
```

Expected final resource markers:

```text
project_containers=none
project_networks=none
project_volumes=none
image_verification=pass
```

Capture a post-cleanup host snapshot and compare it with the pre-deployment
snapshot. Interfaces, routes, policy rules, firewall structure, relevant host
services, and listening sockets must remain intact. Firewall timestamps and
packet counters are expected to advance.

## 10. Optional Exact Image Removal

Only after project containers are absent:

```bash
sudo ./scripts/compose-reference.sh remove-images --confirm
```

This removes only:

- `cn5g/open5gs:2.7.7`;
- `cn5g/ueransim:3.2.8`;
- `cn5g/data-network:0.1.0`.

The digest-pinned MongoDB image and BuildKit cache are not removed. Their
ownership may overlap other work and requires a separate reviewed decision.

## Diagnostic Matrix

| Symptom | Technical interpretation | Inspection focus |
| --- | --- | --- |
| Meson requests `git` | Open5GS wraps a pinned metrics subproject fetched during the build | Build-stage dependencies; runtime image is unaffected |
| Runtime linker reports a missing library | Multi-stage runtime dependency set is incomplete | Compare `ldd` requirements with runtime packages; rebuild the image |
| Open5GS reports a missing YAML field | The pinned release requires an explicit configuration value | Compare the local file with the same pinned upstream release, then validate the exact field |
| Data endpoint exits before health | Route setup or privilege drop failed, or the HTTP applet is absent | Endpoint entrypoint, capabilities, and pinned `busybox-extras` package |
| gNodeB has NG Setup logs but is unhealthy | Protocol evidence is not reaching the private health log | UERANSIM entrypoint `tee`, log `tmpfs`, and health-check pattern |
| UE registers but HTTP times out | Control plane succeeded but UE policy routing or N6 return routing is incomplete | `uesimtun0`, source rule, route table, `ogstun`, and endpoint route |
| UE reports missing `rt_tables` | UERANSIM cannot create its per-session policy-routing table | Private writable `/etc/iproute2` `tmpfs`, seeded file mode, and `NET_ADMIN` |
| SMF logs SBI parser errors during health probes | Probe sends an invalid application path rather than testing listener readiness | Use the local TCP-listener health check; do not probe arbitrary SBI URLs |
| Compose says a dependency failed | Downstream services were correctly gated after an upstream failure | Inspect the first failed/unhealthy dependency, not every waiting container |

## Acceptance Boundary

This runbook proves a local single-UE Compose reference. It does not establish
Kubernetes compatibility, multiple UE scale, multiple DNN/slice behavior,
external Internet access, performance, high availability, or production
security. Those properties require separate measured acceptance gates.
