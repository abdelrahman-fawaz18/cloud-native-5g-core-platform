# CN5G Helm Chart

This chart packages the verified Open5GS, MongoDB, UERANSIM, and controlled
data-network images as one Kubernetes release. The baseline deliberately runs
one replica of each 5G function, one gNodeB, and one synthetic UE.

Non-sensitive configuration is rendered through ConfigMaps. The chart never
templates subscriber authentication material; `subscriberSecret.existingSecret`
must name a Secret created from the ignored files produced by
`scripts/generate-subscriber-secret.sh`.

Every workload uses `imagePullPolicy: Never` and must be loaded into the named
kind node only after its local identity matches the Phase 2 manifest. MongoDB's
upstream `tag@digest` is verified before its fixed-version tag is imported;
the imported containerd image ID is then compared with that accepted digest.
This two-sided gate is required because kind's Docker-image import preserves
the tag and content identity but does not preserve the upstream RepoDigest
alias. Kubernetes therefore cannot pull an unreviewed replacement at runtime.
For project-built OCI indexes, the loader first accepts the recorded index
digest and then reads the runtime configuration digest from the same Docker
archive consumed by kind. That digest is compared with the image ID reported
by the container runtime through CRI. Index, platform-manifest, attestation,
and runtime-configuration digests are distinct OCI objects and are never
compared as though they were equivalent. Repository digests are not used for
this post-import comparison because kind assigns local `import-*` repository
aliases while retaining the configuration identity.

Open5GS, UERANSIM, and the data endpoint use Deployments. MongoDB uses a
StatefulSet and a dynamically provisioned data PersistentVolumeClaim (PVC).
Subscriber provisioning uses a revision-scoped idempotent Job. Workloads use a
ServiceAccount with no Role or RoleBinding because they do not need Kubernetes
Application Programming Interface (API) access.

The initial resource settings are conservative Phase 2-derived candidates.
Phase 4 runtime evidence must measure and accept or revise them before release.

`helm lint` and `helm template` validate package structure and deterministic
rendering. They do not prove SCTP, NGAP, PFCP, GTP-U, TUN, N6 routing, UE
registration, PDU-session establishment, persistence, upgrade, or rollback.
