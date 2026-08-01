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

```bash
sudo ./scripts/compose-lab.sh build
```

This downloads pinned base images and checksummed source archives, compiles
Open5GS and UERANSIM in multi-stage builds, and creates three local image tags.
An initial build can take several minutes and consume several gigabytes of
temporary layer/cache storage. A nonzero exit status means no deployment
should be started; retain and inspect the first failing build step.

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
tunnel.

## Inspect

```bash
sudo ./scripts/compose-lab.sh status
sudo ./scripts/compose-lab.sh logs
```

`status` shows project container state. `logs` emits only the last 200 lines
per service to limit accidental collection. Raw logs remain local evidence and
must be sanitized before publication.

## Scoped Cleanup

Preserve MongoDB volumes:

```bash
sudo ./scripts/compose-lab.sh down
```

Remove containers, networks, and only the two project volumes:

```bash
sudo ./scripts/compose-lab.sh destroy --confirm
```

After containers are removed, the three exact local image tags can be removed
without affecting unrelated images:

```bash
sudo ./scripts/compose-lab.sh remove-images --confirm
```

