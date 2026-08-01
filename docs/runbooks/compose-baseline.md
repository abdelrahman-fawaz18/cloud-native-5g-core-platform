# Docker Compose Baseline Runbook

## Safety Model

Run commands from the repository root. This host intentionally requires
`sudo` for Docker daemon access because the interactive user is not a member
of the root-equivalent `docker` group.

The project name is fixed to `cn5g-compose`. The lifecycle helper refuses
unavailable/overlapping subnets before creation and never uses a global Docker
prune command.

## Static Configuration Check

```bash
sudo ./scripts/compose-lab.sh config
```

Expected result: exit status zero followed by four unique image references.
This action renders the model but creates no image, container, network, or
volume.

## Build

Run the read-only build preflight first:

```bash
sudo ./scripts/compose-lab.sh preflight-build
```

It requires the existing host Open5GS and MongoDB services to remain active,
refuses a concurrently running host UERANSIM or ns-3 command, requires at
least 12 GiB free, and refuses to replace a matching image tag unless its
project ownership label is correct.

```bash
sudo ./scripts/compose-lab.sh build
```

This downloads pinned base images and checksummed source archives, compiles
Open5GS and UERANSIM in multi-stage builds, and creates three local image tags.
An initial build can take several minutes and consume several gigabytes of
temporary layer/cache storage. A nonzero exit status means no deployment
should be started; retain and inspect the first failing build step.

Host Open5GS, UERANSIM, and MongoDB binaries are not copied into images. That
would couple the container to the existing lab's versions and libraries. The
multi-stage builds keep compilers and source trees out of the final images;
Docker reuses immutable layers and successful build cache on later builds.

Verify image ownership, identity, platform, runtime user, size, and the absence
of deployment resources:

```bash
sudo ./scripts/compose-lab.sh verify-images
```

Expected final line: `image_verification=pass`.

## Start And Wait

```bash
sudo ./scripts/compose-lab.sh up
```

The helper checks the three candidate ranges, creates only the named project
resources, starts dependencies in health order, and waits up to 240 seconds.
Success means all long-running services are healthy and the subscriber
initializer exited successfully.

## Validate

```bash
sudo ./scripts/compose-lab.sh validate
```

Expected final line:

```text
compose_validation=pass
```

The checks cover the synthetic subscriber, gNodeB NG Setup, UE registration,
IPv4 Protocol Data Unit session, UE tunnel address, HTTP and Internet Control
Message Protocol traffic through the UPF, the N6 return route, and the UPF
tunnel. Positive receive and transmit packet deltas on `ogstun` provide
sanitized bidirectional packet evidence without retaining a raw capture.

## Inspect

```bash
sudo ./scripts/compose-lab.sh status
sudo ./scripts/compose-lab.sh logs
```

`status` shows project container state. `logs` emits only the last 200 lines
per service to limit accidental collection. Raw logs remain local evidence and
must be sanitized before publication.

## Scoped Cleanup

Before a persistence/recreation test, create one synthetic marker in the
project's dedicated evidence collection:

```bash
sudo ./scripts/compose-lab.sh prepare-persistence
```

Preserve MongoDB volumes:

```bash
sudo ./scripts/compose-lab.sh down
sudo ./scripts/compose-lab.sh verify-down
```

The verification requires zero project containers, zero project networks, and
exactly the two named MongoDB volumes. It does not inspect or remove unrelated
Docker resources.

After `up` reaches healthy state again, prove that the marker survived and
remove the dedicated evidence collection:

```bash
sudo ./scripts/compose-lab.sh verify-persistence
sudo ./scripts/compose-lab.sh validate
```

Expected final lines are `persistence_verification=pass` and
`compose_validation=pass`.

Remove containers, networks, and only the two project volumes:

```bash
sudo ./scripts/compose-lab.sh destroy --confirm
```

After containers are removed, the three exact local image tags can be removed
without affecting unrelated images:

```bash
sudo ./scripts/compose-lab.sh remove-images --confirm
```
