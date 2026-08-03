# CN5G Helm Chart

This chart packages the verified Open5GS, MongoDB, UERANSIM, and controlled
data-network images as one Kubernetes release. The baseline deliberately runs
one replica of each 5G function, one gNodeB, and one synthetic UE.

Non-sensitive configuration is rendered through ConfigMaps. The chart never
templates subscriber authentication material; `subscriberSecret.existingSecret`
must name a Secret created from the ignored files produced by
`scripts/generate-subscriber-secret.sh`.

Project-built images use `imagePullPolicy: Never` and must be loaded into the
named kind node only after their local identities match the Phase 2 manifest.
MongoDB uses an immutable registry digest.

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
