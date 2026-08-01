#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install-docker-engine.sh --check|--install

  --check    Validate the supported host and print the pinned package plan.
             This mode does not require root and does not change the host.
  --install  Configure Docker's official Ubuntu repository and install only
             the exact versions in versions/phase-02.env. Run with sudo.

The script never removes conflicting packages, changes firewall rules directly,
adds users to the docker group, or deletes Docker data.
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
versions_file="$project_root/versions/phase-02.env"

if [[ ! -r $versions_file ]]; then
  printf 'error: version manifest is missing or unreadable: %s\n' \
    "$versions_file" >&2
  exit 2
fi

# shellcheck source=../versions/phase-02.env
source "$versions_file"

required_version_variables=(
  DOCKER_CE_VERSION
  DOCKER_CE_CLI_VERSION
  CONTAINERD_IO_VERSION
  DOCKER_BUILDX_PLUGIN_VERSION
  DOCKER_COMPOSE_PLUGIN_VERSION
)
for variable_name in "${required_version_variables[@]}"; do
  if [[ -z ${!variable_name:-} ]]; then
    printf 'error: %s is not set in %s\n' "$variable_name" "$versions_file" >&2
    exit 2
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
  exit 5
fi

conflicting_packages=(
  docker.io
  docker-compose
  docker-compose-v2
  docker-doc
  docker-buildx
  podman-docker
  containerd
  runc
)
installed_conflicts=()
for package_name in "${conflicting_packages[@]}"; do
  package_state=$(dpkg-query -W -f='${db:Status-Abbrev}' \
    "$package_name" 2>/dev/null || true)
  if [[ $package_state == ii* ]]; then
    installed_conflicts+=("$package_name")
  fi
done
if (( ${#installed_conflicts[@]} > 0 )); then
  printf 'error: conflicting packages are installed:\n' >&2
  printf '  %s\n' "${installed_conflicts[@]}" >&2
  printf 'the script will not remove packages automatically\n' >&2
  exit 6
fi

package_names=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
)
package_versions=(
  "$DOCKER_CE_VERSION"
  "$DOCKER_CE_CLI_VERSION"
  "$CONTAINERD_IO_VERSION"
  "$DOCKER_BUILDX_PLUGIN_VERSION"
  "$DOCKER_COMPOSE_PLUGIN_VERSION"
)

printf 'host=Ubuntu %s (%s) architecture=%s\n' \
  "$VERSION_ID" "$VERSION_CODENAME" "$host_architecture"
printf 'package plan:\n'
for package_index in "${!package_names[@]}"; do
  printf '  %s=%s\n' \
    "${package_names[$package_index]}" \
    "${package_versions[$package_index]}"
done

if [[ $action == "--check" ]]; then
  if command -v docker >/dev/null 2>&1; then
    printf 'docker_command=present\n'
  else
    printf 'docker_command=absent\n'
  fi
  printf 'check_result=pass\n'
  exit 0
fi

if (( EUID != 0 )); then
  printf 'error: --install must be run with sudo\n' >&2
  exit 7
fi

installed_docker_version=$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || true)
if [[ -n $installed_docker_version ]]; then
  all_versions_match=true
  for package_index in "${!package_names[@]}"; do
    installed_version=$(dpkg-query -W -f='${Version}' \
      "${package_names[$package_index]}" 2>/dev/null || true)
    if [[ $installed_version != "${package_versions[$package_index]}" ]]; then
      all_versions_match=false
      printf 'error: installed %s version is %s; expected %s\n' \
        "${package_names[$package_index]}" \
        "${installed_version:-absent}" \
        "${package_versions[$package_index]}" >&2
    fi
  done
  if [[ $all_versions_match == true ]]; then
    printf 'install_result=already-at-pinned-versions\n'
    systemctl is-enabled docker.service
    systemctl is-active docker.service
    docker version
    docker compose version
    docker buildx version
    exit 0
  fi
  printf 'error: refusing to modify an existing mismatched Docker installation\n' >&2
  exit 8
fi

temporary_dir=$(mktemp -d)
if [[ ! -d $temporary_dir || $temporary_dir != /tmp/* ]]; then
  printf 'error: failed to create a safe temporary directory\n' >&2
  exit 9
fi
cleanup_temporary_dir() {
  rm -rf -- "$temporary_dir"
}
trap cleanup_temporary_dir EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o "$temporary_dir/docker.asc"
if [[ ! -s $temporary_dir/docker.asc ]]; then
  printf 'error: downloaded Docker repository key is empty\n' >&2
  exit 10
fi

install -m 0755 -d /etc/apt/keyrings
install -m 0644 "$temporary_dir/docker.asc" /etc/apt/keyrings/docker.asc

printf '%s\n' \
  'Types: deb' \
  'URIs: https://download.docker.com/linux/ubuntu' \
  'Suites: noble' \
  'Components: stable' \
  'Architectures: amd64' \
  'Signed-By: /etc/apt/keyrings/docker.asc' \
  >"$temporary_dir/docker.sources"
install -m 0644 "$temporary_dir/docker.sources" \
  /etc/apt/sources.list.d/docker.sources

apt-get update

for package_index in "${!package_names[@]}"; do
  if ! apt-cache madison "${package_names[$package_index]}" |
      awk -v expected="${package_versions[$package_index]}" \
        '$3 == expected { found = 1 } END { exit !found }'; then
    printf 'error: repository does not provide %s=%s\n' \
      "${package_names[$package_index]}" \
      "${package_versions[$package_index]}" >&2
    exit 11
  fi
done

apt-get install -y --no-install-recommends \
  "docker-ce=$DOCKER_CE_VERSION" \
  "docker-ce-cli=$DOCKER_CE_CLI_VERSION" \
  "containerd.io=$CONTAINERD_IO_VERSION" \
  "docker-buildx-plugin=$DOCKER_BUILDX_PLUGIN_VERSION" \
  "docker-compose-plugin=$DOCKER_COMPOSE_PLUGIN_VERSION"

for package_index in "${!package_names[@]}"; do
  installed_version=$(dpkg-query -W -f='${Version}' \
    "${package_names[$package_index]}")
  if [[ $installed_version != "${package_versions[$package_index]}" ]]; then
    printf 'error: post-install version mismatch for %s: %s\n' \
      "${package_names[$package_index]}" "$installed_version" >&2
    exit 12
  fi
done

printf 'docker_enabled=%s\n' "$(systemctl is-enabled docker.service)"
printf 'docker_active=%s\n' "$(systemctl is-active docker.service)"
printf 'containerd_active=%s\n' "$(systemctl is-active containerd.service)"
docker version
docker compose version
docker buildx version

printf 'install_result=pass\n'
printf 'security_note=no user was added to the docker group\n'
printf 'next_step=capture and review the after-docker host snapshot\n'
