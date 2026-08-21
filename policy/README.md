# Kubernetes Policy Gate

The Conftest policy evaluates fully rendered Helm resources. It rejects
privileged containers, host namespace sharing, privilege escalation, unexpected
Linux capabilities, unexpected host paths, unnecessary service-account tokens,
and images that are not pinned by digest.

The exceptions are intentionally narrow and match the measured architecture:

- the UPF mounts `/dev/net/tun` and adds `NET_ADMIN` to create and route its TUN
  interface;
- the UE container mounts `/dev/net/tun` and adds `NET_ADMIN` plus `NET_RAW` for
  its UERANSIM tunnel and ICMP validation;
- the official MongoDB container starts as root with five explicitly listed
  file-ownership capabilities, while every other capability is dropped;
- Prometheus, kube-state-metrics, and Alloy mount read-only Kubernetes API
  tokens because they discover metrics or logs through scoped RBAC rules.
- Prometheus alone receives `get` access to `nodes/proxy` so kubelet and
  cAdvisor metrics travel through the TLS-verified Kubernetes API proxy. The
  policy rejects that subresource for every other role and rejects broader
  verbs.

Four exact tag-only runtime references are also allowed because kind loads
their already verified local image identities. The Open5GS, UERANSIM, and data
network identities are pinned in the version manifests; MongoDB is pulled and
verified by repository digest before its tag is loaded into the kind node.

No exception permits `privileged: true`, host networking, host PID/IPC access,
or an arbitrary host path. Negative controls in `supply-chain-assurance.sh test-controls`
prove that those boundaries fail closed.
