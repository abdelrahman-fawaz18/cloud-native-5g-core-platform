# Benchmarks

This directory contains reproducible experiment definitions, reviewed
machine-readable summaries, plotting tools, and methodology.

Large raw measurements stay untracked. Every reported value must identify the
topology, versions, host resources, workload, duration, repetitions, and
limitations.

Phase 7 begins with the tracked contract in
[`phase-07/experiment.json`](phase-07/experiment.json). Raw per-run iperf3,
ICMP, Kubernetes, Prometheus, and host-safety captures are written beneath
`benchmarks/raw/`, which is intentionally ignored. Only summaries generated
from complete retained runs are eligible for review and publication.

The successful one-UE pilot unlocks the resumable `run-matrix` lifecycle. Each
matrix condition keeps numbered attempts for auditability; one accepted marker
per repetition/level prevents accidental reruns, and failures are never
silently discarded. Every attempt begins with the documented clean-state reset
so that earlier load levels cannot alter a later condition's session state.
Forward TCP remains unbounded to expose local saturation behavior. Reverse TCP
uses an explicit 10 Mbit/s offered load per UE after an exploratory unbounded
reverse run stalled at the one-UE condition; that bounded result is a service
load check and must not be presented as maximum downlink capacity.

After the raw campaign reaches `raw_complete`, run
`./scripts/phase07-lab.sh analyze`. The analyzer refuses incomplete or
hash-mismatched evidence, filters resource series by the condition's runtime
Pod identities, and regenerates the tracked files under `phase-07/results/`
plus the sanitized Phase 7 report.

Phase 8 uses the separate tracked contract in
[`phase-08/experiment.json`](phase-08/experiment.json). It deletes exactly one
AMF, SMF, or UPF Pod per attempt, distinguishes Kubernetes detection and Pod
readiness from end-to-end service recovery, and performs three repetitions per
component only after all three pilots pass. MongoDB recreation and invalid
configuration rejection are separate safety tests and do not enter the timing
distributions.

Each accepted recovery attempt retains Kubernetes events, bounded Loki logs,
Prometheus ranges, a two-second service timeline, exact Pod/PVC identities,
and pre/post validation locally under `benchmarks/raw/phase-08/`. The analyzer
accepts only the exact nine-condition campaign with complete baseline
restoration and generates reviewed Phase 8 artifacts. The accepted campaign
now supplies the Reliability and Recovery Grafana dashboard through a
deterministic 75-series reviewed metric fixture.
