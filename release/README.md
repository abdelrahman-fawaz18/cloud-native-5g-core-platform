# Release Evidence

This directory contains small, reviewable contracts that connect public
Release claims to tracked evidence. Raw logs, credentials, kubeconfigs,
Software Bills of Materials, scanner output, and host snapshots remain under
ignored `artifacts/` paths.

`release-evidence.json` is the accepted bounded claim inventory. Its status
can be used for publication only when the fail-closed release audit
also proves that the current commit has matching clean-clone, clean-runtime,
privileged, hosted-equivalent, and visual evidence. The accepted dashboard
capture manifest is `dashboard-evidence.json`; its images were inspected,
stripped of metadata, and checksum-bound to their source dashboards.

The contracts are evidence indexes, not substitutes for the referenced
methods, reports, automated tests, or live validation.
