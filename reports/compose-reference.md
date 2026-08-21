# Docker Compose Protocol Baseline

**Status:** Complete — exit gate passed on 2026-08-01

## Executive Summary

The Compose reference converted the validated host-based 5G protocol lab into an isolated,
reproducible Docker Compose reference. Open5GS and UERANSIM are built from
pinned, checksummed source; MongoDB and base images are selected by immutable
Linux/AMD64 manifests; configuration, health, lifecycle, persistence, and
cleanup are declared as code.

The final 15-service topology completed NG Setup, synthetic subscriber
authentication and registration, one IPv4 Protocol Data Unit session, and
bidirectional HTTP/Internet Control Message Protocol traffic through the User
Plane Function. Container/network recreation preserved MongoDB data and
required no image rebuild or manual repair. Final scoped destruction removed
all project containers, networks, and volumes. Before/after host evidence found
no residual project network state and no disruption to the existing Open5GS,
MongoDB, or LXC environment.

The [architecture document](../docs/architecture/compose-reference.md)
explains the component model, interfaces, signalling sequence, packet path,
security boundaries, and Networking qualification dependency. The [Compose
runbook](../docs/runbooks/compose-baseline.md) provides the reproducible
operating and diagnostic procedure.

## Acceptance Matrix

| Gate | Evidence | Result |
| --- | --- | --- |
| Reproducible images | Pinned commits, source checksums, base manifests, runtime dependencies, OCI labels, and recorded output IDs | Pass |
| Meaningful health | 14 long-running services healthy; one-shot subscriber initializer exited successfully | Pass |
| Registration | gNodeB NG Setup and UE initial registration success preserved in container evidence | Pass |
| IPv4 session | UE received `10.60.0.x/24` for DNN `internet`; UPF gateway `10.60.0.1/24` present | Pass |
| User-plane path | Bound HTTP and ICMP traffic reached `10.62.0.10` through the UPF and returned | Pass |
| Packet evidence | `ogstun` receive and transmit counters each increased by eight during validation | Pass |
| Persistence and recreation | Synthetic MongoDB marker survived `down`/`up`; evidence collection removed; full validation repeated | Pass |
| Scoped cleanup | 15 containers, two networks, and two named volumes removed; resource verification passed | Pass |
| Host coexistence | Network snapshot identical; firewall structure unchanged; host services preserved | Pass |

## Runtime Installation And Coexistence

Docker Engine `29.7.1`, containerd `2.2.6`, Docker Buildx `0.36.0`, and Docker
Compose `5.3.1` were installed from Docker's official Ubuntu repository using
exact package versions. The interactive account was not added to the `docker`
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

The reviewed Compose and image definitions passed static rendering, image
build, protocol validation, teardown/recreation, final image identity
recording, and post-cleanup host comparison.

### Implementation Incident Chronology

The following paragraphs retain each failure and its bounded correction in
the order observed. Statements that a retry was pending describe that point in
the chronology; all listed corrections are included in the final passing
baseline documented below.

The first Open5GS build attempt stopped safely during Meson configuration
because the build stage lacked `git`, which Meson requires to retrieve the
pinned `prometheus-client-c` subproject. No deployment resources were created.
The missing build-only dependency was added before retrying.

The retry preflight then correctly refused to overwrite an existing local
endpoint tag, but review showed that the image was the project-owned endpoint
completed by the first parallel build. Its project URL was stored in the OCI
`source` label while the guard initially checked only the OCI `url` label. The
guard now accepts either matching ownership label, and future endpoint builds
write both labels.

The subsequent build completed all three project images. Review of the build
output found that Compose exported shared image definitions once per consuming
service. Compilation layers were cached, but the exports were redundant. Each
build definition was therefore moved to one canonical service before future
builds and clean reproductions.

Image verification passed for Linux/AMD64. The initial successful build sizes were
47,958,802 bytes for Open5GS, 40,488,183 bytes for UERANSIM, and 5,063,524
bytes for the controlled endpoint. At verification time there were three
images and zero containers, Compose networks, or Compose volumes.

Docker reported 3.121 GB of build cache, including 2.37 GB currently marked
reclaimable. It was retained because the default builder cache is not safely
owned by one Compose project and broad pruning is prohibited.

Before first deployment, the Open5GS SBI health probe was aligned with its
cleartext HTTP/2 server. MongoDB received only the capabilities required by
its official entrypoint to prepare named volumes and drop privileges. The
subscriber initializer masks image-declared database paths with temporary
filesystems to prevent unintended anonymous volumes.

After rebuilding the corrected health probe, final pre-deployment verification
passed with image IDs `sha256:4abce03b...` (Open5GS),
`sha256:c3eb37af...` (UERANSIM), and `sha256:9a14ca52...` (endpoint). BuildKit
re-exported all three OCI indexes with provenance metadata; unchanged runtime
sizes for UERANSIM and the endpoint confirm that their runtime content did not
grow. The Open5GS image grew by 23 bytes for the health-probe option.

The first Compose startup stopped at its dependency gates without starting the
gNodeB or UE. Runtime logs identified three bounded image/configuration defects:
the SMF runtime lacked `libidn.so.12`, the controlled data endpoint could not
use `su-exec` to drop its group identity after installing its private route,
and the one-shot subscriber client inherited the MongoDB server entrypoint's
privilege-drop logic despite having no capabilities. The corrective baseline
adds the `libidn12` runtime package, grants the endpoint only `SETGID` and
`SETUID` in addition to `NET_ADMIN`, and starts `mongosh` directly as numeric
user/group `999`. Functional recovery and new image identity verification are
pending; the pre-deployment Open5GS and endpoint IDs above are therefore not
the final Compose reference release identities.

On the recovery attempt, the subscriber initializer completed and the data
endpoint started, proving both permission corrections. The SMF then reached
Open5GS configuration parsing and reported that its mandatory `smf.dns` list
was absent. The configuration now includes the two IPv4 resolvers from the
pinned Open5GS v2.7.7 reference configuration. They are PDU-session parameters;
the Compose reference N6 network remains intentionally isolated, so external DNS
reachability is not claimed by this baseline. SMF recovery remains pending.

The next recovery brought the SMF to healthy state and advanced the dependency
chain to the AMF. The AMF rejected the otherwise valid configuration because
the mandatory periodic registration timer `T3512` was absent. The pinned
Open5GS v2.7.7 reference value of 540 seconds is now explicit. AMF and radio
access recovery remain pending.

With AMF healthy, the data endpoint's retained process then exposed a separate
command-path defect: Alpine provides the HTTP server as a BusyBox applet, but
the entrypoint requested a standalone `httpd` executable. The entrypoint now
invokes `/bin/busybox httpd` explicitly after installing the private route and
dropping to numeric user/group `65532`. Endpoint rebuild and recovery remain
pending.

The targeted rebuild preflight then stopped because its original host-process
guard could see the project's running `nr-gnb` process from the host PID view.
The guard now compares PID namespaces: processes inside running
`cn5g-compose` containers are recognized as project-owned, while matching
processes in the host namespace or an unrelated container still block the
build. The false-positive preflight made no runtime change; validation of the
corrected guard remains pending.

The corrected guard passed with the project gNodeB running, and the endpoint
was rebuilt in isolation. Runtime then confirmed that Alpine's base BusyBox
binary does not contain the `httpd` applet. The endpoint now installs pinned
`busybox-extras` `1.37.0-r20` and invokes its explicit binary. Separately, the
gNodeB log proved SCTP association and successful NG Setup, but the health
probe could not see evidence emitted only to container output. The UERANSIM
entrypoint now duplicates output to both Docker logs and its private temporary
log filesystem without replacing the simulator as the signal-receiving
process. Targeted endpoint and UERANSIM rebuilds remain pending.

After all containers became healthy, functional validation proved the
subscriber, NG Setup, registration, PDU session, and UE address, but HTTP user
traffic timed out. Read-only inspection proved the endpoint and direct UPF-to-N6
path, while the UE had no route beyond its assigned subnet. Pinned UERANSIM
source and runtime logs showed that automatic routing stopped because
`/etc/iproute2/rt_tables` was absent. The UE now receives a private writable
`/etc/iproute2` temporary filesystem seeded from the image; its health gate
requires UERANSIM's connection-success message, source policy rule, and default
route. Live logs also showed the HTTP-based SBI health requests causing repeated
SMF URI parser errors, so SBI probes now verify the local TCP listener without
sending application requests. Rebuild and end-to-end recovery remain pending.

The first targeted rebuild of these corrections stopped before export because
the default-deny Docker context did not yet allow the new routing-table seed.
Only `containers/ueransim/rt_tables` is now added to the reviewed allowlist;
documentation, local-only artifacts, and Git metadata remain excluded. The
failed build changed no image tag or running container.

A second parallel build and a sequential retry then encountered the same
BuildKit finalization error for one missing cached Open5GS runtime snapshot.
No image was exported. The final Dockerfile stage is now explicitly named
`runtime`, allowing only that stage to bypass cache through Buildx's
`--no-cache-filter` option while preserving the expensive compiled `build`
stage and avoiding any shared-cache prune. Scoped cache recovery remains
pending.

The stage-scoped Open5GS recovery and separate UERANSIM build then succeeded.
The first UE recovery exited before UERANSIM because capability-restricted root
could not read the seed through the newly created `/opt/ueransim/share`
directory. The immutable seed now resides directly in the already traversable
`/opt/ueransim` runtime directory; the writable destination remains the
container-private `/etc/iproute2` temporary filesystem. Rebuild and recovery
remain pending.

The stricter UE gate then remained unhealthy. Inspection showed that the seed
was present and readable, but retained immutable mode `0444`; UERANSIM failed
when reopening it to append the `rt_uesimtun0` mapping. The entrypoint now keeps
the image copy immutable while setting only the container-private temporary
copy to owner-writable mode `0644`. Rebuild and recovery remain pending.

## Key Engineering Findings

| Area | Finding | Resulting design rule |
| --- | --- | --- |
| Supply chain | A source build can require fetch tools even when the runtime does not | Declare complete build-stage dependencies; keep them out of runtime stages |
| Runtime linking | A successful compile does not prove the final image contains every shared library | Exercise each Network Function from the runtime image and pin its library package set |
| Configuration schema | Required Open5GS fields vary by pinned release | Validate against configuration from the exact source revision, not a different installed version |
| Health design | Process existence and generic HTTP probes can both produce false conclusions | Use component-specific listeners, interfaces, ports, protocol-success logs, routes, and rules |
| Dependency gating | Compose correctly prevents downstream startup after an upstream failure | Diagnose the first failed dependency rather than treating every waiting service as an independent fault |
| User-plane routing | Registration and PDU-session success do not prove payload reachability | Validate UE policy routing, N3/N4 state, UPF TUN state, N6 forwarding, and the endpoint return route separately |
| Least privilege | TUN and route creation require elevation, but the entire topology does not | Drop all capabilities first, then add only reviewed per-service exceptions and avoid privileged mode |
| Persistence | Re-running an idempotent initializer cannot alone prove stored data survived | Use a separate synthetic marker across container/network recreation and remove it after verification |
| Host safety | Docker bridge/firewall changes are expected while a topology runs | Capture before/after state and distinguish rule-structure changes from normal counter changes |
| Cache recovery | Shared BuildKit cache cannot be assumed to belong to one project | Recover a named stage with `--no-cache-filter`; never use a broad prune as routine repair |

## Final Functional Evidence

The corrected topology reached all 15 Compose dependency gates: 14
long-running services were healthy and the one-shot subscriber initializer
exited successfully. The validation helper then proved:

- exactly one managed synthetic subscriber;
- successful gNodeB Next Generation Application Protocol setup over Stream
  Control Transmission Protocol;
- successful UE registration;
- an IPv4 Protocol Data Unit session in `10.60.0.0/24` for Data Network Name
  `internet`;
- successful HTTP and Internet Control Message Protocol traffic from the UE
  through the gNodeB, General Packet Radio Service (GPRS) Tunnelling Protocol
  User Plane (GTP-U) path, UPF, and N6 return route to the controlled endpoint;
  and
- positive `ogstun` receive and transmit deltas of eight packets each during
  the controlled traffic test.

The counter deltas are concise bidirectional packet evidence. No raw packet
capture, subscriber secret, or unsanitized log was retained for publication.
Container log evidence was reviewed for successful NG Setup, registration,
PDU-session establishment, Packet Forwarding Control Protocol association,
and GTP-U session creation.

## Recreation And Cleanup Evidence

Before teardown, a dedicated collection received one synthetic persistence
marker. `compose down` removed all 15 project containers and both project
networks while retaining exactly the two named MongoDB volumes. A subsequent
`compose up` recreated the topology without an image rebuild or manual repair.
The marker survived, its dedicated evidence collection was removed, and the
complete protocol and traffic validation passed again with eight receive and
eight transmit packets on `ogstun`.

The confirmed destructive cleanup then removed exactly 15 project containers,
two networks, and two MongoDB volumes. Final verification found zero
`cn5g-compose` containers, networks, or volumes. It intentionally retained the
three project images, the pinned MongoDB image, and shared BuildKit cache; no
prune command was used.

Final verified local images were:

| Image | Local image ID | Unpacked image size |
| --- | --- | ---: |
| `cn5g/open5gs:2.7.7` | `sha256:56b1a5aec5f3736c819b5f2edbbb1c61357740136c09c7d253dcca03f0da6cc8` | 48,037,139 bytes |
| `cn5g/ueransim:3.2.8` | `sha256:60de10ecd55a9b96d4863319bd102d776622fcc3211f7f1b1c1a4d8026bc7f58` | 40,489,225 bytes |
| `cn5g/data-network:0.1.0` | `sha256:c4770c4c6934e6b4f207a00304131f805b9c214ac8c9b8c365306bb58cce2b18` | 5,649,954 bytes |

## Post-Cleanup Host Comparison

Checksums passed for both ignored host snapshots. Comparing
`before-compose-up-final` with `after-compose-cleanup` found:

- identical interfaces, bridges, routes, and policy rules;
- identical firewall rule structure, with only expected timestamps and packet
  counters changed;
- zero containers and user-created volumes, and no residual project network;
- preserved active host Open5GS, MongoDB, and LXC services and relevant
  listening sockets;
- one additional retained image: the pinned MongoDB image used by Compose; and
- approximately 1.36 GB more filesystem use from intentionally retained image
  layers and build cache.

The shared builder reported 3.274 GB of cache, of which 2.375 GB was marked
reclaimable. It remains retained because project ownership cannot be proven
for every cache record and broad pruning is prohibited.

## Exit Gate

The Compose reference passes. The Compose deployment is healthy and reproducible, the
Single-UE control and user planes work, persistence survives recreation,
scoped destruction is verified, and no unrelated host network or service was
damaged. This report records the Compose reference exit state; the current platform
is tracked in [`docs/project-status.md`](../docs/project-status.md).
