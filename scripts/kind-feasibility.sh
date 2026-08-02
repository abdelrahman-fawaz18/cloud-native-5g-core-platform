#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: sudo scripts/kind-feasibility.sh ACTION [--confirm]

Actions:
  preflight       Read-only host, tool, ownership, resource, and subnet checks.
  create          Create only the named cn5g feasibility cluster and namespace.
  status          Show the exact cluster, node container, node, and system Pods.
  delete          Delete only cluster cn5g; requires the second argument --confirm.
  verify-delete   Prove that the cluster, node container, and kubeconfig are gone.

The script never prunes Docker state, modifies host services, publishes the API
server beyond loopback, uses the default user kubeconfig, or removes images.
EOF
}

action=${1:-}
confirmation=${2:-}
if [[ $action == "-h" || $action == "--help" ]]; then
  usage
  exit 0
fi
case "$action" in
  preflight|create|status|delete|verify-delete) ;;
  *)
    printf 'error: unknown action: %s\n' "${action:-<empty>}" >&2
    usage >&2
    exit 2
    ;;
esac

if (( EUID != 0 )) || [[ -z ${SUDO_UID:-} || -z ${SUDO_GID:-} ]]; then
  printf 'error: run this lifecycle through sudo from the normal account\n' >&2
  exit 3
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(cd -- "$script_dir/.." && pwd -P)
if [[ ${project_root##*/} != "cloud-native-5g-core-platform" ]]; then
  printf 'error: refusing to run outside the expected repository\n' >&2
  exit 3
fi

versions_file="$project_root/versions/phase-03.env"
config_file="$project_root/configs/kind/phase-03.yaml"
subnet_checker="$project_root/tools/check_kind_subnets.py"
artifact_dir="$project_root/artifacts/kubernetes"
kubeconfig="$artifact_dir/cn5g.kubeconfig"

for required_file in "$versions_file" "$config_file" "$subnet_checker"; do
  if [[ ! -r $required_file ]]; then
    printf 'error: required file is missing or unreadable: %s\n' \
      "$required_file" >&2
    exit 4
  fi
done

# shellcheck source=../versions/phase-03.env
source "$versions_file"

required_variables=(
  KIND_VERSION
  KIND_LINUX_AMD64_SHA256
  KUBERNETES_VERSION
  KUBECTL_LINUX_AMD64_SHA256
  KIND_NODE_IMAGE
  KIND_CLUSTER_NAME
  KIND_CONTEXT_NAME
  KIND_FEASIBILITY_NAMESPACE
  KIND_API_SERVER_ADDRESS
  KIND_POD_SUBNET
  KIND_SERVICE_SUBNET
  KIND_DOCKER_NETWORK_NAME
  KIND_DOCKER_IPV4_SUBNET
  KIND_DOCKER_IPV6_SUBNET
)
for variable_name in "${required_variables[@]}"; do
  if [[ -z ${!variable_name:-} ]]; then
    printf 'error: %s is not set in %s\n' "$variable_name" "$versions_file" >&2
    exit 4
  fi
done

if [[ $KIND_CLUSTER_NAME != "cn5g" || \
      $KIND_CONTEXT_NAME != "kind-cn5g" || \
      $KIND_API_SERVER_ADDRESS != "127.0.0.1" ]]; then
  printf 'error: cluster ownership or loopback API contract changed\n' >&2
  exit 5
fi

verify_binary() {
  local tool_name=$1
  local expected_path=$2
  local expected_checksum=$3
  local resolved_path observed_checksum

  resolved_path=$(command -v "$tool_name" 2>/dev/null || true)
  if [[ $resolved_path != "$expected_path" ]]; then
    printf 'error: expected %s at %s; observed %s\n' \
      "$tool_name" "$expected_path" "${resolved_path:-absent}" >&2
    return 1
  fi
  observed_checksum=$(sha256sum "$expected_path" | awk '{print $1}')
  if [[ $observed_checksum != "$expected_checksum" ]]; then
    printf 'error: %s checksum mismatch\n' "$tool_name" >&2
    return 1
  fi
}

basic_preflight() {
  verify_binary kind /usr/local/bin/kind "$KIND_LINUX_AMD64_SHA256"
  verify_binary kubectl /usr/local/bin/kubectl \
    "$KUBECTL_LINUX_AMD64_SHA256"

  if [[ $(systemctl is-active docker.service) != "active" || \
        $(systemctl is-active containerd.service) != "active" ]]; then
    printf 'error: Docker and containerd must remain active\n' >&2
    return 1
  fi
  if [[ $(systemctl is-active open5gs-amfd.service) != "active" || \
        $(systemctl is-active mongod.service) != "active" ]]; then
    printf 'error: protected host lab services are not active\n' >&2
    return 1
  fi
  printf 'host_lab_services=active\n'

  for process_name in nr-gnb nr-ue; do
    if pgrep -x "$process_name" >/dev/null 2>&1; then
      printf 'error: host process is already running: %s\n' \
        "$process_name" >&2
      return 1
    fi
  done
  printf 'host_ran_or_simulation_processes=none\n'

  available_kib=$(df -Pk /var/lib/docker | awk 'NR == 2 { print $4 }')
  minimum_kib=$((12 * 1024 * 1024))
  if (( available_kib < minimum_kib )); then
    printf 'error: Docker filesystem has less than 12 GiB available\n' >&2
    return 1
  fi
  printf 'docker_filesystem_available_gib=%s\n' \
    "$((available_kib / 1024 / 1024))"

  available_memory_kib=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
  minimum_memory_kib=$((6 * 1024 * 1024))
  if (( available_memory_kib < minimum_memory_kib )); then
    printf 'error: host has less than 6 GiB available memory\n' >&2
    return 1
  fi
  printf 'host_memory_available_gib=%s\n' \
    "$((available_memory_kib / 1024 / 1024))"
}

cluster_names() {
  kind get clusters 2>/dev/null || true
}

remove_empty_owned_kind_network() {
  if ! docker network inspect "$KIND_DOCKER_NETWORK_NAME" \
      >/dev/null 2>&1; then
    printf 'kind_network_cleanup=already-absent\n'
    return 0
  fi

  if [[ -n $(cluster_names) ]]; then
    printf 'error: refusing network removal while kind clusters remain\n' >&2
    return 1
  fi

  local network_name network_driver network_scope
  local container_count label_count observed_subnets
  local -a observed_subnet_list
  network_name=$(docker network inspect --format '{{.Name}}' \
    "$KIND_DOCKER_NETWORK_NAME")
  network_driver=$(docker network inspect --format '{{.Driver}}' \
    "$KIND_DOCKER_NETWORK_NAME")
  network_scope=$(docker network inspect --format '{{.Scope}}' \
    "$KIND_DOCKER_NETWORK_NAME")
  container_count=$(docker network inspect --format '{{len .Containers}}' \
    "$KIND_DOCKER_NETWORK_NAME")
  label_count=$(docker network inspect --format '{{len .Labels}}' \
    "$KIND_DOCKER_NETWORK_NAME")
  observed_subnets=$(docker network inspect --format \
    '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' \
    "$KIND_DOCKER_NETWORK_NAME")
  mapfile -t observed_subnet_list <<<"$observed_subnets"

  if [[ $network_name != "$KIND_DOCKER_NETWORK_NAME" || \
        $network_driver != "bridge" || $network_scope != "local" || \
        $container_count != "0" || $label_count != "0" || \
        ${#observed_subnet_list[@]} -ne 2 || \
        $observed_subnets != *"$KIND_DOCKER_IPV4_SUBNET"* || \
        $observed_subnets != *"$KIND_DOCKER_IPV6_SUBNET"* ]]; then
    printf 'error: refusing to remove unrecognized or non-empty kind network\n' \
      >&2
    printf 'name=%s driver=%s scope=%s containers=%s labels=%s\n' \
      "$network_name" "$network_driver" "$network_scope" \
      "$container_count" "$label_count" >&2
    printf 'subnets=%s\n' "$observed_subnets" >&2
    return 1
  fi

  docker network rm "$KIND_DOCKER_NETWORK_NAME" >/dev/null
  printf 'kind_network_cleanup=removed-empty-owned-network\n'
}

pristine_cluster_preflight() {
  mapfile -t clusters < <(cluster_names)
  if (( ${#clusters[@]} > 0 )); then
    printf 'error: existing kind cluster(s) require review:\n' >&2
    printf '  %s\n' "${clusters[@]}" >&2
    return 1
  fi
  if docker container inspect cn5g-control-plane >/dev/null 2>&1; then
    printf 'error: exact node container already exists: cn5g-control-plane\n' >&2
    return 1
  fi
  if docker network inspect "$KIND_DOCKER_NETWORK_NAME" >/dev/null 2>&1; then
    printf 'error: Docker network named kind already exists without a cluster\n' >&2
    return 1
  fi
  if [[ -e $kubeconfig ]]; then
    printf 'error: refusing to overwrite existing kubeconfig: %s\n' \
      "$kubeconfig" >&2
    return 1
  fi

  python3 "$subnet_checker"
  printf 'existing_kind_clusters=none\n'
  printf 'kind_network=absent\n'
  printf 'project_kubeconfig=absent\n'
}

show_status() {
  if ! cluster_names | grep -Fxq "$KIND_CLUSTER_NAME"; then
    printf 'error: cluster is absent: %s\n' "$KIND_CLUSTER_NAME" >&2
    return 1
  fi
  if [[ ! -r $kubeconfig ]]; then
    printf 'error: project kubeconfig is absent or unreadable: %s\n' \
      "$kubeconfig" >&2
    return 1
  fi

  printf 'cluster=%s\ncontext=%s\nkubeconfig=%s\n' \
    "$KIND_CLUSTER_NAME" "$KIND_CONTEXT_NAME" "$kubeconfig"
  docker ps --filter 'name=^/cn5g-control-plane$' --no-trunc
  kubectl --kubeconfig "$kubeconfig" get nodes -o wide
  kubectl --kubeconfig "$kubeconfig" get pods --all-namespaces -o wide
}

case "$action" in
  preflight)
    basic_preflight
    pristine_cluster_preflight
    printf 'cluster_preflight=pass\n'
    ;;
  create)
    basic_preflight
    pristine_cluster_preflight
    install -d -o "$SUDO_UID" -g "$SUDO_GID" -m 0700 "$artifact_dir"

    kind create cluster \
      --name "$KIND_CLUSTER_NAME" \
      --image "$KIND_NODE_IMAGE" \
      --config "$config_file" \
      --kubeconfig "$kubeconfig" \
      --wait 180s

    chown "$SUDO_UID:$SUDO_GID" "$kubeconfig"
    chmod 0600 "$kubeconfig"

    observed_context=$(kubectl --kubeconfig "$kubeconfig" \
      config current-context)
    if [[ $observed_context != "$KIND_CONTEXT_NAME" ]]; then
      printf 'error: unexpected context after creation: %s\n' \
        "$observed_context" >&2
      exit 30
    fi
    kubectl --kubeconfig "$kubeconfig" wait \
      --for=condition=Ready nodes --all --timeout=180s
    kubectl --kubeconfig "$kubeconfig" wait \
      --for=condition=Ready pods --all --all-namespaces --timeout=180s
    kubectl --kubeconfig "$kubeconfig" create namespace \
      "$KIND_FEASIBILITY_NAMESPACE"
    kubectl --kubeconfig "$kubeconfig" label namespace \
      "$KIND_FEASIBILITY_NAMESPACE" \
      app.kubernetes.io/part-of=cloud-native-5g-core-platform \
      app.kubernetes.io/managed-by=cn5g-feasibility-script
    show_status
    printf 'cluster_creation=pass\n'
    ;;
  status)
    basic_preflight
    show_status
    ;;
  delete)
    if [[ $confirmation != "--confirm" ]]; then
      printf 'error: delete requires the exact second argument --confirm\n' >&2
      exit 31
    fi
    basic_preflight
    printf 'delete_target_cluster=%s\n' "$KIND_CLUSTER_NAME"
    docker ps --all --filter 'name=^/cn5g-control-plane$' --no-trunc
    kind delete cluster \
      --name "$KIND_CLUSTER_NAME" \
      --kubeconfig "$kubeconfig"
    if docker container inspect cn5g-control-plane >/dev/null 2>&1; then
      printf 'error: node container remains after kind deletion\n' >&2
      exit 32
    fi
    remove_empty_owned_kind_network
    rm -f -- "$kubeconfig"
    printf 'cluster_deletion=pass\n'
    ;;
  verify-delete)
    basic_preflight
    if cluster_names | grep -Fxq "$KIND_CLUSTER_NAME"; then
      printf 'error: kind still lists cluster %s\n' "$KIND_CLUSTER_NAME" >&2
      exit 33
    fi
    if docker container inspect cn5g-control-plane >/dev/null 2>&1; then
      printf 'error: node container remains: cn5g-control-plane\n' >&2
      exit 33
    fi
    if [[ -e $kubeconfig ]]; then
      printf 'error: project kubeconfig remains: %s\n' "$kubeconfig" >&2
      exit 33
    fi
    if docker network inspect "$KIND_DOCKER_NETWORK_NAME" \
        >/dev/null 2>&1; then
      printf 'error: Docker network remains: %s\n' \
        "$KIND_DOCKER_NETWORK_NAME" >&2
      exit 34
    fi
    printf 'kind_cluster=absent\n'
    printf 'kind_node_container=absent\n'
    printf 'project_kubeconfig=absent\n'
    printf 'kind_network=absent\n'
    printf 'scoped_cluster_cleanup=pass\n'
    ;;
esac
