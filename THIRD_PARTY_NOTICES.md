# Third-Party Software Notices

This repository contains original orchestration, configuration, validation,
analysis, and documentation licensed under the repository `LICENSE`. It builds
or deploys separate third-party programs that remain governed by their own
licenses. This notice is an index, not a replacement for upstream license
texts or legal advice.

| Component | Accepted project use | Upstream license reference |
| --- | --- | --- |
| Open5GS 2.7.7 | Locally built 5G Core Network Functions | [GNU AGPL-3.0](https://github.com/open5gs/open5gs/blob/v2.7.7/LICENSE) |
| UERANSIM 3.2.8 | Locally built synthetic UE and gNodeB | [GNU AGPL-3.0 or commercial license](https://github.com/aligungr/UERANSIM/blob/v3.2.8/LICENSE) |
| MongoDB 8.0.28 | Digest-pinned Docker Official Image | [Server Side Public License and component notices](https://github.com/mongodb/mongo/blob/master/LICENSE-Community.txt) |
| Prometheus 3.13.1 | Metrics collection, queries, and alert evaluation | [Apache-2.0](https://github.com/prometheus/prometheus/blob/v3.13.1/LICENSE) |
| Grafana 13.1.0 | Dashboard rendering and data-source integration | [AGPL-3.0-only with documented exceptions](https://github.com/grafana/grafana/blob/v13.1.0/LICENSING.md) |
| Grafana Loki 3.7.2 | Project log storage and queries | [AGPL-3.0-only with documented exceptions](https://github.com/grafana/loki/blob/v3.7.2/LICENSING.md) |
| Grafana Alloy 1.18.0 | Kubernetes log collection and forwarding | [Apache-2.0 with dependency notices](https://github.com/grafana/alloy/blob/v1.18.0/LICENSING.md) |
| kube-state-metrics 2.18.0 | Kubernetes object metrics | [Apache-2.0](https://github.com/kubernetes/kube-state-metrics/blob/v2.18.0/LICENSE) |
| Alpine Linux 3.22.5 packages | Data-network and benchmark runtime packages | [Package-specific licenses](https://pkgs.alpinelinux.org/packages?branch=v3.22) |
| Ubuntu 24.04 packages | Open5GS and UERANSIM build/runtime packages | [Package-specific copyright records](https://packages.ubuntu.com/noble/) |
| iperf3 3.19.1 | Controlled Phase 7 traffic measurement | [BSD-style license](https://github.com/esnet/iperf/blob/3.19.1/LICENSE) |

The exact source commits, archive checksums, base-image manifests, local image
identities, and distribution boundary are recorded in
[`docs/image-provenance.md`](docs/image-provenance.md). Phase 9 SPDX Software
Bills of Materials and scanner reports are generated into ignored local or
hosted-workflow artifacts; they are not hand-maintained in this notice.

No project container image is pushed by the accepted workflow. Anyone who
publishes a built image must independently satisfy the corresponding source,
notice, and license obligations, especially those of Open5GS and UERANSIM.
