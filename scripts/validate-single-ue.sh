#!/usr/bin/env bash

set -Eeuo pipefail

if (( EUID != 0 )) || [[ -z ${SUDO_UID:-} || -z ${SUDO_GID:-} ]]; then
  printf 'error: run this validator through sudo from the normal account\n' >&2
  exit 3
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(cd -- "$script_dir/.." && pwd -P)
if [[ ${project_root##*/} != "cloud-native-5g-core-platform" ]]; then
  printf 'error: refusing to run outside the expected repository\n' >&2
  exit 3
fi

# shellcheck source=../versions/kubernetes-runtime.env
source "$project_root/versions/kubernetes-runtime.env"
# shellcheck source=../versions/platform-runtime.env
source "$project_root/versions/platform-runtime.env"

kubeconfig="$project_root/artifacts/kubernetes/cn5g.kubeconfig"
namespace=$CN5G_KUBERNETES_NAMESPACE
release=$CN5G_HELM_RELEASE_NAME
node_container="${KIND_CLUSTER_NAME}-control-plane"

for required_command in docker helm jq kubectl; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'error: required command is unavailable: %s\n' \
      "$required_command" >&2
    exit 4
  fi
done

if [[ ! -r $kubeconfig || -L $kubeconfig ]]; then
  printf 'error: project kubeconfig is absent or unsafe: %s\n' \
    "$kubeconfig" >&2
  exit 4
fi

kubectl_namespace=(
  kubectl --kubeconfig "$kubeconfig" --namespace "$namespace"
)

release_json=$(helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
  status "$release" --output json)
release_status=$(jq -er '.info.status' <<<"$release_json")
if [[ $release_status != "deployed" ]]; then
  printf 'error: Helm release is not deployed: %s\n' "$release_status" >&2
  exit 20
fi
printf 'helm_release_status=deployed\n'

not_ready=$(
  "${kubectl_namespace[@]}" get deployments \
    --selector "app.kubernetes.io/instance=${release}" --output json |
    jq -r '.items[] | select(
      (.spec.replicas != 1) or
      ((.status.observedGeneration // 0) < .metadata.generation) or
      ((.status.updatedReplicas // 0) != 1) or
      ((.status.availableReplicas // 0) != 1)
    ) | .metadata.name'
)
if [[ -n $not_ready ]]; then
  printf 'error: one or more Deployments are not converged:\n%s\n' \
    "$not_ready" >&2
  exit 21
fi
"${kubectl_namespace[@]}" rollout status \
  "statefulset/${release}-mongodb" --timeout=120s >/dev/null
printf 'kubernetes_workload_readiness=pass\n'

subscriber_count=$("${kubectl_namespace[@]}" exec \
  "statefulset/${release}-mongodb" --container mongodb -- \
  mongosh --quiet open5gs --eval 'db.subscribers.countDocuments({})')
if [[ $subscriber_count != "1" ]]; then
  printf 'error: expected one synthetic subscriber, found %s\n' \
    "$subscriber_count" >&2
  exit 22
fi
printf 'subscriber_record=pass\n'

gnb_logs=$("${kubectl_namespace[@]}" logs \
  "deployment/${release}-gnb" --container gnb --tail=300)
if [[ $gnb_logs != *"SCTP connection established"* || \
      $gnb_logs != *"NG Setup procedure is successful"* ]]; then
  printf 'error: gNB SCTP/NG Setup evidence is incomplete\n' >&2
  exit 23
fi
printf 'n2_sctp_association=pass\nng_setup=pass\n'

ue_logs=$("${kubectl_namespace[@]}" logs \
  "deployment/${release}-ue" --container ue --tail=400)
for marker in \
  "Authentication Request received" \
  "Security Mode Command received" \
  "Initial Registration is successful" \
  "PDU Session establishment is successful"; do
  if [[ $ue_logs != *"$marker"* ]]; then
    printf 'error: UE log marker is absent: %s\n' "$marker" >&2
    exit 24
  fi
done
printf '5g_aka_authentication=pass\n'
printf 'nas_security=pass\n'
printf 'registration=pass\n'
printf 'pdu_session=pass\n'

ue_address=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-ue" --container ue -- sh -ec \
  "ip -o -4 address show dev uesimtun0 | awk '{print \$4}'")
case "$ue_address" in
  10.60.0.*\/24) ;;
  *)
    printf 'error: unexpected UE tunnel address: %s\n' "$ue_address" >&2
    exit 25
    ;;
esac
ue_ip=${ue_address%/*}
printf 'ue_tunnel_address=%s\n' "$ue_address"

upf_logs=$("${kubectl_namespace[@]}" logs \
  "deployment/${release}-upf" --container upf --tail=300)
if [[ $upf_logs != *"PFCP associated"* || \
      $upf_logs != *"[Added] Number of UPF-Sessions is now 1"* || \
      $upf_logs != *"gtp_connect()"* ]]; then
  printf 'error: UPF PFCP/GTP-U session evidence is incomplete\n' >&2
  exit 26
fi
printf 'pfcp_association=pass\n'
printf 'pfcp_session=pass\n'
printf 'gtpu_session=pass\n'

upf_ip=$("${kubectl_namespace[@]}" get pod \
  --selector "app.kubernetes.io/component=upf,app.kubernetes.io/instance=${release}" \
  --output json | jq -er '
    [.items[] | select(.status.phase == "Running") | .status.podIP] |
    if length == 1 then .[0] else error("expected one running UPF Pod") end
  ')
data_ip=$("${kubectl_namespace[@]}" get pod \
  --selector "app.kubernetes.io/component=data-network,app.kubernetes.io/instance=${release}" \
  --output json | jq -er '
    [.items[] | select(.status.phase == "Running") | .status.podIP] |
    if length == 1 then .[0] else error("expected one running data-network Pod") end
  ')
printf 'upf_pod_ip=%s\n' "$upf_ip"
printf 'data_network_pod_ip=%s\n' "$data_ip"

upf_node_route=$(docker exec "$node_container" \
  ip -4 route show "$upf_ip/32")
upf_node_interface=$(awk '{for (field = 1; field <= NF; field++) {
  if ($field == "dev") {print $(field + 1); exit}}}' \
  <<<"$upf_node_route")
if [[ -z $upf_node_interface || \
      $upf_node_route != "$upf_ip dev $upf_node_interface scope host"* ]]; then
  printf 'error: UPF node-side interface could not be identified\n' >&2
  printf 'observed_upf_node_route=%s\n' \
    "${upf_node_route:-<absent>}" >&2
  exit 27
fi

node_return_route=$(docker exec "$node_container" \
  ip -N -4 route show "$CN5G_N6_RETURN_SUBNET")
if [[ $node_return_route != "$CN5G_N6_RETURN_SUBNET via $upf_ip "* || \
      $node_return_route != *" dev $upf_node_interface "* || \
      $node_return_route != *" proto $CN5G_N6_RETURN_PROTOCOL "* || \
      $node_return_route != *" metric $CN5G_N6_RETURN_METRIC "* || \
      $node_return_route != *" onlink"* ]]; then
  printf 'error: kind node N6 return route is absent or unexpected\n' >&2
  printf 'observed_node_return_route=%s\n' \
    "${node_return_route:-<absent>}" >&2
  exit 27
fi
printf 'kind_node_return_route=%s\n' "$node_return_route"

"${kubectl_namespace[@]}" exec "deployment/${release}-upf" \
  --container upf -- sh -ec \
  'test "$(cat /proc/sys/net/ipv4/ip_forward)" = 1; ip -4 address show dev ogstun | grep -Fq "10.60.0.1/24"'
data_return_lookup=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-data-network" --container data-network -- \
  ip -4 route get "$ue_ip")
if [[ $data_return_lookup != *" dev eth0 "* ]]; then
  printf 'error: data-network return lookup does not use the Pod network\n' >&2
  printf 'observed_data_return_lookup=%s\n' "$data_return_lookup" >&2
  exit 28
fi
printf 'n6_return_route=pass\n'

ue_rx_before=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-ue" --container ue -- \
  cat /sys/class/net/uesimtun0/statistics/rx_packets)
ue_tx_before=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-ue" --container ue -- \
  cat /sys/class/net/uesimtun0/statistics/tx_packets)
upf_rx_before=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-upf" --container upf -- \
  cat /sys/class/net/ogstun/statistics/rx_packets)
upf_tx_before=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-upf" --container upf -- \
  cat /sys/class/net/ogstun/statistics/tx_packets)

http_result=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-ue" --container ue -- \
  curl --fail --silent --show-error --interface uesimtun0 --max-time 15 \
  "http://${data_ip}:8080/healthz")
if [[ $http_result != "cn5g-data-network-ok" ]]; then
  printf 'error: controlled endpoint returned: %s\n' "$http_result" >&2
  exit 29
fi
printf 'http_user_plane=pass\n'

"${kubectl_namespace[@]}" exec "deployment/${release}-ue" \
  --container ue -- ping -I uesimtun0 -c 3 -W 2 "$data_ip" >/dev/null
printf 'icmp_user_plane=pass\n'

ue_rx_after=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-ue" --container ue -- \
  cat /sys/class/net/uesimtun0/statistics/rx_packets)
ue_tx_after=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-ue" --container ue -- \
  cat /sys/class/net/uesimtun0/statistics/tx_packets)
upf_rx_after=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-upf" --container upf -- \
  cat /sys/class/net/ogstun/statistics/rx_packets)
upf_tx_after=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-upf" --container upf -- \
  cat /sys/class/net/ogstun/statistics/tx_packets)

ue_rx_delta=$((ue_rx_after - ue_rx_before))
ue_tx_delta=$((ue_tx_after - ue_tx_before))
upf_rx_delta=$((upf_rx_after - upf_rx_before))
upf_tx_delta=$((upf_tx_after - upf_tx_before))
if (( ue_rx_delta <= 0 || ue_tx_delta <= 0 || \
      upf_rx_delta <= 0 || upf_tx_delta <= 0 )); then
  printf 'error: bidirectional tunnel counters did not all increase\n' >&2
  printf 'ue_rx=%s ue_tx=%s upf_rx=%s upf_tx=%s\n' \
    "$ue_rx_delta" "$ue_tx_delta" "$upf_rx_delta" "$upf_tx_delta" >&2
  exit 30
fi
printf 'ue_tunnel_rx_packet_delta=%s\n' "$ue_rx_delta"
printf 'ue_tunnel_tx_packet_delta=%s\n' "$ue_tx_delta"
printf 'upf_tunnel_rx_packet_delta=%s\n' "$upf_rx_delta"
printf 'upf_tunnel_tx_packet_delta=%s\n' "$upf_tx_delta"
printf 'bidirectional_tunnel_counters=pass\n'
printf 'gtpu_user_plane=pass\n'

upf_cap=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-upf" --container upf -- \
  sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
ue_cap=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-ue" --container ue -- \
  sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
data_cap=$("${kubectl_namespace[@]}" exec \
  "deployment/${release}-data-network" --container data-network -- \
  sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
if [[ $upf_cap != "0000000000001000" || \
      $ue_cap != "0000000000003000" || \
      $data_cap != "0000000000000000" ]]; then
  printf 'error: effective network capabilities exceed the accepted contract\n' \
    >&2
  printf 'upf=%s ue=%s data_network=%s\n' \
    "$upf_cap" "$ue_cap" "$data_cap" >&2
  exit 31
fi
printf 'upf_effective_capabilities=%s\n' "$upf_cap"
printf 'ue_effective_capabilities=%s\n' "$ue_cap"
printf 'data_network_effective_capabilities=%s\n' "$data_cap"
printf 'capability_minimization=pass\n'
printf 'kubernetes_validation=pass\n'
