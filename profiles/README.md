# Deployment Profiles

Profiles are small Helm values files selected by
[`scripts/cn5g-platform.sh`](../scripts/cn5g-platform.sh). They describe
supported operating configurations of one platform; they are not separate
implementations.

| File | Service contract |
| --- | --- |
| `default.yaml` | five UEs, two DNNs, bounded UE telemetry; deploys the separate observability release |
| `core-only.yaml` | the same five-UE/two-DNN 5G service without observability |
| `resource-limited.yaml` | the same 5G service with a lower MongoDB reservation and no observability |
| `single-ue.yaml` | one UE and one DNN for minimal compatibility diagnosis |
| `performance.yaml` | temporary benchmark sidecars over the default core topology |

The chart's own defaults match `default.yaml`. Profiles only express
intentional differences, so they remain short and reviewable.

An existing cluster is bound to its active profile. The unified lifecycle
rejects an in-place profile switch; use its confirmed scoped destroy and then
deploy the newly selected profile.
