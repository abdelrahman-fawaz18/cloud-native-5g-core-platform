# Phase 7 Performance And Capacity Experiment Report

Status: reviewed local-lab evidence; not production sizing.

## Result

Campaign `20260806T223341Z-matrix` completed all nine accepted conditions: three repetitions
at 1, 3, and 5 concurrent synthetic UEs. Registration and PDU-session success
were 100% in every accepted condition, every traffic command completed, no new
container restart occurred, and the runner restored five UEs after every attempt.

![Aggregate traffic results](../benchmarks/phase-07/results/plots/throughput.svg)

| UEs | Forward aggregate Mbit/s | Forward per-UE median Mbit/s | Jain fairness | Reverse aggregate Mbit/s | Maximum UDP loss % | Median ICMP RTT ms |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 114.70 | 114.70 | 1.0000 | 10.00 | 0.00 | 2.089 |
| 3 | 79.38 | 26.19 | 0.9997 | 29.99 | 0.00 | 1.491 |
| 5 | 91.70 | 17.61 | 0.9928 | 49.98 | 0.00 | 1.266 |

Forward TCP was unbounded and is the only saturation-oriented traffic stage.
Reverse TCP offered exactly 10 Mbit/s per UE, while UDP offered 1 Mbit/s per UE;
those values test service-load delivery and are not downlink-capacity claims.

## Procedure Behavior

![Procedure latency](../benchmarks/phase-07/results/plots/procedures.svg)

| UEs | Registration success % | Registration median ms | PDU success % | PDU median ms |
| --- | --- | --- | --- | --- |
| 1 | 100.0 | 60.000 | 100.0 | 216.000 |
| 3 | 100.0 | 54.000 | 100.0 | 68.000 |
| 5 | 100.0 | 83.000 | 100.0 | 88.000 |

Each latency cell above is the median of three condition-level medians. The
machine-readable summary also retains minimum, maximum, nearest-rank p95, and
sample standard deviation. With only three repetitions, p95 equals the maximum
observed repetition and should be interpreted cautiously.

## Resource Evidence And Bottleneck Reading

![Five-UE CPU peaks](../benchmarks/phase-07/results/plots/resources.svg)

The largest individual accepted-condition CPU peak was
`ue/ue` at 520.7 millicores.
The largest memory peak was `ue/ue` at
58.2 MiB. Resource analysis filters Prometheus
series against each condition's runtime Pod snapshot, preventing terminated
rollout Pods from inflating the result. No accepted condition recorded a
container restart or Out-of-Memory kill.

The forward aggregate result should be read together with the falling per-UE
share as concurrency rises. It characterizes contention in this exact
single-host, user-space simulated path; it does not establish commercial RAN or
5G Core capacity.

At five UEs, the median peak CPU was 515.7 millicores across the five UE runtime
containers, 334.7 millicores at the single gNB, and 147.7 millicores at the
UPF. Median forward retransmissions rose from 233 at one UE to 729 at three and
1,919 at five, while aggregate forward throughput did not scale with UE count.
Together these observations identify the simulated UE/gNB side of the path as
the leading bottleneck candidate. They do not isolate one causal function;
packet-level profiling would be required for that stronger claim.

## Retained Failures

Earlier exploratory campaigns are intentionally excluded from the accepted
summary. They exposed reverse-TCP stalls under an unbounded downlink workload
and a stale UPF endpoint-policy ordering defect. Both failures were retained,
explained, and used to correct the experiment contract. The accepted contract
restarts DNN endpoints before rebuilding the session chain and treats reverse
TCP as a fixed 10 Mbit/s-per-UE service-load check.

## Reproduction

```bash
sudo ./scripts/phase07-lab.sh preflight
sudo ./scripts/phase07-lab.sh pilot
sudo ./scripts/phase07-lab.sh run-matrix
./scripts/analyze-phase07.py
```

The analyzer validates the experiment hash, accepted markers, manifests,
runtime restart snapshots, and all required traffic/telemetry files before it
writes reviewed outputs. Raw evidence remains ignored and permission-restricted.

## Reviewed Artifacts

- `benchmarks/phase-07/results/summary.json`
- `benchmarks/phase-07/results/condition-summary.csv`
- `benchmarks/phase-07/results/per-ue.csv`
- `benchmarks/phase-07/results/resource-summary.csv`
- `benchmarks/phase-07/results/plots/`

## Limitations

- Single Ubuntu host and single-node kind cluster; results are not carrier capacity or production sizing.
- UERANSIM models the radio link in user space and does not implement a complete 5G NR physical layer.
- Reverse TCP is a fixed 10 Mbit/s per-UE service-load check, not a maximum downlink-capacity test.
- The accepted matrix contains three repetitions per load level; nearest-rank p95 therefore equals the maximum repetition-level observation.
- Idle telemetry proves a timestamped baseline exists, but component comparisons use condition telemetry filtered by runtime Pod identity to exclude terminated-container series.
