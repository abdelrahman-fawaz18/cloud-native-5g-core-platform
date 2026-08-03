#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install-helm.sh --check|--install

  --check    Validate the supported host, version contract, existing command,
             and installation target. This mode does not change the host.
  --install  Download, checksum-verify, and install the pinned Helm binary into
             /usr/local/bin. Run this mode with sudo.

The installer does not configure a package repository, create or access a
cluster, create a kubeconfig, start or enable a service, alter firewall or
routing state, or overwrite an unrecognized existing binary.
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
versions_file="$project_root/versions/phase-04.env"

if [[ ! -r $versions_file ]]; then
  printf 'error: version manifest is missing or unreadable: %s\n' \
    "$versions_file" >&2
  exit 2
fi

# shellcheck source=../versions/phase-04.env
source "$versions_file"

required_version_variables=(
  HELM_VERSION
  HELM_GIT_COMMIT
  HELM_LINUX_AMD64_ARCHIVE_SHA256
  HELM_LINUX_AMD64_BINARY_SHA256
  HELM_DOWNLOAD_URL
)
for variable_name in "${required_version_variables[@]}"; do
  if [[ -z ${!variable_name:-} ]]; then
    printf 'error: %s is not set in %s\n' "$variable_name" \
      "$versions_file" >&2
    exit 2
  fi
done

for checksum_variable in \
  HELM_LINUX_AMD64_ARCHIVE_SHA256 HELM_LINUX_AMD64_BINARY_SHA256; do
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

helm_target=/usr/local/bin/helm
expected_version="v${HELM_VERSION}+g${HELM_GIT_COMMIT}"

inspect_helm() {
  local resolved_path current_checksum current_version

  resolved_path=$(command -v helm 2>/dev/null || true)
  if [[ -n $resolved_path && $resolved_path != "$helm_target" ]]; then
    printf 'error: helm already resolves to an unmanaged path: %s\n' \
      "$resolved_path" >&2
    return 1
  fi

  if [[ ! -e $helm_target ]]; then
    printf 'helm_state=absent\n'
    return 0
  fi
  if [[ ! -f $helm_target || -L $helm_target ]]; then
    printf 'error: refusing non-regular or symbolic-link target: %s\n' \
      "$helm_target" >&2
    return 1
  fi

  current_checksum=$(sha256sum "$helm_target" | awk '{print $1}')
  if [[ $current_checksum != "$HELM_LINUX_AMD64_BINARY_SHA256" ]]; then
    printf 'error: refusing to replace unrecognized %s\n' "$helm_target" >&2
    printf 'observed_sha256=%s\nexpected_sha256=%s\n' \
      "$current_checksum" "$HELM_LINUX_AMD64_BINARY_SHA256" >&2
    return 1
  fi

  current_version=$("$helm_target" version --short)
  if [[ $current_version != "$expected_version" ]]; then
    printf 'error: Helm version does not match the pinned build\n' >&2
    printf 'observed_version=%s\nexpected_version=%s\n' \
      "$current_version" "$expected_version" >&2
    return 1
  fi

  printf 'helm_state=present-and-pinned\n'
}

printf 'host=Ubuntu %s (%s) architecture=%s\n' \
  "$VERSION_ID" "$VERSION_CODENAME" "$host_architecture"
printf 'helm_version=%s\n' "$HELM_VERSION"
printf 'helm_git_commit=%s\n' "$HELM_GIT_COMMIT"
printf 'helm_archive_sha256=%s\n' "$HELM_LINUX_AMD64_ARCHIVE_SHA256"
printf 'helm_binary_sha256=%s\n' "$HELM_LINUX_AMD64_BINARY_SHA256"

inspect_helm

if [[ $action == "--check" ]]; then
  printf 'check_result=pass\n'
  exit 0
fi

if (( EUID != 0 )); then
  printf 'error: --install must be run with sudo\n' >&2
  exit 5
fi

for command_name in curl install mktemp sha256sum tar; do
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

if [[ ! -e $helm_target ]]; then
  archive="$temporary_dir/helm.tar.gz"
  curl --fail --location --show-error --silent --retry 3 \
    --output "$archive" "$HELM_DOWNLOAD_URL"
  printf '%s  %s\n' "$HELM_LINUX_AMD64_ARCHIVE_SHA256" "$archive" | \
    sha256sum --check --status

  tar --extract --gzip --no-same-owner --file "$archive" \
    --directory "$temporary_dir" linux-amd64/helm
  extracted_binary="$temporary_dir/linux-amd64/helm"
  if [[ ! -f $extracted_binary || -L $extracted_binary ]]; then
    printf 'error: verified archive did not contain a regular Helm binary\n' \
      >&2
    exit 8
  fi
  printf '%s  %s\n' "$HELM_LINUX_AMD64_BINARY_SHA256" \
    "$extracted_binary" | sha256sum --check --status
  install -o root -g root -m 0755 "$extracted_binary" "$helm_target"
fi

inspect_helm
"$helm_target" version --short

printf 'install_result=pass\n'
printf 'service_changes=none\n'
printf 'cluster_changes=none\n'
printf 'next_step=capture and review the after-Helm-install host snapshot\n'
