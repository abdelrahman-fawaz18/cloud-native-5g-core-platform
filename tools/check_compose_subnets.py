#!/usr/bin/env python3
"""Refuse Compose network creation when candidate ranges overlap host state."""

from __future__ import annotations

import ipaddress
import json
import subprocess
import sys


PROJECT = "cn5g-compose"
CANDIDATES = (
    ipaddress.ip_network("172.28.0.0/24"),
    ipaddress.ip_network("10.60.0.0/24"),
    ipaddress.ip_network("10.62.0.0/24"),
)


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


def docker_networks() -> tuple[
    list[tuple[ipaddress.IPv4Network, str]], set[ipaddress.IPv4Network]
]:
    identifiers = run("docker", "network", "ls", "--quiet").split()
    if not identifiers:
        return [], set()

    records = json.loads(run("docker", "network", "inspect", *identifiers))
    networks: list[tuple[ipaddress.IPv4Network, str]] = []
    project_networks: set[ipaddress.IPv4Network] = set()
    for record in records:
        labels = record.get("Labels") or {}
        project_owned = labels.get("com.docker.compose.project") == PROJECT
        for item in (record.get("IPAM") or {}).get("Config") or []:
            subnet = item.get("Subnet")
            if not subnet:
                continue
            try:
                parsed = ipaddress.ip_network(subnet, strict=False)
            except ValueError:
                continue
            if isinstance(parsed, ipaddress.IPv4Network):
                if project_owned:
                    project_networks.add(parsed)
                else:
                    networks.append((parsed, record.get("Name", "unknown")))
    return networks, project_networks


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
    other_docker_networks, project_networks = docker_networks()
    existing = [
        (network, f"host route: {detail}")
        for network, detail in host_routes()
        if network not in project_networks
    ]
    existing += [
        (network, f"Docker network: {name}")
        for network, name in other_docker_networks
    ]

    conflicts = find_conflicts(CANDIDATES, existing)

    if conflicts:
        print("compose_subnet_check=fail", file=sys.stderr)
        for conflict in conflicts:
            print(f"conflict={conflict}", file=sys.stderr)
        return 40

    for candidate in CANDIDATES:
        print(f"available={candidate}")
    print("compose_subnet_check=pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
