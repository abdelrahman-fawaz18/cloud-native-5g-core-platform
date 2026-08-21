#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: sudo scripts/networking-qualification.sh ACTION [--confirm]

Actions:
  preflight-image  Verify the exact Compose reference base image and target ownership.
  build-image      Build only cn5g/feasibility-probe:0.1.0.
  rebuild-image-candidate
                   Rebuild an owned probe after a reviewed source correction
                   and print its new identity for manifest acceptance.
  verify-image     Inspect the probe image identity, labels, platform, and user.
  load-image       Load the exact local probe image into cluster cn5g.
  verify-load      Prove that the node runtime can resolve the probe image.
  deploy-transport Deploy the unprivileged direct-Pod and Service probes.
  status-transport Show only the Networking qualification transport probe resources.
  validate-transport
                   Run direct-Pod and Service TCP, UDP, and SCTP checks.
  cleanup-transport
                   Delete only the transport probes; requires --confirm.
  deploy-tun       Deploy negative and minimum-capability TUN probes.
  status-tun       Show only the Networking qualification TUN probe Pods.
  validate-tun     Verify denial without and success with only NET_ADMIN.
  cleanup-tun      Delete only the TUN probes; requires --confirm.
  deploy-n6        Deploy the controlled routed TUN and observer topology.
  status-n6        Show only the Networking qualification N6 routing resources.
  validate-n6      Verify bidirectional routed traffic and packet visibility.
  cleanup-n6       Delete only the N6 probes; requires --confirm.

No action publishes a port, changes a host service, removes Docker state, or
uses a registry. The load actions require the existing named cn5g cluster.
EOF
}

action=${1:-}
confirmation=${2:-}
case "$action" in
  -h|--help)
    usage
    exit 0
    ;;
  preflight-image|build-image|rebuild-image-candidate|verify-image|\
  load-image|verify-load|\
  deploy-transport|status-transport|validate-transport|cleanup-transport|\
  deploy-tun|status-tun|validate-tun|cleanup-tun|\
  deploy-n6|status-n6|validate-n6|cleanup-n6) ;;
  *)
    printf 'error: unknown action: %s\n' "${action:-<empty>}" >&2
    usage >&2
    exit 2
    ;;
esac

if (( EUID != 0 )) || [[ -z ${SUDO_UID:-} || -z ${SUDO_GID:-} ]]; then
  printf 'error: run this script through sudo from the normal account\n' >&2
  exit 3
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(cd -- "$script_dir/.." && pwd -P)
if [[ ${project_root##*/} != "cloud-native-5g-core-platform" ]]; then
  printf 'error: refusing to run outside the cloud-native-5g-core-platform repository\n' \
    >&2
  exit 3
fi

# shellcheck source=../versions/kubernetes-runtime.env
source "$project_root/versions/kubernetes-runtime.env"

required_variables=(
  UERANSIM_BASE_IMAGE
  KIND_FEASIBILITY_PROBE_IMAGE
  KIND_FEASIBILITY_PROBE_IMAGE_ID
  KIND_CLUSTER_NAME
  KIND_FEASIBILITY_NAMESPACE
)
for variable_name in "${required_variables[@]}"; do
  if [[ -z ${!variable_name:-} ]]; then
    printf 'error: %s is not set in versions/kubernetes-runtime.env\n' \
      "$variable_name" >&2
    exit 4
  fi
done

expected_source=https://github.com/abdelrahman-fawaz18/cloud-native-5g-core-platform
expected_title="Cloud-Native 5G Core Feasibility Probe"
kubeconfig="$project_root/artifacts/kubernetes/cn5g.kubeconfig"
transport_manifest="$project_root/configs/kubernetes/networking-qualification/01-transport-probes.yaml"
tun_manifest="$project_root/configs/kubernetes/networking-qualification/02-tun-capability-probes.yaml"
n6_manifest="$project_root/configs/kubernetes/networking-qualification/03-n6-routing-probes.yaml"
n6_return_subnet=10.60.0.0/24
n6_return_protocol=186
n6_return_metric=36060

verify_base_image() {
  if ! docker image inspect "$UERANSIM_BASE_IMAGE" >/dev/null 2>&1; then
    printf 'error: exact accepted Compose reference base image is absent: %s\n' \
      "$UERANSIM_BASE_IMAGE" >&2
    return 1
  fi
  printf 'base_image=%s\n' "$UERANSIM_BASE_IMAGE"
}

verify_target_ownership_or_absence() {
  if ! docker image inspect "$KIND_FEASIBILITY_PROBE_IMAGE" \
      >/dev/null 2>&1; then
    printf 'probe_image_state=absent\n'
    return 0
  fi
  local source_label title_label
  source_label=$(docker image inspect --format \
    '{{index .Config.Labels "org.opencontainers.image.source"}}' \
    "$KIND_FEASIBILITY_PROBE_IMAGE")
  title_label=$(docker image inspect --format \
    '{{index .Config.Labels "org.opencontainers.image.title"}}' \
    "$KIND_FEASIBILITY_PROBE_IMAGE")
  if [[ $source_label != "$expected_source" || \
        $title_label != "$expected_title" ]]; then
    printf 'error: refusing to replace probe tag not owned by this project\n' >&2
    return 1
  fi
  printf 'probe_image_state=present-and-project-owned\n'
}

image_preflight() {
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
  printf 'host_reference_services=active\n'

  for process_name in nr-gnb nr-ue; do
    if pgrep -x "$process_name" >/dev/null 2>&1; then
      printf 'error: host process is already running: %s\n' \
        "$process_name" >&2
      return 1
    fi
  done
  printf 'host_ran_or_simulation_processes=none\n'

  local available_kib minimum_kib
  available_kib=$(df -Pk /var/lib/docker | awk 'NR == 2 { print $4 }')
  minimum_kib=$((8 * 1024 * 1024))
  if (( available_kib < minimum_kib )); then
    printf 'error: Docker filesystem has less than 8 GiB available\n' >&2
    return 1
  fi
  printf 'docker_filesystem_available_gib=%s\n' \
    "$((available_kib / 1024 / 1024))"
  verify_base_image
  verify_target_ownership_or_absence
  printf 'probe_image_preflight=pass\n'
}

verify_probe_image_structure() {
  if ! docker image inspect "$KIND_FEASIBILITY_PROBE_IMAGE" \
      >/dev/null 2>&1; then
    printf 'error: probe image is absent: %s\n' \
      "$KIND_FEASIBILITY_PROBE_IMAGE" >&2
    return 1
  fi
  verify_target_ownership_or_absence
  local image_id image_user image_platform
  image_id=$(docker image inspect --format '{{.Id}}' \
    "$KIND_FEASIBILITY_PROBE_IMAGE")
  image_user=$(docker image inspect --format '{{.Config.User}}' \
    "$KIND_FEASIBILITY_PROBE_IMAGE")
  image_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' \
    "$KIND_FEASIBILITY_PROBE_IMAGE")
  if [[ $image_user != "65532:65532" || \
        $image_platform != "linux/amd64" ]]; then
    printf 'error: unexpected probe image user or platform\n' >&2
    return 1
  fi
  printf 'probe_image=%s\n' "$KIND_FEASIBILITY_PROBE_IMAGE"
  printf 'probe_image_id=%s\n' "$image_id"
  printf 'probe_image_platform=%s\n' "$image_platform"
  printf 'probe_image_default_user=%s\n' "$image_user"
}

verify_probe_image() {
  verify_probe_image_structure
  local image_id
  image_id=$(docker image inspect --format '{{.Id}}' \
    "$KIND_FEASIBILITY_PROBE_IMAGE")
  if [[ $image_id != "$KIND_FEASIBILITY_PROBE_IMAGE_ID" ]]; then
    printf 'error: probe image identity does not match networking.env\n' >&2
    printf 'observed_image_id=%s\nexpected_image_id=%s\n' \
      "$image_id" "$KIND_FEASIBILITY_PROBE_IMAGE_ID" >&2
    return 1
  fi
  printf 'probe_image_verification=pass\n'
}

build_probe_image() {
  docker buildx build \
    --file "$project_root/containers/feasibility-probe/Dockerfile" \
    --platform linux/amd64 \
    --build-arg "UERANSIM_BASE_IMAGE=$UERANSIM_BASE_IMAGE" \
    --tag "$KIND_FEASIBILITY_PROBE_IMAGE" \
    --load \
    "$project_root"
}

require_cluster() {
  if ! kind get clusters 2>/dev/null | grep -Fxq "$KIND_CLUSTER_NAME"; then
    printf 'error: required cluster is absent: %s\n' \
      "$KIND_CLUSTER_NAME" >&2
    return 1
  fi
  if ! docker container inspect cn5g-control-plane >/dev/null 2>&1; then
    printf 'error: exact kind node container is absent\n' >&2
    return 1
  fi
  if [[ ! -r $kubeconfig ]]; then
    printf 'error: project kubeconfig is absent or unreadable: %s\n' \
      "$kubeconfig" >&2
    return 1
  fi
  if ! kubectl --kubeconfig "$kubeconfig" get namespace \
      "$KIND_FEASIBILITY_NAMESPACE" >/dev/null 2>&1; then
    printf 'error: feasibility namespace is absent: %s\n' \
      "$KIND_FEASIBILITY_NAMESPACE" >&2
    return 1
  fi
}

verify_node_image() {
  docker exec cn5g-control-plane crictl inspecti \
    "$KIND_FEASIBILITY_PROBE_IMAGE" >/dev/null
}

transport_status() {
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$KIND_FEASIBILITY_NAMESPACE" \
    get pod,service,endpointslice \
    --selector app.kubernetes.io/part-of=cn5g-networking \
    -o wide
}

tun_status() {
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$KIND_FEASIBILITY_NAMESPACE" get pods \
    --selector app.kubernetes.io/part-of=cn5g-networking-tun \
    -o wide
}

n6_status() {
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$KIND_FEASIBILITY_NAMESPACE" \
    get pod,service,endpointslice \
    --selector app.kubernetes.io/part-of=cn5g-networking-n6 \
    -o wide
}

wait_for_log_marker() {
  local pod_name=$1
  local container_name=$2
  local marker=$3
  local logs
  for attempt in $(seq 1 30); do
    logs=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" logs "$pod_name" \
      --container "$container_name" 2>/dev/null || true)
    if [[ $logs == *"$marker"* ]]; then
      printf '%s\n' "$logs"
      return 0
    fi
    sleep 1
  done
  printf 'error: marker %s not observed in %s/%s logs\n' \
    "$marker" "$pod_name" "$container_name" >&2
  return 1
}

validate_n6() {
  local data_ip router_ip
  local ue_rx_before ue_tx_before ue_rx_after ue_tx_after
  local ue_rx_delta ue_tx_delta data_log
  local router_cap ue_cap data_cap pod_observer_cap node_observer_cap
  local node_return_route router_node_interface router_node_route
  local -a kubectl_namespace=(
    kubectl --kubeconfig "$kubeconfig"
    --namespace "$KIND_FEASIBILITY_NAMESPACE"
  )

  "${kubectl_namespace[@]}" wait --for=condition=Ready \
    pod/n6-router pod/n6-ue pod/n6-data pod/n6-node-observer \
    --timeout=180s
  data_ip=$("${kubectl_namespace[@]}" get pod n6-data \
    -o jsonpath='{.status.podIP}')
  router_ip=$("${kubectl_namespace[@]}" get pod n6-router \
    -o jsonpath='{.status.podIP}')
  if [[ -z $data_ip || -z $router_ip ]]; then
    printf 'error: N6 probe Pod addresses are incomplete\n' >&2
    return 1
  fi
  printf 'n6_router_pod_ip=%s\n' "$router_ip"
  printf 'n6_data_pod_ip=%s\n' "$data_ip"

  router_node_route=$(docker exec cn5g-control-plane \
    ip -4 route show "$router_ip/32")
  router_node_interface=$(awk '{for (field = 1; field <= NF; field++) {\
    if ($field == "dev") {print $(field + 1); exit}}}' \
    <<<"$router_node_route")
  if [[ -z $router_node_interface || \
        $router_node_route != \
          "$router_ip dev $router_node_interface scope host"* ]]; then
    printf 'error: could not identify the router Pod node-side interface\n' >&2
    printf 'observed_router_node_route=%s\n' \
      "${router_node_route:-<absent>}" >&2
    return 1
  fi
  printf 'n6_router_node_interface=%s\n' "$router_node_interface"

  node_return_route=$(docker exec cn5g-control-plane \
    ip -N -4 route show "$n6_return_subnet")
  if [[ $node_return_route != "$n6_return_subnet via $router_ip "* || \
        $node_return_route != *" dev $router_node_interface "* || \
        $node_return_route != *" proto $n6_return_protocol "* || \
        $node_return_route != *" metric $n6_return_metric "* || \
        $node_return_route != *" onlink"* ]]; then
    printf 'error: kind node N6 return route is absent or unexpected\n' >&2
    printf 'observed_node_return_route=%s\n' \
      "${node_return_route:-<absent>}" >&2
    return 1
  fi
  printf 'kind_node_return_route=%s\n' "$node_return_route"

  "${kubectl_namespace[@]}" exec n6-router --container relay -- \
    sh -ec 'test "$(cat /proc/sys/net/ipv4/ip_forward)" = 1; test "$(cat /sys/class/net/cn5gupf0/mtu)" = 1400; ip -4 address show dev cn5gupf0'
  "${kubectl_namespace[@]}" exec n6-ue --container relay -- \
    sh -ec 'test "$(cat /sys/class/net/cn5gue0/mtu)" = 1400; ip -4 address show dev cn5gue0'
  "${kubectl_namespace[@]}" exec n6-ue --container relay -- \
    ip -4 route get "$data_ip"
  "${kubectl_namespace[@]}" exec n6-data --container endpoint -- \
    ip -4 route get 10.60.0.2

  wait_for_log_marker n6-router pod-observer 'state=ready'
  wait_for_log_marker n6-node-observer observer 'state=ready'

  ue_rx_before=$("${kubectl_namespace[@]}" exec n6-ue --container relay -- \
    cat /sys/class/net/cn5gue0/statistics/rx_packets)
  ue_tx_before=$("${kubectl_namespace[@]}" exec n6-ue --container relay -- \
    cat /sys/class/net/cn5gue0/statistics/tx_packets)
  if ! timeout 30 "${kubectl_namespace[@]}" exec n6-ue \
      --container relay -- cn5g-feasibility-probe \
      tcp-client n6-data 8080 n6-return-route; then
    printf 'error: routed N6 TCP request did not complete within 30 seconds\n' \
      >&2
    return 1
  fi
  ue_rx_after=$("${kubectl_namespace[@]}" exec n6-ue --container relay -- \
    cat /sys/class/net/cn5gue0/statistics/rx_packets)
  ue_tx_after=$("${kubectl_namespace[@]}" exec n6-ue --container relay -- \
    cat /sys/class/net/cn5gue0/statistics/tx_packets)
  ue_rx_delta=$((ue_rx_after - ue_rx_before))
  ue_tx_delta=$((ue_tx_after - ue_tx_before))
  if (( ue_rx_delta <= 0 || ue_tx_delta <= 0 )); then
    printf 'error: bidirectional UE TUN counters did not increase\n' >&2
    printf 'ue_tun_rx_delta=%s\nue_tun_tx_delta=%s\n' \
      "$ue_rx_delta" "$ue_tx_delta" >&2
    return 1
  fi

  data_log=$("${kubectl_namespace[@]}" logs n6-data --container endpoint)
  printf '%s\n' "$data_log"
  if [[ $data_log != *"received=n6-return-route transport=tcp"* ]]; then
    printf 'error: controlled data endpoint did not record the payload\n' >&2
    return 1
  fi
  wait_for_log_marker n6-router pod-observer 'packet_visibility=pass'
  wait_for_log_marker n6-node-observer observer 'packet_visibility=pass'

  router_cap=$("${kubectl_namespace[@]}" exec n6-router --container relay -- \
    sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
  pod_observer_cap=$("${kubectl_namespace[@]}" exec n6-router \
    --container pod-observer -- \
    sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
  ue_cap=$("${kubectl_namespace[@]}" exec n6-ue --container relay -- \
    sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
  data_cap=$("${kubectl_namespace[@]}" exec n6-data --container endpoint -- \
    sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
  node_observer_cap=$("${kubectl_namespace[@]}" exec n6-node-observer \
    --container observer -- \
    sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
  if [[ $router_cap != "0000000000001000" || \
        $ue_cap != "0000000000001000" || \
        $data_cap != "0000000000000000" || \
        $pod_observer_cap != "0000000000002000" || \
        $node_observer_cap != "0000000000002000" ]]; then
    printf 'error: N6 probe capability minimization check failed\n' >&2
    return 1
  fi

  printf 'ue_tun_rx_packet_delta=%s\n' "$ue_rx_delta"
  printf 'ue_tun_tx_packet_delta=%s\n' "$ue_tx_delta"
  printf 'bidirectional_tun_counters=pass\n'
  printf 'synthetic_udp_tunnel=pass\n'
  printf 'n6_return_route=pass\n'
  printf 'data_endpoint_effective_capabilities=%s\n' "$data_cap"
  printf 'pod_network_packet_visibility=pass\n'
  printf 'node_network_packet_visibility=pass\n'
  printf 'n6_net_admin_capability=%s\n' "$router_cap"
  printf 'observer_net_raw_capability=%s\n' "$node_observer_cap"
  printf 'n6_capability_minimization=pass\n'
  printf 'n6_validation=pass\n'
}

validate_tun() {
  local negative_log allowed_capabilities privileged_field
  local -a kubectl_namespace=(
    kubectl --kubeconfig "$kubeconfig"
    --namespace "$KIND_FEASIBILITY_NAMESPACE"
  )

  "${kubectl_namespace[@]}" wait \
    --for=jsonpath='{.status.phase}'=Succeeded pod/tun-denied \
    --timeout=120s
  "${kubectl_namespace[@]}" wait --for=condition=Ready \
    pod/tun-allowed --timeout=120s

  negative_log=$("${kubectl_namespace[@]}" logs tun-denied \
    --container probe)
  printf '%s\n' "$negative_log"
  if [[ $negative_log != *"tun_without_net_admin=denied_as_expected"* ]]; then
    printf 'error: negative TUN capability control did not pass\n' >&2
    return 1
  fi

  "${kubectl_namespace[@]}" exec tun-allowed -- \
    test -c /dev/net/tun
  "${kubectl_namespace[@]}" exec tun-allowed -- \
    ip -details link show dev cn5gtun0
  "${kubectl_namespace[@]}" exec tun-allowed -- \
    ip -4 address show dev cn5gtun0
  allowed_capabilities=$("${kubectl_namespace[@]}" exec tun-allowed -- \
    sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
  if [[ $allowed_capabilities != "0000000000001000" ]]; then
    printf 'error: TUN probe capabilities are not exactly NET_ADMIN\n' >&2
    printf 'observed_capabilities=%s\n' "$allowed_capabilities" >&2
    return 1
  fi
  privileged_field=$("${kubectl_namespace[@]}" get pod tun-allowed \
    -o jsonpath='{.spec.containers[0].securityContext.privileged}')
  if [[ $privileged_field != "false" ]]; then
    printf 'error: TUN probe unexpectedly uses privileged mode\n' >&2
    return 1
  fi
  printf 'tun_device_mount=pass\n'
  printf 'tun_interface=cn5gtun0 address=10.63.0.1/30 state=up\n'
  printf 'tun_effective_capabilities=%s\n' "$allowed_capabilities"
  printf 'tun_privileged_mode=false\n'
  printf 'minimum_tun_capability=pass\n'
  printf 'tun_validation=pass\n'
}

validate_transport() {
  local server_ip service_dns client_capabilities server_capabilities
  local -a kubectl_namespace=(
    kubectl --kubeconfig "$kubeconfig"
    --namespace "$KIND_FEASIBILITY_NAMESPACE"
  )

  "${kubectl_namespace[@]}" wait --for=condition=Ready \
    pod/transport-server pod/transport-client --timeout=120s
  server_ip=$("${kubectl_namespace[@]}" get pod transport-server \
    -o jsonpath='{.status.podIP}')
  if [[ -z $server_ip ]]; then
    printf 'error: transport server has no Pod address\n' >&2
    return 1
  fi
  service_dns="transport-server.${KIND_FEASIBILITY_NAMESPACE}.svc.cluster.local"
  printf 'transport_server_pod_ip=%s\n' "$server_ip"
  printf 'transport_server_service_dns=%s\n' "$service_dns"

  timeout 20 "${kubectl_namespace[@]}" exec transport-client -- \
    cn5g-feasibility-probe tcp-client "$server_ip" 8080 tcp-direct
  timeout 20 "${kubectl_namespace[@]}" exec transport-client -- \
    cn5g-feasibility-probe udp-client "$server_ip" 9091 udp-direct
  timeout 20 "${kubectl_namespace[@]}" exec transport-client -- \
    cn5g-feasibility-probe sctp-client "$server_ip" 38412 n2-sctp-direct
  timeout 20 "${kubectl_namespace[@]}" exec transport-client -- \
    cn5g-feasibility-probe udp-client "$server_ip" 8805 n4-pfcp-port-direct
  timeout 20 "${kubectl_namespace[@]}" exec transport-client -- \
    cn5g-feasibility-probe udp-client "$server_ip" 2152 n3-gtpu-port-direct
  printf 'direct_pod_transport=pass\n'

  timeout 20 "${kubectl_namespace[@]}" exec transport-client -- \
    cn5g-feasibility-probe tcp-client "$service_dns" 8080 tcp-service
  timeout 20 "${kubectl_namespace[@]}" exec transport-client -- \
    cn5g-feasibility-probe udp-client "$service_dns" 9091 udp-service
  timeout 20 "${kubectl_namespace[@]}" exec transport-client -- \
    cn5g-feasibility-probe sctp-client "$service_dns" 38412 n2-sctp-service
  timeout 20 "${kubectl_namespace[@]}" exec transport-client -- \
    cn5g-feasibility-probe udp-client "$service_dns" 8805 n4-pfcp-port-service
  timeout 20 "${kubectl_namespace[@]}" exec transport-client -- \
    cn5g-feasibility-probe udp-client "$service_dns" 2152 n3-gtpu-port-service
  printf 'clusterip_service_transport=pass\n'

  client_capabilities=$("${kubectl_namespace[@]}" exec transport-client -- \
    sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
  server_capabilities=$("${kubectl_namespace[@]}" exec transport-server \
    --container n2-sctp -- \
    sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
  if [[ $client_capabilities != "0000000000000000" || \
        $server_capabilities != "0000000000000000" ]]; then
    printf 'error: an unprivileged transport container retained capabilities\n' >&2
    return 1
  fi
  printf 'transport_client_effective_capabilities=%s\n' "$client_capabilities"
  printf 'transport_server_effective_capabilities=%s\n' "$server_capabilities"
  printf 'unprivileged_transport_security=pass\n'
  printf 'transport_validation=pass\n'
}

case "$action" in
  preflight-image)
    image_preflight
    ;;
  build-image)
    image_preflight
    build_probe_image
    verify_probe_image
    printf 'probe_image_build=pass\n'
    ;;
  rebuild-image-candidate)
    image_preflight
    build_probe_image
    verify_probe_image_structure
    candidate_image_id=$(docker image inspect --format '{{.Id}}' \
      "$KIND_FEASIBILITY_PROBE_IMAGE")
    if [[ $candidate_image_id == "$KIND_FEASIBILITY_PROBE_IMAGE_ID" ]]; then
      printf 'error: corrected source unexpectedly retained the old image ID\n' >&2
      exit 24
    fi
    printf 'candidate_probe_image_id=%s\n' "$candidate_image_id"
    printf 'probe_image_rebuild=identity-review-required\n'
    ;;
  verify-image)
    verify_base_image
    verify_probe_image
    ;;
  load-image)
    require_cluster
    verify_probe_image
    kind load docker-image \
      --name "$KIND_CLUSTER_NAME" \
      "$KIND_FEASIBILITY_PROBE_IMAGE"
    docker exec cn5g-control-plane crictl inspecti \
      "$KIND_FEASIBILITY_PROBE_IMAGE" >/dev/null
    printf 'probe_image_load=pass\n'
    ;;
  verify-load)
    require_cluster
    verify_probe_image
    docker exec cn5g-control-plane crictl inspecti \
      "$KIND_FEASIBILITY_PROBE_IMAGE" >/dev/null
    printf 'node_runtime_image=%s\n' "$KIND_FEASIBILITY_PROBE_IMAGE"
    printf 'probe_image_load_verification=pass\n'
    ;;
  deploy-transport)
    require_cluster
    verify_node_image
    if [[ ! -r $transport_manifest ]]; then
      printf 'error: transport manifest is missing or unreadable\n' >&2
      exit 20
    fi
    existing_resources=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" get all \
      --selector app.kubernetes.io/part-of=cn5g-networking \
      -o name)
    if [[ -n $existing_resources ]]; then
      printf 'error: transport probe resources already exist:\n%s\n' \
        "$existing_resources" >&2
      exit 21
    fi
    kubectl --kubeconfig "$kubeconfig" apply --filename "$transport_manifest"
    kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" wait \
      --for=condition=Ready pod/transport-server pod/transport-client \
      --timeout=120s
    transport_status
    printf 'transport_probe_deployment=pass\n'
    ;;
  status-transport)
    require_cluster
    transport_status
    ;;
  validate-transport)
    require_cluster
    validate_transport
    ;;
  cleanup-transport)
    if [[ $confirmation != "--confirm" ]]; then
      printf 'error: cleanup-transport requires --confirm\n' >&2
      exit 22
    fi
    require_cluster
    kubectl --kubeconfig "$kubeconfig" delete \
      --filename "$transport_manifest" --ignore-not-found=true
    kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" wait --for=delete pod \
      --selector app.kubernetes.io/part-of=cn5g-networking \
      --timeout=120s
    remaining_resources=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" get all \
      --selector app.kubernetes.io/part-of=cn5g-networking \
      -o name)
    if [[ -n $remaining_resources ]]; then
      printf 'error: transport resources remain:\n%s\n' \
        "$remaining_resources" >&2
      exit 23
    fi
    printf 'transport_probe_cleanup=pass\n'
    ;;
  deploy-tun)
    require_cluster
    verify_node_image
    if [[ ! -r $tun_manifest ]]; then
      printf 'error: TUN manifest is missing or unreadable\n' >&2
      exit 25
    fi
    existing_tun_pods=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" get pods \
      --selector app.kubernetes.io/part-of=cn5g-networking-tun \
      -o name)
    if [[ -n $existing_tun_pods ]]; then
      printf 'error: TUN probe Pods already exist:\n%s\n' \
        "$existing_tun_pods" >&2
      exit 26
    fi
    kubectl --kubeconfig "$kubeconfig" apply --filename "$tun_manifest"
    kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" wait \
      --for=jsonpath='{.status.phase}'=Succeeded pod/tun-denied \
      --timeout=120s
    kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" wait \
      --for=condition=Ready pod/tun-allowed --timeout=120s
    tun_status
    printf 'tun_probe_deployment=pass\n'
    ;;
  status-tun)
    require_cluster
    tun_status
    ;;
  validate-tun)
    require_cluster
    validate_tun
    ;;
  cleanup-tun)
    if [[ $confirmation != "--confirm" ]]; then
      printf 'error: cleanup-tun requires --confirm\n' >&2
      exit 27
    fi
    require_cluster
    kubectl --kubeconfig "$kubeconfig" delete \
      --filename "$tun_manifest" --ignore-not-found=true
    kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" wait --for=delete pod \
      --selector app.kubernetes.io/part-of=cn5g-networking-tun \
      --timeout=120s
    remaining_tun_pods=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" get pods \
      --selector app.kubernetes.io/part-of=cn5g-networking-tun \
      -o name)
    if [[ -n $remaining_tun_pods ]]; then
      printf 'error: TUN probe Pods remain:\n%s\n' \
        "$remaining_tun_pods" >&2
      exit 28
    fi
    printf 'tun_probe_cleanup=pass\n'
    ;;
  deploy-n6)
    require_cluster
    verify_node_image
    if [[ ! -r $n6_manifest ]]; then
      printf 'error: N6 manifest is missing or unreadable\n' >&2
      exit 29
    fi
    node_forwarding=$(docker exec cn5g-control-plane \
      cat /proc/sys/net/ipv4/ip_forward)
    if [[ $node_forwarding != "1" ]]; then
      printf 'error: kind node IPv4 forwarding is not enabled\n' >&2
      exit 29
    fi
    printf 'kind_node_ipv4_forwarding=%s\n' "$node_forwarding"
    existing_n6_resources=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" get all \
      --selector app.kubernetes.io/part-of=cn5g-networking-n6 \
      -o name)
    if [[ -n $existing_n6_resources ]]; then
      printf 'error: N6 probe resources already exist:\n%s\n' \
        "$existing_n6_resources" >&2
      exit 30
    fi
    existing_n6_return_route=$(docker exec cn5g-control-plane \
      ip -N -4 route show "$n6_return_subnet")
    if [[ -n $existing_n6_return_route ]]; then
      printf 'error: refusing to overwrite existing kind node route: %s\n' \
        "$existing_n6_return_route" >&2
      exit 30
    fi
    kubectl --kubeconfig "$kubeconfig" apply --filename "$n6_manifest"
    kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" wait \
      --for=condition=Ready pod/n6-router --timeout=180s
    n6_router_ip=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" get pod n6-router \
      -o jsonpath='{.status.podIP}')
    if [[ -z $n6_router_ip ]]; then
      printf 'error: N6 router Pod address is unavailable\n' >&2
      exit 30
    fi
    n6_router_node_route=$(docker exec cn5g-control-plane \
      ip -4 route show "$n6_router_ip/32")
    n6_router_node_interface=$(awk '{for (field = 1; field <= NF; field++) {\
      if ($field == "dev") {print $(field + 1); exit}}}' \
      <<<"$n6_router_node_route")
    if [[ -z $n6_router_node_interface || \
          $n6_router_node_route != \
          "$n6_router_ip dev $n6_router_node_interface scope host"* ]]; then
      printf 'error: could not identify the router Pod node-side interface\n' \
        >&2
      printf 'observed_router_node_route=%s\n' \
        "${n6_router_node_route:-<absent>}" >&2
      exit 30
    fi
    printf 'n6_router_node_interface=%s\n' "$n6_router_node_interface"
    docker exec cn5g-control-plane ip -4 route add "$n6_return_subnet" \
      via "$n6_router_ip" dev "$n6_router_node_interface" onlink \
      proto "$n6_return_protocol" metric "$n6_return_metric"
    printf 'kind_node_return_route=%s via %s dev %s proto %s metric %s onlink\n' \
      "$n6_return_subnet" "$n6_router_ip" "$n6_router_node_interface" \
      "$n6_return_protocol" "$n6_return_metric"
    kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" wait \
      --for=condition=Ready pod/n6-ue pod/n6-data pod/n6-node-observer \
      --timeout=180s
    n6_status
    printf 'n6_probe_deployment=pass\n'
    ;;
  status-n6)
    require_cluster
    n6_status
    ;;
  validate-n6)
    require_cluster
    validate_n6
    ;;
  cleanup-n6)
    if [[ $confirmation != "--confirm" ]]; then
      printf 'error: cleanup-n6 requires --confirm\n' >&2
      exit 31
    fi
    require_cluster
    existing_n6_return_route=$(docker exec cn5g-control-plane \
      ip -N -4 route show "$n6_return_subnet")
    if [[ -n $existing_n6_return_route ]]; then
      if [[ $existing_n6_return_route != \
              "$n6_return_subnet via 10.244."* || \
            $existing_n6_return_route != *" dev veth"* || \
            $existing_n6_return_route != *" proto $n6_return_protocol "* || \
            $existing_n6_return_route != *" metric $n6_return_metric "* || \
            $existing_n6_return_route != *" onlink"* ]]; then
        printf 'error: refusing to remove unrecognized kind node route: %s\n' \
          "$existing_n6_return_route" >&2
        exit 31
      fi
      docker exec cn5g-control-plane ip -4 route del "$n6_return_subnet" \
        proto "$n6_return_protocol" metric "$n6_return_metric"
      printf 'kind_node_return_route=removed\n'
    else
      printf 'kind_node_return_route=absent\n'
    fi
    kubectl --kubeconfig "$kubeconfig" delete \
      --filename "$n6_manifest" --ignore-not-found=true
    kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" wait --for=delete pod \
      --selector app.kubernetes.io/part-of=cn5g-networking-n6 \
      --timeout=180s
    remaining_n6_resources=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$KIND_FEASIBILITY_NAMESPACE" get all \
      --selector app.kubernetes.io/part-of=cn5g-networking-n6 \
      -o name)
    if [[ -n $remaining_n6_resources ]]; then
      printf 'error: N6 resources remain:\n%s\n' \
        "$remaining_n6_resources" >&2
      exit 32
    fi
    printf 'n6_probe_cleanup=pass\n'
    ;;
esac
