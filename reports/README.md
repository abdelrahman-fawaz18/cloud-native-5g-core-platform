# Evidence Reports

These reports contain sanitized, reviewable engineering evidence. They state
what was tested, what passed, and where the claim stops. Raw terminal output,
scanner reports, credentials, kubeconfigs, host snapshots, and individual
experiment attempts remain local under ignored `artifacts/` or `benchmarks/raw/`
paths.

| Report | Question answered |
| --- | --- |
| [Host preflight](host-preflight.md) | Can the project coexist safely with the existing workstation services and networks? |
| [Container reference](compose-reference.md) | Do the pinned Open5GS/UERANSIM containers reproduce the protocol-correct baseline? |
| [Default platform validation](platform-validation.md) | Do five UEs obtain unique sessions across two isolated DNNs with real bidirectional traffic? |
| [Observability validation](observability-validation.md) | Are current service, resource, log, alert, and reviewed-result signals available and bounded? |
| [Performance results](performance-results.md) | How does the controlled user-plane path behave at 1, 3, and 5 concurrent UEs? |
| [Resilience results](resilience-results.md) | How quickly are AMF, SMF, and UPF faults detected, replaced, and restored to service? |
| [Supply-chain assurance](supply-chain-assurance.md) | Are sources, images, policies, secrets, and hosted checks controlled and reviewable? |
| [Release qualification](release-qualification.md) | Can the platform be installed on a fresh cluster and removed without collateral impact? |

The [release evidence contract](../release/release-evidence.json) links every
public claim to one or more of these methods and includes an explicit scope
limit.
