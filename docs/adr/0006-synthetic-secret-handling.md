# ADR-0006: Synthetic Secret Handling

## Status

Proposed

## Context

The platform uses synthetic subscriber keys, database credentials, dashboard
credentials, and possibly certificates or tokens. Synthetic values are safe
for lab semantics but still require a disciplined workflow so live Kubernetes
Secrets, command history, logs, and Git history do not become unsafe examples.
Base64 encoding does not encrypt a Kubernetes Secret.

## Decision

- Commit schemas, templates, and deterministic non-secret identity rules, not
  generated credential files or live Secret manifests.
- Generate live synthetic secret values locally into ignored files with owner
  read/write permissions only.
- Create or update Kubernetes Secret objects from file input without printing
  values or placing them directly on command lines.
- Reference existing Secret names from Helm values; do not pass secret material
  through ordinary Helm value files.
- Redact secret fields from status, logs, test output, screenshots, captures,
  and Continuous Integration artifacts.
- Run secret scans before commits and releases.
- Use only clearly synthetic Public Land Mobile Network, subscriber, network,
  username, password, certificate, token, and endpoint values.
- Delete local generated values only by their exact ignored project path after
  inspecting the target; rotate/recreate them for a clean deployment.

## Alternatives Considered

- **Commit fixed synthetic keys:** reproducible, but teaches unsafe handling and
  may leak into reused configurations.
- **Pass secrets as command-line arguments:** convenient, but exposes values to
  history and potentially process listings.
- **External cloud secret manager:** stronger centralized controls, but outside
  the local minimum-release scope.
- **Sealed Secrets/SOPS immediately:** viable future options, but introduce key
  management before the local threat model and workflow are proven.

## Evidence

- Kubernetes documentation states that Secret data is base64 encoded and
  requires additional controls for confidentiality.
- Project publication rules prohibit live secrets, kubeconfigs, keys, and
  credentials in Git or evidence.
- No live project secret exists yet.

## Consequences

Deployments require an explicit local generation step and tests must verify
missing/invalid secret behavior. The repository remains reproducible through
generation rules without preserving deployed credentials.

## Reversal Or Migration

An encrypted Git workflow or external manager may replace ignored local files
after an updated threat model, key-recovery procedure, CI integration, and
rotation test. Revoke or rotate any value that is accidentally exposed before
history cleanup or publication.
