# Configuration

This directory will contain synthetic, environment-independent Open5GS,
UERANSIM, data-network, and test configuration templates.

Configuration must keep cross-component Public Land Mobile Network (PLMN),
Tracking Area Code (TAC), Single Network Slice Selection Assistance Information
(S-NSSAI), Data Network Name (DNN), addresses, ports, and subscriber contracts
explicit. Live secrets and local overrides remain untracked.

`compose/` contains the Phase 2 single-UE baseline: separate Open5GS Network
Function files, one simulated gNodeB, one synthetic User Equipment profile,
and an idempotent MongoDB subscriber initializer. Its private ranges
deliberately differ from the host Open5GS lab ranges.

`kubernetes/phase-05/subscriber-plan.json` is the public, non-secret source of
truth for the five synthetic UEs and two DNN network contracts. It fixes
ordinal-to-IMSI-to-DNN mapping and contains no K, OPc, token, password, or
local path. `scripts/generate-phase05-subscribers.py` validates it before
deriving ignored runtime material from a local seed.

`kubernetes/phase-05/invalid-ue-pod.yaml` is an exact, short-lived
negative-test Pod. Its configuration Secret is generated at runtime, its
identity is deliberately not provisioned, and the lifecycle helper removes
both objects after validating that the five accepted UEs remain operational.
`kubernetes/phase-05/reprovision-job.yaml` is an independently owned,
short-lived recovery Job used to restore one deliberately removed managed
record and prove idempotent batch convergence.
