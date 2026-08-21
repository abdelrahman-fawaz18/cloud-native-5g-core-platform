#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install-kubernetes-tools.sh --check|--install

  --check    Validate the supported host, existing commands, version pins, and
             installation targets. This mode does not change the host.
  --install  Download, checksum-verify, and install the pinned kind and kubectl
             binaries into /usr/local/bin. Run this mode with sudo.

The installer does not configure a package repository, create a cluster or
kubeconfig, start or enable a service, alter firewall or routing state, change
group membership, install Helm, or overwrite an unrecognized existing binary.
EOF
}

action=${1:-}
if [[ $action == "-h" || $action == "--help" ]]; then
  usage
  exit 0
fi
if [[ $action != "--check" && $action != "--install" ]]; then
  printf 'error: choose exactly one of --check or --install\n' >&2
  usage >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(cd -- "$script_dir/.." && pwd -P)
versions_file="$project_root/versions/kubernetes-runtime.env"

if [[ ! -r $versions_file ]]; then
  printf 'error: version manifest is missing or unreadable: %s\n' \
    "$versions_file" >&2
  exit 2
fi

# shellcheck source=../versions/kubernetes-runtime.env
source "$versions_file"

required_version_variables=(
  KIND_VERSION
  KIND_LINUX_AMD64_SHA256
  KIND_DOWNLOAD_URL
  KUBERNETES_VERSION
  KUBECTL_LINUX_AMD64_SHA256
  KUBECTL_DOWNLOAD_URL
  KIND_NODE_IMAGE
)
for variable_name in "${required_version_variables[@]}"; do
  if [[ -z ${!variable_name:-} ]]; then
    printf 'error: %s is not set in %s\n' "$variable_name" "$versions_file" >&2
    exit 2
  fi
done

for checksum_variable in \
  KIND_LINUX_AMD64_SHA256 KUBECTL_LINUX_AMD64_SHA256; do
  checksum_value=${!checksum_variable}
  if [[ ! $checksum_value =~ ^[0-9a-f]{64}$ ]]; then
    printf 'error: %s is not a lowercase SHA-256 value\n' \
      "$checksum_variable" >&2
    exit 3
  fi
done

. /etc/os-release
host_architecture=$(dpkg --print-architecture)
if [[ ${ID:-} != "ubuntu" || ${VERSION_ID:-} != "24.04" || \
      ${VERSION_CODENAME:-} != "noble" || $host_architecture != "amd64" ]]; then
  printf 'error: supported host is Ubuntu 24.04 noble on amd64\n' >&2
  printf 'observed: id=%s version=%s codename=%s architecture=%s\n' \
    "${ID:-unknown}" "${VERSION_ID:-unknown}" \
    "${VERSION_CODENAME:-unknown}" "$host_architecture" >&2
  exit 4
fi

kind_target=/usr/local/bin/kind
kubectl_target=/usr/local/bin/kubectl

inspect_tool() {
  local tool_name=$1
  local target=$2
  local expected_checksum=$3
  local resolved_path current_checksum

  resolved_path=$(command -v "$tool_name" 2>/dev/null || true)
  if [[ -n $resolved_path && $resolved_path != "$target" ]]; then
    printf 'error: %s already resolves to an unmanaged path: %s\n' \
      "$tool_name" "$resolved_path" >&2
    return 1
  fi

  if [[ ! -e $target ]]; then
    printf '%s_state=absent\n' "$tool_name"
    return 0
  fi
  if [[ ! -f $target || -L $target ]]; then
    printf 'error: refusing non-regular or symbolic-link target: %s\n' \
      "$target" >&2
    return 1
  fi

  current_checksum=$(sha256sum "$target" | awk '{print $1}')
  if [[ $current_checksum != "$expected_checksum" ]]; then
    printf 'error: refusing to replace unrecognized %s\n' "$target" >&2
    printf 'observed_sha256=%s\nexpected_sha256=%s\n' \
      "$current_checksum" "$expected_checksum" >&2
    return 1
  fi

  printf '%s_state=present-and-pinned\n' "$tool_name"
}

printf 'host=Ubuntu %s (%s) architecture=%s\n' \
  "$VERSION_ID" "$VERSION_CODENAME" "$host_architecture"
printf 'kind_version=%s\n' "$KIND_VERSION"
printf 'kind_sha256=%s\n' "$KIND_LINUX_AMD64_SHA256"
printf 'kubectl_version=%s\n' "$KUBERNETES_VERSION"
printf 'kubectl_sha256=%s\n' "$KUBECTL_LINUX_AMD64_SHA256"
printf 'node_image=%s\n' "$KIND_NODE_IMAGE"

inspect_tool kind "$kind_target" "$KIND_LINUX_AMD64_SHA256"
inspect_tool kubectl "$kubectl_target" "$KUBECTL_LINUX_AMD64_SHA256"

if [[ $action == "--check" ]]; then
  printf 'check_result=pass\n'
  exit 0
fi

if (( EUID != 0 )); then
  printf 'error: --install must be run with sudo\n' >&2
  exit 5
fi

for command_name in curl install mktemp sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'error: required command is absent: %s\n' "$command_name" >&2
    exit 6
  fi
done

temporary_dir=$(mktemp -d)
if [[ ! -d $temporary_dir || $temporary_dir != /tmp/* ]]; then
  printf 'error: failed to create a safe temporary directory\n' >&2
  exit 7
fi
cleanup_temporary_dir() {
  rm -rf -- "$temporary_dir"
}
trap cleanup_temporary_dir EXIT

download_and_verify() {
  local tool_name=$1
  local target=$2
  local download_url=$3
  local expected_checksum=$4
  local downloaded_file="$temporary_dir/$tool_name"

  if [[ -e $target ]]; then
    return 0
  fi

  curl --fail --location --show-error --silent \
    --retry 3 --output "$downloaded_file" "$download_url"
  printf '%s  %s\n' "$expected_checksum" "$downloaded_file" | \
    sha256sum --check --status
  install -o root -g root -m 0755 "$downloaded_file" "$target"
}

download_and_verify \
  kind "$kind_target" "$KIND_DOWNLOAD_URL" "$KIND_LINUX_AMD64_SHA256"
download_and_verify \
  kubectl "$kubectl_target" "$KUBECTL_DOWNLOAD_URL" \
  "$KUBECTL_LINUX_AMD64_SHA256"

inspect_tool kind "$kind_target" "$KIND_LINUX_AMD64_SHA256"
inspect_tool kubectl "$kubectl_target" "$KUBECTL_LINUX_AMD64_SHA256"

kind version
kubectl version --client=true

printf 'install_result=pass\n'
printf 'service_changes=none\n'
printf 'cluster_changes=none\n'
printf 'next_step=capture and review the after-tool-install host snapshot\n'
