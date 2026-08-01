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
- `compose-lab.sh`: controls only the named `cn5g-compose` project, including
  rendering, build, startup, health wait, status, logs, validation, and scoped
  cleanup.
- `validate-compose.sh`: proves the synthetic subscriber record, NG Setup,
  registration, IPv4 PDU session, UPF tunnel, controlled HTTP path, ICMP path,
  and N6 return route.
