# Version And Provenance Manifests

This directory records exact tool, source, package, image, chart, and action
inputs used by verified project baselines.

Each manifest must identify:

- the component and exact version;
- the authoritative source;
- a checksum or immutable digest when the artifact format supports one;
- the date on which availability was verified;
- relevant license or provenance notes; and
- the phase whose tests accepted the version.

A value in a phase manifest is a candidate until that phase's runtime and
cleanup exit gate passes. Floating `latest` tags are not release inputs.
