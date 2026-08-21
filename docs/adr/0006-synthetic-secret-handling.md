# ADR-0006: Synthetic Secret Handling

## Status

Accepted on 2026-08-05

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
- single-UE profile created a pre-existing subscriber Secret from ignored local files,
  verified its content hash and project ownership without printing values,
  and retained it independently of the Helm release.
- platform committed only a synthetic non-secret identity/DNN plan. A local
  mode-`0600` seed derives five K and OPc values with HMAC-SHA256 into ignored
  files; repeated generation is byte-identical and rejects tampered or
  unexpected output.
- The five-UE StatefulSet mounts only its selected runtime configuration after
  an init-container copy. Validation derives identity and DNN evidence from
  that runtime configuration rather than reading or printing Secret data.
- Static tests, ignored-path checks, publication scans, an invalid-UE runtime
  test, and an idempotent partial-reprovision test passed without committing
  subscriber authentication material.

## Consequences

Deployments require an explicit local generation step and tests must verify
missing/invalid secret behavior. The repository remains reproducible through
generation rules without preserving deployed credentials.

## Reversal Or Migration

An encrypted Git workflow or external manager may replace ignored local files
after an updated threat model, key-recovery procedure, CI integration, and
rotation test. Revoke or rotate any value that is accidentally exposed before
history cleanup or publication.
