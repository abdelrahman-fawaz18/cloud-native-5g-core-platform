# Phase 9 CI And Supply-Chain Security Results

## Scope

Phase 9 establishes deterministic hosted checks and an explicit local
privileged integration boundary. It does not claim production security,
artifact signing, multi-node availability, or automated deployment.

## Accepted Local Safe Gates

| Area | Accepted result |
| --- | --- |
| Tool integrity | 11 official downloads verified by SHA-256; 3 Actions pinned by full commit identity |
| Repository quality | Documentation, links, shell, Python, Dockerfiles, generators, and workflow passed |
| Kubernetes manifests | 2 Helm charts rendered deterministically; 70 resources passed Kubernetes 1.36 schema validation |
| Policy as code | 910 Conftest evaluations passed with exact 5G capability exceptions |
| Secret history | 40 Git commits scanned with no unresolved secret finding |
| Repository security | No unresolved fixed high/critical Trivy source finding |
| Negative controls | Unpinned Action, floating base, privileged Pod, and synthetic token all rejected |
| Image security | 5 local images passed fixed high/critical vulnerability and secret scanning |
| Component inventory | 5 SPDX 2.3 JSON SBOMs generated and structurally validated |
| Local image promotion | Scanned data-network rebuild deployed; Phase 5 and Phase 6 validation passed |
| Local privileged gate | Phase 5/6 integration passed; reviewed Phase 7/8 condition counts verified as 9 each |
| Host coexistence | Before/after snapshots retained the same cluster container and Docker networks with no new host service or structural firewall rule |

## Security Changes

- Trivy rejected the original Alpine 3.22.1 base because fixed high/critical
  OpenSSL, musl, and zlib findings were present. Both Alpine-based project
  images now use the official Linux/AMD64 Alpine 3.22.5 security-maintenance
  digest and must pass a clean rebuild and rescan before acceptance.
- The data-network boundary is now explicitly tested: Compose grants only
  `NET_ADMIN`, `SETUID`, and `SETGID` for one fixed return route before
  `su-exec` drops to UID/GID 65532; Kubernetes overrides the entrypoint and
  enforces UID/GID 65532 with all capabilities dropped.
- Prometheus `nodes/proxy` access is split from node discovery and narrowed to
  GET-only. Conftest permits that capability only for the exact Prometheus
  ClusterRole, preserving TLS-verified kubelet and cAdvisor collection through
  the Kubernetes API.
- The accepted data-network export is
  `sha256:7a5f7ab23fe5eefb12a6a2de097d01c4dbdc939be741561dc90e8e7b3c3d4bb8`
  (5,114,825 bytes). Its controlled rollout preserved five unique UE sessions,
  both DNN paths, cross-DNN isolation, node/container metrics, centralized
  logs, and six provisioned dashboards.
- Rendered workloads are evaluated against fail-closed Rego rules for
  privilege, host namespaces, host paths, service-account tokens, capabilities,
  image identity, and privilege escalation.
- Reports and SBOMs remain ignored and permission-restricted; public results
  contain reviewed summaries rather than raw findings.

## Accepted Hosted Evidence

GitHub Actions run `32419738287` evaluated implementation commit
`75e346c330edf35c9f8310ea291d267062f4d24b` on an Ubuntu 24.04 hosted runner.

| Hosted boundary | Accepted result |
| --- | --- |
| Safe deterministic gates | Passed in 50 seconds, including 190 tests, manifest schema and policy checks, secret history, repository scanning, and four negative controls |
| Image supply-chain gate | Passed in 7 minutes 48 seconds; five images were rebuilt, scanned, and inventoried without a registry push |
| Aggregate release gate | Passed only after both independent jobs succeeded |
| Repository artifacts | Gitleaks reported zero findings; Trivy reported zero unresolved fixed high/critical vulnerabilities and zero secrets |
| Image artifacts | Five Trivy reports contained zero unresolved fixed high/critical vulnerabilities and zero secrets |
| Inventory artifacts | Five structurally valid SPDX 2.3 SBOMs described 430 total packages |

The two retained artifact bundles were reviewed for structure and bounded
finding counts. Raw reports remain in the workflow's restricted artifact
storage rather than Git.

A skipped or unavailable gate is never recorded as passing.
