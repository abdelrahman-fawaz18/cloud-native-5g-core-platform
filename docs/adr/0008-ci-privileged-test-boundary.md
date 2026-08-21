# ADR-0008: Continuous Integration And Privileged Test Boundary

## Status

Accepted

## Context

Most source-quality checks are deterministic and safe on hosted Continuous
Integration (CI) runners. Full 5G integration may require SCTP, GTP-U, TUN,
`NET_ADMIN`, nested containers, firewall changes, and substantial resources.
Giving untrusted pull-request code privileged access to a persistent personal
host would create an unacceptable security boundary.

## Decision

- Run documentation, link, shell, Python, YAML, Dockerfile, Helm, schema,
  policy, secret, dependency, image, and Software Bill of Materials checks on
  hosted CI where supported.
- Keep privileged end-to-end 5G networking tests out of ordinary hosted jobs
  unless the runner capability and isolation are explicitly proven.
- Provide one exact local integration command that produces machine-readable
  results and clearly reports skipped prerequisites.
- Do not register the everyday development host as an automatic privileged
  runner for untrusted contributions.
- Consider a dedicated, ephemeral, hardened self-hosted runner only in a later
  ADR after defining trust, cleanup, secrets, network exposure, and patching.
- Never label a privileged test as passed when it was skipped or simulated.

## Alternatives Considered

- **Run everything on hosted CI:** desirable coverage, but may lack TUN,
  protocol, nested-runtime, and privilege support.
- **Permanent self-hosted runner on this host:** capable, but exposes the
  working labs and host credentials/state to CI workloads.
- **No integration automation:** safest for the host, but weak repeatability
  and release evidence.

## Evidence

- The required local feasibility tests include TUN and elevated network
  capabilities that ordinary hosted checks do not guarantee.
- The host contains two unrelated technical environments that must not share a
  CI blast radius.
- `.github/workflows/ci.yml` now runs two hosted, unprivileged jobs with
  read-only repository permissions and immutable Action identities.
- `scripts/supply-chain-assurance.sh privileged-gate` runs the accepted platform and capability
  6 integration validators locally and records a restricted JSON result.
- The hosted workflow contains no deployment, secret consumption, or
  self-hosted runner registration.

## Consequences

Pull requests receive broad safe validation, while the most privileged evidence
remains an explicit local release gate. Release status must combine hosted CI
artifacts with a separately timestamped integration report.

## Reversal Or Migration

Move a test to hosted CI when an isolated runner demonstrably supplies its
requirements. Introduce a self-hosted runner only through a new accepted ADR
and remove its registration, credentials, service, and workspace by exact
target during rollback.
