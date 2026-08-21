#!/usr/bin/env python3
"""Generate deterministic, ignored platform subscriber and UE material.

The tracked plan contains synthetic identities and service assignments but no
authentication values. A permission-restricted local seed is created once.
HMAC-SHA256 derives matching K and OPc values for Open5GS and UERANSIM. Reruns
with the same plan and seed reproduce byte-identical output.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PLAN = ROOT / "configs/kubernetes/platform/subscriber-plan.json"
DEFAULT_OUTPUT = ROOT / "artifacts/secrets/platform"
SEED_FILE = "derivation-seed.hex"
SUPPORTED_DNNS = {
    "internet": ("10.60.0.0/24", "10.60.0.1", "ogstun", "data-internet"),
    "enterprise": ("10.61.0.0/24", "10.61.0.1", "ogstun2", "data-enterprise"),
}
EXPECTED_SUBSCRIBERS = 5
IMSI_RE = re.compile(r"^99970[0-9]{10}$")
IMEI_RE = re.compile(r"^[0-9]{15}$")
IMEISV_RE = re.compile(r"^[0-9]{16}$")


class PlanError(ValueError):
    """Raised when the public subscriber plan violates the platform contract."""


def load_plan(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise PlanError("plan is missing or is not a regular file")
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PlanError(f"plan is unreadable or invalid JSON: {exc}") from exc
    validate_plan(plan)
    return plan


def validate_plan(plan: dict[str, Any]) -> None:
    if set(plan) != {"schemaVersion", "plmn", "slice", "dnns", "subscribers"}:
        raise PlanError("plan has missing or unsupported top-level fields")
    if plan["schemaVersion"] != 1:
        raise PlanError("unsupported plan schemaVersion")
    if plan["plmn"] != {"mcc": "999", "mnc": "70", "tac": 1}:
        raise PlanError("plan must use the reserved synthetic PLMN and TAC")
    if plan["slice"] != {"sst": 1}:
        raise PlanError("plan must use the accepted SST 1 slice")

    dnns = plan["dnns"]
    if not isinstance(dnns, list) or len(dnns) != len(SUPPORTED_DNNS):
        raise PlanError("plan must define exactly the two accepted DNNs")
    observed_dnns: dict[str, tuple[str, str, str, str]] = {}
    observed_pools: set[ipaddress.IPv4Network] = set()
    for dnn in dnns:
        required = {"name", "pool", "gateway", "tunDevice", "endpoint"}
        if not isinstance(dnn, dict) or set(dnn) != required:
            raise PlanError("each DNN must contain only the supported fields")
        name = dnn["name"]
        if name not in SUPPORTED_DNNS:
            raise PlanError(f"unsupported DNN: {name}")
        contract = (dnn["pool"], dnn["gateway"], dnn["tunDevice"], dnn["endpoint"])
        if contract != SUPPORTED_DNNS[name]:
            raise PlanError(f"DNN contract differs from the accepted network model: {name}")
        network = ipaddress.ip_network(dnn["pool"], strict=True)
        gateway = ipaddress.ip_address(dnn["gateway"])
        if gateway not in network or gateway in (network.network_address, network.broadcast_address):
            raise PlanError(f"DNN gateway is outside the usable pool: {name}")
        if any(network.overlaps(existing) for existing in observed_pools):
            raise PlanError("DNN address pools overlap")
        observed_pools.add(network)
        observed_dnns[name] = contract
    if set(observed_dnns) != set(SUPPORTED_DNNS):
        raise PlanError("accepted DNN set is incomplete")

    subscribers = plan["subscribers"]
    if not isinstance(subscribers, list) or len(subscribers) != EXPECTED_SUBSCRIBERS:
        raise PlanError(f"plan must define exactly {EXPECTED_SUBSCRIBERS} subscribers")
    imsis: set[str] = set()
    imeis: set[str] = set()
    imeisvs: set[str] = set()
    dnn_counts = {name: 0 for name in SUPPORTED_DNNS}
    for expected_ordinal, subscriber in enumerate(subscribers):
        required = {"ordinal", "imsi", "imei", "imeiSv", "dnn"}
        if not isinstance(subscriber, dict) or set(subscriber) != required:
            raise PlanError("each subscriber must contain only the supported fields")
        if subscriber["ordinal"] != expected_ordinal:
            raise PlanError("subscriber ordinals must be contiguous from zero")
        imsi = subscriber["imsi"]
        imei = subscriber["imei"]
        imeisv = subscriber["imeiSv"]
        if not isinstance(imsi, str) or not IMSI_RE.fullmatch(imsi):
            raise PlanError("IMSI is outside the reserved synthetic range")
        if not isinstance(imei, str) or not IMEI_RE.fullmatch(imei):
            raise PlanError("IMEI must contain exactly 15 decimal digits")
        if not isinstance(imeisv, str) or not IMEISV_RE.fullmatch(imeisv):
            raise PlanError("IMEISV must contain exactly 16 decimal digits")
        if imsi in imsis or imei in imeis or imeisv in imeisvs:
            raise PlanError("duplicate subscriber identity detected")
        if subscriber["dnn"] not in SUPPORTED_DNNS:
            raise PlanError(f"unsupported subscriber DNN: {subscriber['dnn']}")
        imsis.add(imsi)
        imeis.add(imei)
        imeisvs.add(imeisv)
        dnn_counts[subscriber["dnn"]] += 1
    if not all(count > 0 for count in dnn_counts.values()):
        raise PlanError("both accepted DNNs must have at least one subscriber")


def derive_hex(seed: bytes, purpose: str, imsi: str) -> str:
    payload = f"cn5g-platform:{purpose}:{imsi}".encode("ascii")
    return hmac.new(seed, payload, hashlib.sha256).digest()[:16].hex().upper()


def object_id(label: str) -> str:
    return hashlib.sha256(f"cn5g-platform:{label}".encode("ascii")).hexdigest()[:24]


def ue_yaml(plan: dict[str, Any], subscriber: dict[str, Any], seed: bytes) -> str:
    imsi = subscriber["imsi"]
    return f"""# Generated synthetic platform UE configuration. Do not commit this file.
supi: 'imsi-{imsi}'
mcc: '{plan['plmn']['mcc']}'
mnc: '{plan['plmn']['mnc']}'
protectionScheme: 0
homeNetworkPublicKey: '5a8d38864820197c3394b92613b20b91633cbd897119273bf8e4a6f4eec0a650'
homeNetworkPublicKeyId: 1
routingIndicator: '0000'

key: '{derive_hex(seed, "k", imsi)}'
op: '{derive_hex(seed, "opc", imsi)}'
opType: 'OPC'
amf: '8000'
imei: '{subscriber['imei']}'
imeiSv: '{subscriber['imeiSv']}'

tunNetmask: '255.255.255.0'
useNamespace: false
gnbSearchList:
  - __GNB_IP__

uacAic: {{mps: false, mcs: false}}
uacAcc:
  normalClass: 0
  class11: false
  class12: false
  class13: false
  class14: false
  class15: false

sessions:
  - type: 'IPv4'
    apn: '{subscriber['dnn']}'
    slice: {{sst: {plan['slice']['sst']}}}
configured-nssai: [{{sst: {plan['slice']['sst']}}}]
default-nssai: [{{sst: {plan['slice']['sst']}}}]
integrity: {{IA1: true, IA2: true, IA3: true}}
ciphering: {{EA1: true, EA2: true, EA3: true}}
integrityMaxRate: {{uplink: 'full', downlink: 'full'}}
"""


def subscriber_document(plan: dict[str, Any], subscriber: dict[str, Any], seed: bytes) -> str:
    imsi = subscriber["imsi"]
    dnn = subscriber["dnn"]
    ordinal = subscriber["ordinal"]
    return f"""  {{
    _id: ObjectId('{object_id(f"subscriber:{imsi}")}'),
    schema_version: NumberInt(1),
    imsi: '{imsi}',
    msisdn: [], imeisv: [], mme_host: [], mm_realm: [], purge_flag: [],
    slice: [{{
      _id: ObjectId('{object_id(f"slice:{imsi}")}'),
      sst: NumberInt({plan['slice']['sst']}),
      default_indicator: true,
      session: [{{
        _id: ObjectId('{object_id(f"session:{imsi}:{dnn}")}'),
        name: '{dnn}', type: NumberInt(1),
        qos: {{index: NumberInt(9), arp: {{priority_level: NumberInt(8), pre_emption_capability: NumberInt(1), pre_emption_vulnerability: NumberInt(2)}}}},
        ambr: {{downlink: {{value: NumberInt(1000000000), unit: NumberInt(0)}}, uplink: {{value: NumberInt(1000000000), unit: NumberInt(0)}}}},
        pcc_rule: []
      }}]
    }}],
    security: {{k: '{derive_hex(seed, "k", imsi)}', op: null, opc: '{derive_hex(seed, "opc", imsi)}', amf: '8000'}},
    ambr: {{downlink: {{value: NumberInt(1000000000), unit: NumberInt(0)}}, uplink: {{value: NumberInt(1000000000), unit: NumberInt(0)}}}},
    access_restriction_data: NumberInt(32), network_access_mode: NumberInt(0),
    subscriber_status: NumberInt(0), operator_determined_barring: NumberInt(0),
    subscribed_rau_tau_timer: NumberInt(12), __v: NumberInt(0),
    cn5g_managed: {{topology: 'multi-ue', ordinal: NumberInt({ordinal}), dnn: '{dnn}'}}
  }}"""


def provisioning_javascript(plan: dict[str, Any], seed: bytes) -> str:
    docs = ",\n".join(subscriber_document(plan, sub, seed) for sub in plan["subscribers"])
    imsis = ", ".join(f"'{sub['imsi']}'" for sub in plan["subscribers"])
    return f"""// Generated synthetic platform provisioning input. Do not commit this file.
const open5gs = db.getSiblingDB('open5gs');
const subscribers = [
{docs}
];
const imsis = subscribers.map((subscriber) => subscriber.imsi);
if (new Set(imsis).size !== subscribers.length) {{
  throw new Error('duplicate IMSI detected before provisioning');
}}
if (subscribers.length !== {EXPECTED_SUBSCRIBERS}) {{
  throw new Error('unexpected managed subscriber count before provisioning');
}}

for (const subscriber of subscribers) {{
  const mutable = Object.assign({{}}, subscriber);
  delete mutable._id;
  open5gs.subscribers.updateOne(
    {{imsi: subscriber.imsi}},
    {{$set: mutable, $setOnInsert: {{_id: subscriber._id}}}},
    {{upsert: true}}
  );
}}

const managed = open5gs.subscribers.find(
  {{imsi: {{$in: [{imsis}]}}}},
  {{imsi: 1, 'cn5g_managed.topology': 1}}
).toArray();
if (managed.length !== {EXPECTED_SUBSCRIBERS} ||
    managed.some((subscriber) => subscriber.cn5g_managed.topology !== 'multi-ue')) {{
  throw new Error(`expected {EXPECTED_SUBSCRIBERS} managed synthetic subscribers, found ${{managed.length}}`);
}}
print('subscriber_batch_init=pass count={EXPECTED_SUBSCRIBERS}');
"""


def safe_write(path: Path, content: str, mode: int = 0o600) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def require_mode(path: Path, expected: int) -> None:
    actual = stat.S_IMODE(path.stat().st_mode)
    if actual != expected:
        raise PlanError(f"unsafe mode on {path.name}: expected {expected:o}, observed {actual:o}")


def load_seed(output: Path, create: bool) -> bytes:
    seed_path = output / SEED_FILE
    if not seed_path.exists():
        if not create:
            raise PlanError("local derivation seed is absent")
        safe_write(seed_path, secrets.token_hex(32) + "\n")
    if not seed_path.is_file() or seed_path.is_symlink():
        raise PlanError("local derivation seed is unsafe")
    require_mode(seed_path, 0o600)
    encoded = seed_path.read_text(encoding="ascii").strip()
    if not re.fullmatch(r"[0-9a-f]{64}", encoded):
        raise PlanError("local derivation seed must be 32-byte lowercase hexadecimal")
    return bytes.fromhex(encoded)


def expected_outputs(plan: dict[str, Any], seed: bytes) -> dict[str, str]:
    files = {"subscriber-init.js": provisioning_javascript(plan, seed)}
    public_manifest = {
        "schemaVersion": plan["schemaVersion"],
        "subscriberCount": len(plan["subscribers"]),
        "dnns": plan["dnns"],
        "subscribers": [
            {key: sub[key] for key in ("ordinal", "imsi", "dnn")}
            for sub in plan["subscribers"]
        ],
    }
    files["plan.json"] = json.dumps(public_manifest, indent=2, sort_keys=True) + "\n"
    for sub in plan["subscribers"]:
        ordinal = sub["ordinal"]
        files[f"ue-{ordinal}.yaml"] = ue_yaml(plan, sub, seed)
        files[f"imsi-{ordinal}"] = sub["imsi"] + "\n"
        files[f"dnn-{ordinal}"] = sub["dnn"] + "\n"
    return files


def check_material(plan: dict[str, Any], output: Path) -> None:
    if not output.is_dir() or output.is_symlink():
        raise PlanError("platform material directory is missing or unsafe")
    require_mode(output, 0o700)
    seed = load_seed(output, create=False)
    expected = expected_outputs(plan, seed)
    allowed = set(expected) | {SEED_FILE}
    observed = {path.name for path in output.iterdir()}
    if observed != allowed:
        raise PlanError("platform material directory has missing or unexpected files")
    for name, content in expected.items():
        path = output / name
        if not path.is_file() or path.is_symlink():
            raise PlanError(f"generated file is missing or unsafe: {name}")
        require_mode(path, 0o600)
        if path.read_text(encoding="utf-8") != content:
            raise PlanError(f"generated file differs from deterministic contract: {name}")


def generate(plan: dict[str, Any], output: Path) -> None:
    if output.exists() and (not output.is_dir() or output.is_symlink()):
        raise PlanError("refusing unsafe platform output path")
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(output, 0o700)
    seed = load_seed(output, create=True)
    for name, content in expected_outputs(plan, seed).items():
        safe_write(output / name, content)
    check_material(plan, output)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true")
    action.add_argument("--generate", action="store_true")
    action.add_argument("--validate-plan", action="store_true")
    parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        plan = load_plan(args.plan.resolve())
        if args.validate_plan:
            print("platform_subscriber_plan_validation=pass")
            return 0
        output = args.output.resolve()
        if args.check:
            if not output.exists():
                print("platform_subscriber_material_state=absent")
                print("check_result=pass")
                return 0
            check_material(plan, output)
            print("platform_subscriber_material_state=present-deterministic-and-restricted")
            print("platform_subscriber_material_validation=pass")
            print("check_result=pass")
            return 0
        generate(plan, output)
        print("platform_subscriber_material_state=present-deterministic-and-restricted")
        print(f"platform_subscriber_count={EXPECTED_SUBSCRIBERS}")
        print("platform_dnn_count=2")
        print("platform_subscriber_generation=pass")
        return 0
    except (OSError, PlanError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
