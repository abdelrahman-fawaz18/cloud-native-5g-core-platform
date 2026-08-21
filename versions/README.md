# Version And Provenance Manifests

This directory records exact tool, source, package, image, chart, and action
inputs used by verified project baselines.

Each manifest must identify:

- the component and exact version;
- the authoritative source;
- a checksum or immutable digest when the artifact format supports one;
- the date on which availability was verified;
- relevant license or provenance notes; and
- the capability whose tests accepted the version.

A value in a version manifest is a candidate until the relevant runtime and
cleanup exit gate passes. Floating `latest` tags are not release inputs.

Current manifests:

- `compose-reference.env`: accepted container-runtime and Compose baseline inputs and
  verified local image identities.
- `networking.env`: accepted kind, Kubernetes, kubectl, node-image, ownership,
  cluster-network, probe-image, and cleanup inputs for the Kubernetes
  feasibility baseline.
- `single-ue.env`: accepted Helm artifact identity and project-owned release,
  namespace, chart-version, and N6 route contract for the single-UE platform.
- `observability.env`: accepted Prometheus, Grafana, Loki, Alloy,
  kube-state-metrics, and UE probe runtime versions plus immutable registry
  index digests for the observability baseline.
