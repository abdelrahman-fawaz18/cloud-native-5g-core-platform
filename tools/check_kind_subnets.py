#!/usr/bin/env python3
"""Refuse kind creation when Pod or Service ranges overlap host state."""

from __future__ import annotations

import ipaddress
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip("'\"")
    return values


def run(*command: str) -> str:
    return subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    ).stdout


def host_routes() -> list[tuple[ipaddress.IPv4Network, str]]:
    routes: list[tuple[ipaddress.IPv4Network, str]] = []
    for line in run("ip", "-4", "route", "show").splitlines():
        destination = line.split(maxsplit=1)[0]
        if destination == "default":
            continue
        try:
            routes.append((ipaddress.ip_network(destination, strict=False), line))
        except ValueError:
            continue
    return routes


def docker_networks() -> list[tuple[ipaddress.IPv4Network, str]]:
    identifiers = run("docker", "network", "ls", "--quiet").split()
    if not identifiers:
        return []

    records = json.loads(run("docker", "network", "inspect", *identifiers))
    networks: list[tuple[ipaddress.IPv4Network, str]] = []
    for record in records:
        for item in (record.get("IPAM") or {}).get("Config") or []:
            subnet = item.get("Subnet")
            if not subnet:
                continue
            try:
                parsed = ipaddress.ip_network(subnet, strict=False)
            except ValueError:
                continue
            if isinstance(parsed, ipaddress.IPv4Network):
                networks.append((parsed, record.get("Name", "unknown")))
    return networks


def find_conflicts(
    candidates: tuple[ipaddress.IPv4Network, ...],
    existing: list[tuple[ipaddress.IPv4Network, str]],
) -> list[str]:
    return [
        f"{candidate} overlaps {current} ({owner})"
        for candidate in candidates
        for current, owner in existing
        if candidate.overlaps(current)
    ]


def main() -> int:
    manifest = parse_env(ROOT / "versions" / "kubernetes-runtime.env")
    candidates = (
        ipaddress.ip_network(manifest["KIND_POD_SUBNET"]),
        ipaddress.ip_network(manifest["KIND_SERVICE_SUBNET"]),
    )
    if candidates[0].overlaps(candidates[1]):
        print("kind_subnet_check=fail", file=sys.stderr)
        print("conflict=Pod and Service ranges overlap each other", file=sys.stderr)
        return 40

    existing = [
        (network, f"host route: {detail}")
        for network, detail in host_routes()
    ]
    existing += [
        (network, f"Docker network: {name}")
        for network, name in docker_networks()
    ]
    conflicts = find_conflicts(candidates, existing)

    if conflicts:
        print("kind_subnet_check=fail", file=sys.stderr)
        for conflict in conflicts:
            print(f"conflict={conflict}", file=sys.stderr)
        return 40

    for candidate in candidates:
        print(f"available={candidate}")
    print("kind_subnet_check=pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
