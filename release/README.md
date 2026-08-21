# Release Evidence

This directory contains small, reviewable contracts that connect public
release claims to tracked evidence. Raw logs, credentials, kubeconfigs,
Software Bills of Materials, scanner output, and host snapshots remain under
ignored `artifacts/` paths.

`phase-10-evidence.json` is the bounded claim inventory. Its state stays
`candidate` until every Phase 10 acceptance gate passes. The final dashboard
capture manifest is named `dashboard-evidence.json`; it is added only after
the images are captured, inspected, stripped of metadata, and checksum-bound
to their source dashboard and Git commit.

The contracts are evidence indexes, not substitutes for the referenced
methods, reports, automated tests, or live validation.
