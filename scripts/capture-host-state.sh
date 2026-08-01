#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/capture-host-state.sh LABEL

Capture a read-only host snapshot under artifacts/host-state/LABEL.

Run `sudo -v` first. The script uses non-interactive sudo only for live
firewall and container-daemon reads. It refuses to overwrite an existing
snapshot.
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

snapshot_label=${1:-}
if [[ ! $snapshot_label =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
  printf 'error: LABEL must match ^[a-z0-9][a-z0-9._-]*$\n' >&2
  usage >&2
  exit 2
fi

if ! command -v git >/dev/null 2>&1; then
  printf 'error: git is required to locate the project root\n' >&2
  exit 2
fi

project_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  printf 'error: run this script from inside the project repository\n' >&2
  exit 2
}

expected_project='cloud-native-5g-core-platform'
if [[ ${project_root##*/} != "$expected_project" ]]; then
  printf 'error: refusing to run outside the %s repository\n' \
    "$expected_project" >&2
  exit 2
fi

if ! sudo -n true 2>/dev/null; then
  printf 'error: administrative read access is not cached\n' >&2
  printf 'run `sudo -v`, then rerun this script as your normal user\n' >&2
  exit 3
fi

umask 077
snapshot_root="$project_root/artifacts/host-state"
snapshot_dir="$snapshot_root/$snapshot_label"

if [[ -e $snapshot_dir ]]; then
  printf 'error: snapshot already exists: %s\n' "$snapshot_dir" >&2
  exit 4
fi

mkdir -p "$snapshot_dir"

section() {
  printf '\n===== %s =====\n' "$1"
}

{
  section 'CAPTURE METADATA'
  printf 'captured_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf 'label=%s\n' "$snapshot_label"
  printf 'git_commit=%s\n' "$(git -C "$project_root" rev-parse HEAD)"
  printf 'git_branch=%s\n' "$(git -C "$project_root" branch --show-current)"

  section 'OPERATING SYSTEM'
  . /etc/os-release
  printf 'pretty_name=%s\nversion_id=%s\ncodename=%s\n' \
    "$PRETTY_NAME" "$VERSION_ID" "$VERSION_CODENAME"
  printf 'kernel=%s\narchitecture=%s\n' "$(uname -r)" "$(uname -m)"

  section 'CPU AND VIRTUALIZATION'
  lscpu | sed -n -E \
    '/^(CPU\(s\)|On-line CPU\(s\) list|Vendor ID|Model name|Virtualization:|Hypervisor vendor:)/p'

  section 'MEMORY AND SWAP'
  free -b
  swapon --show --bytes 2>/dev/null || true

  section 'DISK AND INODES'
  df -B1 -T / /var/lib 2>/dev/null || true
  df -i / /var/lib 2>/dev/null || true

  section 'KERNEL NETWORK PRIMITIVES'
  ls -l /dev/net/tun 2>&1 || true
  lsmod | awk 'NR == 1 || $1 ~ /^(sctp|gtp|tun|udp_tunnel|ip6_udp_tunnel)$/'
  for module_name in sctp gtp tun udp_tunnel; do
    if modinfo "$module_name" >/dev/null 2>&1; then
      printf '%s: available (%s)\n' "$module_name" \
        "$(modinfo -F filename "$module_name" | head -n 1)"
    else
      printf '%s: no modinfo entry\n' "$module_name"
    fi
  done
  sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding 2>/dev/null || true

  section 'CGROUP AND SECURITY'
  printf 'cgroup_filesystem=%s\n' "$(stat -fc %T /sys/fs/cgroup)"
  findmnt -n -o TARGET,FSTYPE,OPTIONS /sys/fs/cgroup 2>/dev/null || true
  if command -v aa-status >/dev/null 2>&1; then
    aa-status --enabled 2>/dev/null && printf 'apparmor=enabled\n' || true
  fi
} >"$snapshot_dir/system.txt" 2>&1

{
  section 'INTERFACES'
  ip -brief address
  section 'BRIDGES'
  ip -details -brief link show type bridge 2>/dev/null || true
  section 'IPV4 ROUTES'
  ip -4 route show table main
  section 'IPV6 ROUTES'
  ip -6 route show table main
  section 'POLICY RULES'
  ip rule show
  section 'NETWORK NAMESPACES'
  ip netns list 2>/dev/null || true
} >"$snapshot_dir/network.txt" 2>&1

{
  section 'UFW'
  sudo -n ufw status verbose 2>&1 || true
  section 'NFTABLES'
  sudo -n nft list ruleset 2>&1 || true
  section 'IPV4 IPTABLES'
  sudo -n iptables-save 2>&1 || true
  section 'IPV6 IPTABLES'
  sudo -n ip6tables-save 2>&1 || true
} >"$snapshot_dir/firewall.txt" 2>&1

{
  section 'RELEVANT PACKAGES'
  dpkg-query -W \
    -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' 2>/dev/null |
    grep -Ei '^(docker|containerd|podman|cri-o|kubectl|kubeadm|kubelet|kubernetes|helm|prometheus|grafana|open5gs|mongodb|mongod|lxc)' || true

  section 'RELEVANT SERVICE UNITS'
  systemctl list-unit-files --type=service --no-legend 2>/dev/null |
    grep -Ei '(docker|containerd|podman|kube|k3s|prometheus|grafana|open5gs|mongod|lxc)' || true

  section 'RELEVANT SERVICE STATE'
  systemctl list-units --type=service --all --no-legend 2>/dev/null |
    grep -Ei '(docker|containerd|podman|kube|k3s|prometheus|grafana|open5gs|mongod|lxc)' || true

  section 'LISTENING TCP AND UDP SOCKETS'
  ss -H -lntup 2>/dev/null || true
  section 'LISTENING SCTP SOCKETS'
  ss -H -lnp -A sctp 2>/dev/null || true
} >"$snapshot_dir/services.txt" 2>&1

{
  section 'COMMAND VERSIONS'
  for tool_name in docker podman containerd kubectl kind k3s helm prometheus grafana-server; do
    if command -v "$tool_name" >/dev/null 2>&1; then
      printf '%s=%s\n' "$tool_name" "$(command -v "$tool_name")"
    else
      printf '%s=absent\n' "$tool_name"
    fi
  done

  if command -v docker >/dev/null 2>&1; then
    section 'DOCKER VERSION'
    sudo -n docker version 2>&1 || true
    section 'DOCKER INFO'
    sudo -n docker info 2>&1 || true
    section 'DOCKER CONTEXTS'
    docker context ls 2>&1 || true
    section 'DOCKER CONTAINERS'
    sudo -n docker ps --all --no-trunc 2>&1 || true
    section 'DOCKER NETWORKS'
    sudo -n docker network ls --no-trunc 2>&1 || true
    section 'DOCKER VOLUMES'
    sudo -n docker volume ls 2>&1 || true
  fi

  if command -v kubectl >/dev/null 2>&1; then
    section 'KUBERNETES CONTEXTS'
    kubectl config get-contexts 2>&1 || true
  fi
} >"$snapshot_dir/runtime.txt" 2>&1

(
  cd "$snapshot_dir"
  sha256sum firewall.txt network.txt runtime.txt services.txt system.txt \
    >SHA256SUMS
)

printf 'snapshot created: %s\n' "$snapshot_dir"
printf 'raw output is local-only and ignored by Git\n'
