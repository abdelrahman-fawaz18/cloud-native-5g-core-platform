# ADR-0009: Performance Benchmark Traffic Path And Tooling

## Status

Accepted

## Context

Performance campaign must measure the real synthetic 5G user-plane path. Running a traffic
client from the Ubuntu host or allowing a UE Pod to use its ordinary Kubernetes
interface would bypass UERANSIM, GTP-U, the UPF, and DNN policy routing. Such a
result could look fast while measuring the wrong network.

The accepted platform topology has exactly five synthetic subscriber identities
and two DNNs. The host also runs unrelated laboratories, so traffic generation
must remain inside the project-owned kind cluster and must have explicit abort
and rollback behavior.

## Decision

- Build `cn5g/benchmark:0.1.0` from digest-pinned Alpine 3.22.5 with exact
  `iperf3`, `iproute2`, and `iputils` package versions.
- Add an idle, unprivileged benchmark client sidecar to each UE Pod and an
  unprivileged iperf3 server sidecar to each controlled DNN endpoint only when
  the performance campaign Helm overlay is enabled.
- Run one independent iperf3 server port per UE ordinal (5201-5205) so that
  concurrent conditions do not serialize behind a single-test server.
- Keep each benchmark root filesystem read-only and mount only a dedicated,
  memory-backed 16 MiB `/tmp` scratch volume required for iperf3 stream setup.
- Bind each client to the UE session address. Before every test, require
  `ip route get` to show `uesimtun0` and source-policy table 1000. The same
  kernel table is named `rt_uesimtun0` inside the UE container; the sidecar's
  separate read-only filesystem does not contain that friendly-name mapping.
- Reject and retain a run if traffic would use the ordinary Pod interface.
- Begin with 1, 3, and 5 concurrent UEs, three repetitions, fixed duration,
  warm-up, and cool-down. Do not add synthetic identities merely to claim a
  larger number.
- Keep forward TCP unbounded to observe local saturation behavior, but apply a
  declared 10 Mbit/s per-UE offered rate to reverse TCP. Retain the exploratory
  unbounded reverse-path stall as failed evidence and do not present the
  bounded test as maximum downlink capacity.
- Keep raw results ignored and publish only reviewed summaries that preserve
  failures and outliers.
- Keep the accepted five-UE topology as the restoration target after every
  experiment and after performance campaign rollback.

## Alternatives Considered

- **Run iperf3 on the host:** simpler, but expands host networking effects and
  does not naturally prove the UE source path.
- **Install iperf3 in the existing UERANSIM image:** measures the right path,
  but changes an already accepted runtime image for a temporary experiment.
- **Use ordinary Pod-to-Pod traffic:** easy and fast, but bypasses the 5G user
  plane and is invalid evidence.
- **Start at 10 UEs:** potentially interesting, but the accepted secret and
  reproducible subscriber model currently contain five identities.

## Evidence

- The [iperf3 documentation](https://software.es.net/iperf/) defines its
  client/server design and machine-readable JSON results.
- The [iperf3 invocation reference](https://software.es.net/iperf/invoking.html)
  documents source binding, warm-up omission, reverse TCP, UDP offered rate,
  loss, and jitter.
- Alpine 3.22 publishes the selected
  [iperf3](https://pkgs.alpinelinux.org/package/v3.22/main/x86_64/iperf3),
  [iproute2](https://pkgs.alpinelinux.org/package/v3.22/main/x86_64/iproute2),
  and [iputils](https://pkgs.alpinelinux.org/package/v3.22/main/x86_64/iputils)
  packages.
- platform already proves that source-bound HTTP and ICMP use `uesimtun0`, reach
  only the intended DNN, and deny cross-DNN traffic.

## Consequences

The benchmark measures the intended local 5G path without modifying accepted
Open5GS or UERANSIM images. Sidecars add bounded CPU and memory overhead, which
must be disclosed and sampled. Results remain one-host kind-lab evidence, not
commercial capacity certification.

## Reversal Or Migration

Apply only the accepted platform and observability stack value overlays, wait for all
workloads, repair the session chain if required, and re-run both validators.
This removes the benchmark sidecars and ports without deleting subscriber or
telemetry state. A future 10-UE matrix requires a separately reviewed identity,
resource, and safety change.
