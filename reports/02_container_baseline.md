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

Image verification passed for Linux/AMD64. The final runtime sizes were
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
the final Phase 2 release identities.

On the recovery attempt, the subscriber initializer completed and the data
endpoint started, proving both permission corrections. The SMF then reached
Open5GS configuration parsing and reported that its mandatory `smf.dns` list
was absent. The configuration now includes the two IPv4 resolvers from the
pinned Open5GS v2.7.7 reference configuration. They are PDU-session parameters;
the Phase 2 N6 network remains intentionally isolated, so external DNS
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
