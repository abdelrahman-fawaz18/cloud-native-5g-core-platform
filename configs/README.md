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
