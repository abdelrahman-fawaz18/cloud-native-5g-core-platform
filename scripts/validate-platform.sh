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
plan="$project_root/configs/kubernetes/platform/subscriber-plan.json"
namespace=$CN5G_KUBERNETES_NAMESPACE
release=$CN5G_HELM_RELEASE_NAME
node_container="${KIND_CLUSTER_NAME}-control-plane"

for required_command in awk curl docker grep helm jq kubectl sed seq sort wc; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'error: required command is unavailable: %s\n' "$required_command" >&2
    exit 4
  fi
done
for required_file in "$kubeconfig" "$plan"; do
  if [[ ! -r $required_file || -L $required_file ]]; then
    printf 'error: required file is absent or unsafe: %s\n' "$required_file" >&2
    exit 4
  fi
done

kubectl_namespace=(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace")

component_pod_ip() {
  local component=$1
  "${kubectl_namespace[@]}" get pod \
    --selector "app.kubernetes.io/component=${component},app.kubernetes.io/instance=${release}" \
    --output json | jq -er '
      [.items[] | select(.status.phase == "Running") | .status.podIP] |
      if length == 1 then .[0] else error("expected one running component Pod") end'
}

verify_runtime_sbi_advertisements() {
  local component expected
  for component in nrf scp amf ausf udm udr pcf nssf smf; do
    expected="advertise: ${release}-${component}.${namespace}.svc.cluster.local"
    if ! "${kubectl_namespace[@]}" exec "deployment/${release}-${component}" \
        --container "$component" -- grep -Fq "$expected" \
        "/etc/open5gs/${component}.yaml"; then
      printf 'error: stable SBI advertisement is absent: %s\n' "$component" >&2
      return 1
    fi
  done
  printf 'stable_sbi_advertisements=pass\n'
}

get_nrf_collection() {
  "${kubectl_namespace[@]}" exec "deployment/${release}-nrf" --container nrf -- \
    curl --http2-prior-knowledge --fail --silent --show-error \
    "http://${release}-nrf:7777/nnrf-nfm/v1/nf-instances"
}

nrf_collection_count() {
  local collection=$1 count
  if count=$(jq -er '
      ._links.totalItemCount // 0 |
      if type == "number" and . >= 0 and floor == . then tostring
      else error("invalid NRF profile count") end
    ' <<<"$collection" 2>/dev/null); then
    printf '%s\n' "$count"
  else
    printf '0\n'
  fi
}

verify_nrf_profiles() {
  local collection count attempt profile_url profile_json nf_type
  local expected_fqdn observed_fqdn stale_address
  local -a profile_urls
  for attempt in $(seq 1 45); do
    collection=$(get_nrf_collection 2>/dev/null || true)
    count=$(nrf_collection_count "${collection:-}")
    [[ $count == "9" ]] && break
    sleep 2
  done
  if [[ ${count:-0} != "9" ]]; then
    printf 'error: NRF did not converge to nine registered SBI profiles\n' >&2
    return 1
  fi
  mapfile -t profile_urls < <(jq -er '._links.item[].href' <<<"$collection")
  if [[ ${#profile_urls[@]} -ne 9 ]]; then
    printf 'error: NRF profile URL count is unexpected\n' >&2
    return 1
  fi
  for profile_url in "${profile_urls[@]}"; do
    profile_json=$("${kubectl_namespace[@]}" exec \
      "deployment/${release}-nrf" --container nrf -- \
      curl --http2-prior-knowledge --fail --silent --show-error "$profile_url")
    nf_type=$(jq -er '.nfType' <<<"$profile_json")
    expected_fqdn="${release}-${nf_type,,}.${namespace}.svc.cluster.local"
    observed_fqdn=$(jq -r '.fqdn // ""' <<<"$profile_json")
    stale_address=$(jq -r '
      [.ipv4Addresses[]?, .nfServiceList[]?.ipEndPoints[]?.ipv4Address] |
      map(select(startswith("10.244."))) | length' <<<"$profile_json")
    if [[ $observed_fqdn != "$expected_fqdn" || $stale_address != "0" ]]; then
      printf 'error: NRF profile uses an unstable endpoint: %s\n' "$nf_type" >&2
      return 1
    fi
  done
  printf 'nrf_stable_service_profiles=pass count=9\n'
}

release_json=$(helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
  status "$release" --output json)
release_status=$(jq -er '.info.status' <<<"$release_json")
if [[ $release_status != "deployed" ]]; then
  printf 'error: Helm release is not deployed: %s\n' "$release_status" >&2
  exit 20
fi
platform_enabled=$(helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get values "$release" --all --output json | jq -er '.platform.enabled')
if [[ $platform_enabled != "true" ]]; then
  printf 'error: deployed release is not using the platform topology\n' >&2
  exit 20
fi
printf 'helm_release_status=deployed\nplatform_topology=enabled\n'

not_ready=$("${kubectl_namespace[@]}" get deployments \
  --selector "app.kubernetes.io/instance=${release}" --output json | jq -r '
    .items[] | select(
      (.spec.replicas != 1) or
      ((.status.observedGeneration // 0) < .metadata.generation) or
      ((.status.updatedReplicas // 0) != 1) or
      ((.status.availableReplicas // 0) != 1)
    ) | .metadata.name')
if [[ -n $not_ready ]]; then
  printf 'error: one or more Deployments are not converged:\n%s\n' "$not_ready" >&2
  exit 21
fi
"${kubectl_namespace[@]}" rollout status \
  "statefulset/${release}-mongodb" --timeout=180s >/dev/null
"${kubectl_namespace[@]}" rollout status \
  "statefulset/${release}-ue" --timeout=300s >/dev/null
ue_state=$("${kubectl_namespace[@]}" get statefulset "${release}-ue" --output json)
if [[ $(jq -er '.spec.replicas' <<<"$ue_state") != "5" || \
      $(jq -er '.status.readyReplicas // 0' <<<"$ue_state") != "5" || \
      $(jq -er '.status.currentReplicas // 0' <<<"$ue_state") != "5" ]]; then
  printf 'error: five-UE StatefulSet is not fully converged\n' >&2
  exit 21
fi
printf 'kubernetes_workload_readiness=pass\nconcurrent_ue_pods=5\n'

verify_runtime_sbi_advertisements
verify_nrf_profiles

subscriber_count=$("${kubectl_namespace[@]}" exec \
  "statefulset/${release}-mongodb" --container mongodb -- mongosh --quiet \
  open5gs --eval 'db.subscribers.countDocuments({"cn5g_managed.topology":"multi-ue"})')
total_subscriber_count=$("${kubectl_namespace[@]}" exec \
  "statefulset/${release}-mongodb" --container mongodb -- mongosh --quiet \
  open5gs --eval 'db.subscribers.countDocuments({})')
if [[ $subscriber_count != "5" || $total_subscriber_count != "5" ]]; then
  printf 'error: subscriber database does not contain exactly five managed records\n' >&2
  printf 'managed=%s total=%s\n' "$subscriber_count" "$total_subscriber_count" >&2
  exit 22
fi
printf 'subscriber_records=pass count=5\n'

gnb_logs=$("${kubectl_namespace[@]}" logs \
  "deployment/${release}-gnb" --container gnb --tail=1000)
if [[ $gnb_logs != *"SCTP connection established"* || \
      $gnb_logs != *"NG Setup procedure is successful"* ]]; then
  printf 'error: gNB SCTP/NG Setup evidence is incomplete\n' >&2
  exit 23
fi
printf 'n2_sctp_association=pass\nng_setup=pass\n'

upf_logs=$("${kubectl_namespace[@]}" logs \
  "deployment/${release}-upf" --container upf --tail=3000)
smf_logs=$("${kubectl_namespace[@]}" logs \
  "deployment/${release}-smf" --container smf --tail=3000)
if [[ $upf_logs != *"PFCP associated"* || \
      $upf_logs != *"[Added] Number of UPF-Sessions is now 5"* || \
      $upf_logs != *"gtp_connect()"* ]]; then
  printf 'error: UPF does not expose five complete PFCP/GTP-U sessions\n' >&2
  exit 24
fi
if [[ $upf_logs == *"Cannot find PFCP-Node"* || \
      $smf_logs == *"No PFCP session establishment response"* || \
      $smf_logs == *"No PFCP session modification response"* ]]; then
  printf 'error: PFCP peer identity or session programming is incomplete\n' >&2
  exit 24
fi
printf 'pfcp_control_plane_health=pass\n'

# A StatefulSet rolling update replaces one UE session at a time. Open5GS
# retains both the removed session's historical INFO line and the replacement
# session's line in the same container log. Keep only the newest record for
# each address so uniqueness describes current UE assignments rather than the
# accumulated log history.
latest_fseid_rows=$(sed -n \
  's/.*UE F-SEID\[UP:\([^ ]*\) CP:\([^]]*\)\].*APN\[\([^]]*\)\].*IPv4\[\([^]]*\)\].*/\1 \2 \3 \4/p' \
  <<<"$upf_logs" | awk '{latest[$4] = $0} END {for (ip in latest) print latest[ip]}' | \
  sort -k4,4)

internet_ip=$(component_pod_ip data-internet)
enterprise_ip=$(component_pod_ip data-enterprise)
upf_ip=$(component_pod_ip upf)
upf_rules=$("${kubectl_namespace[@]}" exec "deployment/${release}-upf" \
  --container upf -- ip -4 rule show)
internet_table=$("${kubectl_namespace[@]}" exec "deployment/${release}-upf" \
  --container upf -- ip -4 route show table 1060)
enterprise_table=$("${kubectl_namespace[@]}" exec "deployment/${release}-upf" \
  --container upf -- ip -4 route show table 1061)
if [[ $upf_rules != *"1060:"*"from 10.60.0.0/24 lookup 1060"* || \
      $upf_rules != *"1061:"*"from 10.61.0.0/24 lookup 1061"* || \
      $internet_table != *"${internet_ip} via "*" dev eth0"* || \
      $internet_table != *"unreachable default"* || \
      $internet_table == *"${enterprise_ip} via "* || \
      $enterprise_table != *"${enterprise_ip} via "*" dev eth0"* || \
      $enterprise_table != *"unreachable default"* || \
      $enterprise_table == *"${internet_ip} via "* ]]; then
  printf 'error: UPF source-policy routing does not match the two-DNN contract\n' >&2
  exit 24
fi
for subnet_metric in "10.60.0.0/24:46060" "10.61.0.0/24:46061"; do
  subnet=${subnet_metric%:*}
  metric=${subnet_metric##*:}
  node_route=$(docker exec "$node_container" ip -N -4 route show "$subnet")
  if [[ $node_route != "$subnet via $upf_ip dev veth"* || \
        $node_route != *" proto 186 "* || \
        $node_route != *" metric $metric "* || \
        $node_route != *" onlink"* ]]; then
    printf 'error: kind-node return route is absent or unexpected: %s\n' \
      "$subnet" >&2
    exit 24
  fi
done
printf 'upf_dnn_policy_routing=pass tables=1060,1061\n'
printf 'kind_node_dual_return_routes=pass\n'

declare -a observed_addresses=()
declare -a ue_rx_before=()
declare -a ue_tx_before=()
printf 'per_ue_results_begin\n'
printf 'ordinal pod dnn tunnel_address registration pdu intended_endpoint cross_dnn\n'
for ordinal in 0 1 2 3 4; do
  pod="${release}-ue-${ordinal}"
  expected_imsi=$(jq -er ".subscribers[] | select(.ordinal == ${ordinal}) | .imsi" "$plan")
  dnn=$(jq -er ".subscribers[] | select(.ordinal == ${ordinal}) | .dnn" "$plan")
  runtime_imsi=$("${kubectl_namespace[@]}" exec "$pod" --container ue -- \
    sed -n "s/^supi: 'imsi-\([0-9][0-9]*\)'$/\1/p" \
    /etc/ueransim/ue.yaml)
  runtime_dnn=$("${kubectl_namespace[@]}" exec "$pod" --container ue -- \
    sed -n "s/^    apn: '\([^']*\)'$/\1/p" /etc/ueransim/ue.yaml)
  if [[ $runtime_imsi != "$expected_imsi" || $runtime_dnn != "$dnn" ]]; then
    printf 'error: Pod ordinal does not match the tracked identity plan: %s\n' "$pod" >&2
    exit 25
  fi
  logs=$("${kubectl_namespace[@]}" logs "$pod" --container ue --tail=800)
  for marker in \
    "Authentication Request received" \
    "Security Mode Command received" \
    "Initial Registration is successful" \
    "PDU Session establishment is successful"; do
    if [[ $logs != *"$marker"* ]]; then
      printf 'error: %s is missing protocol marker: %s\n' "$pod" "$marker" >&2
      exit 25
    fi
  done
  address=$("${kubectl_namespace[@]}" exec "$pod" --container ue -- sh -ec \
    "ip -o -4 address show dev uesimtun0 | awk '{print \$4}'")
  case "$dnn:$address" in
    internet:10.60.0.*\/24) intended_component=data-internet; cross_component=data-enterprise ;;
    enterprise:10.61.0.*\/24) intended_component=data-enterprise; cross_component=data-internet ;;
    *)
      printf 'error: %s received an address outside its DNN pool: %s %s\n' \
        "$pod" "$dnn" "$address" >&2
      exit 26
      ;;
  esac
  ue_ip=${address%/*}
  observed_addresses+=("$ue_ip")
  if ! awk -v expected_dnn="$dnn" -v expected_ip="$ue_ip" '
      $3 == expected_dnn && $4 == expected_ip {found = 1}
      END {exit !found}
    ' <<<"$latest_fseid_rows"; then
    printf 'error: UPF session does not correlate %s with %s\n' "$dnn" "$ue_ip" >&2
    exit 27
  fi
  intended_ip=$(component_pod_ip "$intended_component")
  cross_ip=$(component_pod_ip "$cross_component")
  route_lookup=$("${kubectl_namespace[@]}" exec "$pod" --container ue -- \
    ip -4 route get "$intended_ip" from "$ue_ip")
  if [[ $route_lookup != *"from $ue_ip dev uesimtun0 table rt_uesimtun0"* ]]; then
    printf 'error: intended endpoint route does not use the UE TUN: %s\n' "$pod" >&2
    exit 28
  fi
  ue_rx_before[$ordinal]=$("${kubectl_namespace[@]}" exec "$pod" --container ue -- \
    cat /sys/class/net/uesimtun0/statistics/rx_packets)
  ue_tx_before[$ordinal]=$("${kubectl_namespace[@]}" exec "$pod" --container ue -- \
    cat /sys/class/net/uesimtun0/statistics/tx_packets)
  response=$("${kubectl_namespace[@]}" exec "$pod" --container ue -- \
    curl --fail --silent --show-error --interface uesimtun0 --max-time 15 \
    "http://${intended_ip}:8080/")
  if [[ $response != "cn5g-dnn=${dnn}" ]]; then
    printf 'error: %s reached the wrong endpoint identity: %s\n' "$pod" "$response" >&2
    exit 29
  fi
  "${kubectl_namespace[@]}" exec "$pod" --container ue -- \
    ping -I uesimtun0 -c 2 -W 2 "$intended_ip" >/dev/null
  if "${kubectl_namespace[@]}" exec "$pod" --container ue -- \
      curl --fail --silent --interface uesimtun0 --connect-timeout 2 \
      --max-time 4 "http://${cross_ip}:8080/" >/dev/null 2>&1; then
    printf 'error: cross-DNN endpoint was reachable from %s\n' "$pod" >&2
    exit 30
  fi
  printf '%s %s %s %s pass pass pass denied\n' \
    "$ordinal" "$pod" "$dnn" "$address"
done
printf 'per_ue_results_end\n'

unique_address_count=$(printf '%s\n' "${observed_addresses[@]}" | sort -u | wc -l)
if [[ $unique_address_count != "5" ]]; then
  printf 'error: UE tunnel address collision detected\n' >&2
  exit 31
fi
fseid_rows=''
for ue_ip in "${observed_addresses[@]}"; do
  row=$(awk -v expected_ip="$ue_ip" '$4 == expected_ip {print}' \
    <<<"$latest_fseid_rows")
  if [[ $(sed '/^$/d' <<<"$row" | wc -l) != "1" ]]; then
    printf 'error: current UPF session evidence is ambiguous: %s\n' "$ue_ip" >&2
    exit 31
  fi
  fseid_rows+="${row}"$'\n'
done
fseid_address_count=$(awk '{print $4}' <<<"$fseid_rows" | sort -u | sed '/^$/d' | wc -l)
fseid_up_count=$(awk '{print $1}' <<<"$fseid_rows" | sort -u | sed '/^$/d' | wc -l)
fseid_cp_count=$(awk '{print $2}' <<<"$fseid_rows" | sort -u | sed '/^$/d' | wc -l)
if [[ $fseid_address_count != "5" || $fseid_up_count != "5" || $fseid_cp_count != "5" ]]; then
  printf 'error: F-SEID/address correlation is incomplete or colliding\n' >&2
  printf 'addresses=%s up_fseid=%s cp_fseid=%s\n' \
    "$fseid_address_count" "$fseid_up_count" "$fseid_cp_count" >&2
  exit 31
fi
printf 'ue_address_uniqueness=pass count=5\n'
printf 'fseid_uniqueness=pass up=5 cp=5\n'
printf 'concurrent_session_collision_symptoms=absent\n'

for ordinal in 0 1 2 3 4; do
  pod="${release}-ue-${ordinal}"
  ue_rx_after=$("${kubectl_namespace[@]}" exec "$pod" --container ue -- \
    cat /sys/class/net/uesimtun0/statistics/rx_packets)
  ue_tx_after=$("${kubectl_namespace[@]}" exec "$pod" --container ue -- \
    cat /sys/class/net/uesimtun0/statistics/tx_packets)
  rx_delta=$((ue_rx_after - ue_rx_before[ordinal]))
  tx_delta=$((ue_tx_after - ue_tx_before[ordinal]))
  if (( rx_delta <= 0 || tx_delta <= 0 )); then
    printf 'error: UE tunnel counters did not increase for ordinal %s\n' "$ordinal" >&2
    exit 32
  fi
  printf 'ue_ordinal=%s tunnel_rx_packet_delta=%s tunnel_tx_packet_delta=%s\n' \
    "$ordinal" "$rx_delta" "$tx_delta"
done
printf 'per_ue_bidirectional_tunnel_counters=pass\n'

upf_cap=$("${kubectl_namespace[@]}" exec "deployment/${release}-upf" \
  --container upf -- sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
if [[ $upf_cap != "0000000000001000" ]]; then
  printf 'error: UPF effective capabilities changed: %s\n' "$upf_cap" >&2
  exit 33
fi
for ordinal in 0 1 2 3 4; do
  ue_cap=$("${kubectl_namespace[@]}" exec "${release}-ue-${ordinal}" \
    --container ue -- sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
  if [[ $ue_cap != "0000000000003000" ]]; then
    printf 'error: UE ordinal %s effective capabilities changed: %s\n' \
      "$ordinal" "$ue_cap" >&2
    exit 33
  fi
done
for component in data-internet data-enterprise; do
  data_cap=$("${kubectl_namespace[@]}" exec "deployment/${release}-${component}" \
    --container data-network -- sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status")
  if [[ $data_cap != "0000000000000000" ]]; then
    printf 'error: endpoint %s has effective capabilities: %s\n' "$component" "$data_cap" >&2
    exit 33
  fi
done
printf 'upf_effective_capabilities=%s\n' "$upf_cap"
printf 'all_ue_effective_capabilities=0000000000003000\n'
printf 'all_endpoint_effective_capabilities=0000000000000000\n'
printf 'capability_minimization=pass\n'
printf 'dnn_selection=pass internet_ues=3 enterprise_ues=2\n'
printf 'cross_dnn_isolation=pass\n'
printf 'platform_validation=pass\n'
