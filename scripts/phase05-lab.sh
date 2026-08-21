#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: sudo scripts/phase05-lab.sh ACTION

Actions:
  preflight       Read-only cluster/resource, identity-plan, Secret-material,
                  and deterministic Helm-render checks.
  prepare-secret  Create or verify the exact file-backed Phase 5 Secret.
  upgrade         Migrate the accepted release to five stable UE identities,
                  two DNNs, and two isolated data endpoints; then validate it.
  repair-sessions Quiesce the five UEs, restart only the project-owned 5G
                  session chain in dependency order, and revalidate Phase 5.
                  This does not create a Helm revision or alter subscriber data.
  validate        Reconcile the two exact kind-node return routes and run the
                  complete per-UE Phase 5 validator.
  test-invalid-ue Launch one non-provisioned synthetic UE, prove that it
                  cannot establish service, and revalidate all five valid UEs.
  test-reprovision Remove one exact managed subscriber, rerun the idempotent
                  batch Job, reconcile sessions, and prove full recovery.
  observe-resources
                  Validate the topology, then sample cgroup CPU and memory for
                  every singleton component and each of the five UE Pods.
  rollback        Restore the saved Phase 4 revision, remove only four
                  Phase 5-managed subscriber records, and validate Phase 4.
  status          Show the Helm release and Phase 5 namespace-scoped objects.
  reset-stale-state --confirm
                  Preserve and archive a rollback state from a deleted cluster
                  only when the current release is a different Phase 4/PVC
                  lineage. This never changes the live release or database.
  remove-secret --confirm
                  Remove only the verified Phase 5 Secret after rollback.

The helper never deletes the MongoDB claim, kind cluster, Phase 4 Secret, or
unrelated resources. Cluster lifecycle remains owned by kind-feasibility.sh.
EOF
}

action=${1:-}
case "$action" in
  preflight|prepare-secret|upgrade|repair-sessions|validate|test-invalid-ue|test-reprovision|observe-resources|rollback|status) ;;
  remove-secret|reset-stale-state)
    if [[ ${2:-} != "--confirm" ]]; then
      printf 'error: %s requires --confirm\n' "$action" >&2
      exit 2
    fi
    ;;
  -h|--help) usage; exit 0 ;;
  *) printf 'error: unknown action: %s\n' "${action:-<empty>}" >&2; usage >&2; exit 2 ;;
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

for required_command in awk base64 chmod cmp date df docker helm install jq \
  kubectl mktemp mv python3 rm sed seq sha256sum sleep sort stat unlink; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'error: required command is unavailable: %s\n' "$required_command" >&2
    exit 4
  fi
done

# shellcheck source=../versions/phase-03.env
source "$project_root/versions/phase-03.env"
# shellcheck source=../versions/phase-04.env
source "$project_root/versions/phase-04.env"

chart="$project_root/charts/cn5g"
overlay="$chart/values-phase05.yaml"
plan="$project_root/configs/kubernetes/phase-05/subscriber-plan.json"
material_dir="$project_root/artifacts/secrets/phase-05"
kubeconfig="$project_root/artifacts/kubernetes/cn5g.kubeconfig"
state_file="$project_root/artifacts/kubernetes/phase-05-upgrade.state"
secret_name=cn5g-subscribers-phase05
namespace=$CN5G_KUBERNETES_NAMESPACE
release=$CN5G_HELM_RELEASE_NAME
node_container="${KIND_CLUSTER_NAME}-control-plane"
generator="$script_dir/generate-phase05-subscribers.py"
validator="$script_dir/validate-phase05.sh"
invalid_ue_manifest="$project_root/configs/kubernetes/phase-05/invalid-ue-pod.yaml"
reprovision_manifest="$project_root/configs/kubernetes/phase-05/reprovision-job.yaml"

for required_file in "$chart/Chart.yaml" "$chart/values.yaml" "$overlay" \
  "$plan" "$generator" "$validator" "$invalid_ue_manifest" \
  "$reprovision_manifest"; do
  if [[ ! -r $required_file || -L $required_file ]]; then
    printf 'error: required file is missing, unreadable, or unsafe: %s\n' \
      "$required_file" >&2
    exit 4
  fi
done

kubectl_namespace=(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace")

require_cluster() {
  if [[ ! -r $kubeconfig || -L $kubeconfig ]]; then
    printf 'error: project kubeconfig is absent or unsafe\n' >&2
    return 1
  fi
  if ! docker inspect "$node_container" >/dev/null 2>&1; then
    printf 'error: exact kind node container is absent: %s\n' "$node_container" >&2
    return 1
  fi
  kubectl --kubeconfig "$kubeconfig" get node "$node_container" >/dev/null
}

release_json() {
  helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    status "$release" --output json
}

release_phase05_enabled() {
  helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    get values "$release" --all --output json | jq -r '
      (.phase05.enabled // false) |
      if type == "boolean" then tostring
      else error("phase05.enabled must be boolean")
      end'
}

verify_release_deployed() {
  local status
  status=$(release_json | jq -er '.info.status')
  if [[ $status != "deployed" ]]; then
    printf 'error: Helm release is not deployed: %s\n' "$status" >&2
    return 1
  fi
}

verify_resource_budget() {
  local memory_kib swap_kib disk_kib
  memory_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  swap_kib=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
  disk_kib=$(df -Pk /var/lib/docker | awk 'NR == 2 {print $4}')
  printf 'host_memory_available_gib=%s\n' "$((memory_kib / 1024 / 1024))"
  printf 'host_swap_total_mib=%s\n' "$((swap_kib / 1024))"
  printf 'docker_filesystem_available_gib=%s\n' "$((disk_kib / 1024 / 1024))"
  if (( memory_kib < 6 * 1024 * 1024 )); then
    printf 'error: Phase 5 requires at least 6 GiB available memory before rollout\n' >&2
    return 1
  fi
  if (( swap_kib < 512 * 1024 )); then
    printf 'error: Phase 5 requires at least 512 MiB configured swap\n' >&2
    return 1
  fi
  if (( disk_kib < 6 * 1024 * 1024 )); then
    printf 'error: Phase 5 requires at least 6 GiB on the Docker filesystem\n' >&2
    return 1
  fi
  printf 'phase05_resource_budget=pass\n'
}

phase05_secret_files() {
  printf '%s\n' "$material_dir/subscriber-init.js" "$material_dir/plan.json"
  local ordinal
  for ordinal in 0 1 2 3 4; do
    printf '%s\n' "$material_dir/ue-${ordinal}.yaml"
    printf '%s\n' "$material_dir/imsi-${ordinal}"
    printf '%s\n' "$material_dir/dnn-${ordinal}"
  done
}

verify_secret_ownership() {
  local secret_json instance part managed
  secret_json=$("${kubectl_namespace[@]}" get secret "$secret_name" --output json)
  instance=$(jq -r '.metadata.labels["app.kubernetes.io/instance"] // ""' <<<"$secret_json")
  part=$(jq -r '.metadata.labels["app.kubernetes.io/part-of"] // ""' <<<"$secret_json")
  managed=$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$secret_json")
  if [[ $instance != "$release" || $part != "cn5g-core" || \
        $managed != "cn5g-phase05-lab" ]]; then
    printf 'error: Phase 5 Secret ownership labels are unexpected\n' >&2
    return 1
  fi
}

verify_secret() {
  local secret_json expected_keys observed_keys file name local_hash cluster_hash
  "$generator" --check
  verify_secret_ownership
  secret_json=$("${kubectl_namespace[@]}" get secret "$secret_name" --output json)
  expected_keys=$(phase05_secret_files | awk -F/ '{print $NF}' | sort)
  observed_keys=$(jq -r '.data | keys[]' <<<"$secret_json" | sort)
  if [[ $observed_keys != "$expected_keys" ]]; then
    printf 'error: Phase 5 Secret key set differs from the generated contract\n' >&2
    return 1
  fi
  while IFS= read -r file; do
    name=${file##*/}
    local_hash=$(sha256sum "$file" | awk '{print $1}')
    cluster_hash=$(jq -r --arg key "$name" '.data[$key]' <<<"$secret_json" | \
      base64 --decode | sha256sum | awk '{print $1}')
    if [[ $local_hash != "$cluster_hash" ]]; then
      printf 'error: Phase 5 Secret content mismatch: %s\n' "$name" >&2
      return 1
    fi
  done < <(phase05_secret_files)
  printf 'phase05_subscriber_secret=present-matching-and-project-owned\n'
}

prepare_secret() {
  local -a create_args
  "$generator" --check
  if ! "${kubectl_namespace[@]}" get secret "$secret_name" >/dev/null 2>&1; then
    create_args=(create secret generic "$secret_name")
    while IFS= read -r file; do
      create_args+=("--from-file=${file##*/}=${file}")
    done < <(phase05_secret_files)
    "${kubectl_namespace[@]}" "${create_args[@]}"
    "${kubectl_namespace[@]}" label secret "$secret_name" \
      "app.kubernetes.io/instance=${release}" \
      app.kubernetes.io/part-of=cn5g-core \
      app.kubernetes.io/managed-by=cn5g-phase05-lab
  fi
  verify_secret
  printf 'phase05_secret_preparation=pass\n'
}

component_pod_ip() {
  local component=$1
  "${kubectl_namespace[@]}" get pod \
    --selector "app.kubernetes.io/component=${component},app.kubernetes.io/instance=${release}" \
    --output json | jq -er '
      [.items[] | select(.status.phase == "Running") | .status.podIP] |
      if length == 1 then .[0] else error("expected one running component Pod") end'
}

pod_node_interface() {
  local pod_ip=$1 pod_route interface
  pod_route=$(docker exec "$node_container" ip -4 route show "$pod_ip/32")
  interface=$(awk '{for (field = 1; field <= NF; field++) if ($field == "dev") {print $(field + 1); exit}}' <<<"$pod_route")
  if [[ -z $interface || $pod_route != "$pod_ip dev $interface scope host"* ]]; then
    printf 'error: could not identify the UPF Pod node-side interface\n' >&2
    return 1
  fi
  printf '%s\n' "$interface"
}

recognized_return_route() {
  local route=$1 subnet=$2 metric=$3
  [[ $route == "$subnet via 10.244."* && $route == *" dev veth"* && \
     $route == *" proto 186 "* && $route == *" metric $metric "* && \
     $route == *" onlink"* ]]
}

reconcile_return_routes() {
  local upf_ip interface subnet metric existing prefix
  upf_ip=$(component_pod_ip upf)
  interface=$(pod_node_interface "$upf_ip")
  for subnet_metric in "10.60.0.0/24:46060" "10.61.0.0/24:46061"; do
    subnet=${subnet_metric%:*}
    metric=${subnet_metric##*:}
    existing=$(docker exec "$node_container" ip -N -4 route show "$subnet")
    prefix="$subnet via $upf_ip dev $interface"
    if [[ -n $existing ]] && ! recognized_return_route "$existing" "$subnet" "$metric"; then
      printf 'error: refusing to replace unrecognized kind-node route: %s\n' "$subnet" >&2
      printf 'observed=%s\n' "$existing" >&2
      return 1
    fi
    if [[ $existing != "$prefix "* ]]; then
      if [[ -n $existing ]]; then
        docker exec "$node_container" ip -4 route del "$subnet" proto 186 metric "$metric"
      fi
      docker exec "$node_container" ip -4 route add "$subnet" via "$upf_ip" \
        dev "$interface" onlink proto 186 metric "$metric"
      existing=$(docker exec "$node_container" ip -N -4 route show "$subnet")
    fi
    if [[ $existing != "$prefix "* ]] || ! recognized_return_route "$existing" "$subnet" "$metric"; then
      printf 'error: Phase 5 return route did not converge: %s\n' "$subnet" >&2
      return 1
    fi
    printf 'kind_node_return_route=%s\n' "$existing"
  done
  printf 'phase05_return_routes=pass\n'
}

remove_enterprise_return_route() {
  local existing
  existing=$(docker exec "$node_container" ip -N -4 route show 10.61.0.0/24)
  if [[ -z $existing ]]; then
    printf 'enterprise_return_route=absent\n'
    return
  fi
  if ! recognized_return_route "$existing" "10.61.0.0/24" "46061"; then
    printf 'error: refusing to remove unrecognized enterprise return route\n' >&2
    return 1
  fi
  docker exec "$node_container" ip -4 route del 10.61.0.0/24 proto 186 metric 46061
  printf 'enterprise_return_route=removed\n'
}

wait_for_phase05_foundation() {
  local revision=$1 component
  "${kubectl_namespace[@]}" wait --for=condition=Complete \
    "job/${release}-subscriber-init-r${revision}" --timeout=240s
  for component in nrf udr udm ausf pcf nssf smf scp amf upf \
    data-internet data-enterprise gnb; do
    "${kubectl_namespace[@]}" rollout status "deployment/${release}-${component}" \
      --timeout=240s
  done
  "${kubectl_namespace[@]}" rollout status "statefulset/${release}-mongodb" \
    --timeout=240s
  printf 'phase05_foundation_readiness=pass\n'
}

verify_ue_statefulset_ownership() {
  local object instance component managed
  object=$("${kubectl_namespace[@]}" get "statefulset/${release}-ue" \
    --output json)
  instance=$(jq -r '.metadata.labels["app.kubernetes.io/instance"] // ""' \
    <<<"$object")
  component=$(jq -r '.metadata.labels["app.kubernetes.io/component"] // ""' \
    <<<"$object")
  managed=$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' \
    <<<"$object")
  if [[ $instance != "$release" || $component != "ue" || $managed != "Helm" ]]; then
    printf 'error: UE StatefulSet ownership contract failed\n' >&2
    return 1
  fi
}

scale_phase05_ues() {
  local replicas=$1 object observed=unknown attempt
  verify_ue_statefulset_ownership
  "${kubectl_namespace[@]}" scale "statefulset/${release}-ue" \
    --replicas="$replicas"
  if [[ $replicas == "0" ]]; then
    for attempt in $(seq 1 60); do
      object=$("${kubectl_namespace[@]}" get "statefulset/${release}-ue" \
        --output json)
      observed=$(jq -r '.status.replicas // 0' <<<"$object")
      [[ $observed == "0" ]] && break
      sleep 2
    done
    if [[ $observed != "0" ]]; then
      printf 'error: UE StatefulSet did not quiesce\n' >&2
      return 1
    fi
    printf 'phase05_ue_statefulset=quiesced\n'
    return
  fi
  "${kubectl_namespace[@]}" rollout status "statefulset/${release}-ue" \
    --timeout=360s
  printf 'phase05_ue_statefulset=ready replicas=%s\n' "$replicas"
}

wait_for_phase05_nrf_profiles() {
  local collection count attempt
  for attempt in $(seq 1 60); do
    collection=$("${kubectl_namespace[@]}" exec "deployment/${release}-nrf" \
      --container nrf -- curl --http2-prior-knowledge --fail --silent \
      --show-error "http://${release}-nrf:7777/nnrf-nfm/v1/nf-instances" \
      2>/dev/null || true)
    if [[ -n $collection ]]; then
      count=$(jq -r '._links.totalItemCount // 0' <<<"$collection" \
        2>/dev/null || printf '0')
    else
      count=0
    fi
    if [[ $count == "9" ]]; then
      printf 'phase05_nrf_profile_convergence=pass count=9\n'
      return
    fi
    sleep 2
  done
  printf 'error: NRF did not converge to nine profiles before UE startup\n' >&2
  return 1
}

restart_session_chain() {
  local component
  # Establish the quiescence invariant here rather than relying on callers.
  # Otherwise an in-place recovery can restart the gNB beneath live UEs; those
  # Pods remain Ready at the container level but retain no usable radio cell.
  scale_phase05_ues 0
  # UEs remain stopped while stateful SBI, PFCP, NGAP, and discovery caches
  # are rebuilt. Otherwise failed session retries can exhaust UDM's SDM
  # subscription pool before the dependency chain has converged.
  for component in nrf scp udr udm ausf pcf nssf upf smf amf gnb; do
    "${kubectl_namespace[@]}" rollout restart "deployment/${release}-${component}"
    "${kubectl_namespace[@]}" rollout status "deployment/${release}-${component}" \
      --timeout=240s
    printf 'deployment=%s session_cache_reset=pass\n' "$component"
  done
  wait_for_phase05_nrf_profiles
  scale_phase05_ues 5
  printf 'statefulset=ue session_cache_reset=pass\n'
}

repair_phase05_sessions() {
  verify_release_deployed
  if [[ $(release_phase05_enabled) != "true" ]]; then
    printf 'error: session repair requires the deployed Phase 5 topology\n' >&2
    return 1
  fi
  verify_secret
  printf 'phase05_session_repair=dependency-ordered-restart\n'
  restart_session_chain
  reconcile_return_routes
  "$validator"
  printf 'phase05_session_repair=pass\n'
}

write_state() {
  local revision=$1 pvc_json uid volume
  pvc_json=$("${kubectl_namespace[@]}" get pvc \
    "mongodb-data-${release}-mongodb-0" --output json)
  uid=$(jq -er '.metadata.uid' <<<"$pvc_json")
  volume=$(jq -er '.spec.volumeName' <<<"$pvc_json")
  install -d -m 0700 "$(dirname -- "$state_file")"
  install -m 0600 /dev/null "$state_file"
  printf 'BASE_REVISION=%q\nPVC_UID=%q\nPVC_VOLUME=%q\n' \
    "$revision" "$uid" "$volume" > "$state_file"
}

read_state() {
  if [[ ! -f $state_file || -L $state_file || $(stat -c '%a' "$state_file") != "600" ]]; then
    printf 'error: Phase 5 rollback state is absent or unsafe\n' >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$state_file"
  if [[ ! ${BASE_REVISION:-} =~ ^[1-9][0-9]*$ || -z ${PVC_UID:-} || -z ${PVC_VOLUME:-} ]]; then
    printf 'error: Phase 5 rollback state is invalid\n' >&2
    return 1
  fi
}

verify_pvc_identity() {
  local pvc_json uid volume
  pvc_json=$("${kubectl_namespace[@]}" get pvc \
    "mongodb-data-${release}-mongodb-0" --output json)
  uid=$(jq -er '.metadata.uid' <<<"$pvc_json")
  volume=$(jq -er '.spec.volumeName' <<<"$pvc_json")
  if [[ $uid != "$PVC_UID" || $volume != "$PVC_VOLUME" ]]; then
    printf 'error: MongoDB PVC identity changed across Phase 5 lifecycle\n' >&2
    return 1
  fi
  printf 'mongodb_pvc_identity=preserved\n'
}

reset_stale_state() {
  verify_release_deployed
  if [[ $(release_phase05_enabled) != "false" ]]; then
    printf 'error: stale-state reset requires the deployed Phase 4 topology\n' >&2
    return 1
  fi
  read_state
  local current_revision pvc_json current_uid current_volume archive
  current_revision=$(release_json | jq -er '.version')
  pvc_json=$("${kubectl_namespace[@]}" get pvc \
    "mongodb-data-${release}-mongodb-0" --output json)
  current_uid=$(jq -er '.metadata.uid' <<<"$pvc_json")
  current_volume=$(jq -er '.spec.volumeName' <<<"$pvc_json")
  if [[ $current_uid == "$PVC_UID" || $current_volume == "$PVC_VOLUME" ]]; then
    printf 'error: rollback state belongs to the current PVC and is not stale\n' >&2
    return 1
  fi
  if [[ $current_revision == "$BASE_REVISION" ]]; then
    printf 'error: refusing stale-state reset with a matching Helm revision\n' >&2
    return 1
  fi
  archive="${state_file}.stale-$(date -u +%Y%m%dT%H%M%SZ)"
  [[ ! -e $archive && ! -L $archive ]] || {
    printf 'error: stale-state archive target already exists\n' >&2
    return 1
  }
  mv -- "$state_file" "$archive"
  chmod 0600 "$archive"
  printf 'phase05_stale_state=archived old_revision=%s current_revision=%s\n' \
    "$BASE_REVISION" "$current_revision"
}

controlled_upgrade() {
  local current_revision current_phase05 current_status new_revision
  verify_secret
  current_revision=$(release_json | jq -er '.version')
  current_status=$(release_json | jq -er '.info.status')
  current_phase05=$(release_phase05_enabled)
  if [[ ! -e $state_file ]]; then
    if [[ $current_status != "deployed" || $current_phase05 != "false" ]]; then
      printf 'error: a new Phase 5 migration requires the deployed Phase 4 topology\n' >&2
      printf 'release_status=%s phase05_enabled=%s\n' \
        "$current_status" "$current_phase05" >&2
      return 1
    fi
    write_state "$current_revision"
    read_state
    "${kubectl_namespace[@]}" scale "deployment/${release}-ue" --replicas=0
    "${kubectl_namespace[@]}" rollout status "deployment/${release}-ue" --timeout=120s
    printf 'phase04_ue_deployment=scaled-to-zero-for-kind-migration\n'
  else
    read_state
    verify_pvc_identity
    case "$current_status" in
      deployed|failed|pending-upgrade) ;;
      *)
        printf 'error: release state is not safe for controlled Phase 5 resume: %s\n' \
          "$current_status" >&2
        return 1
        ;;
    esac
    case "$current_phase05" in
      false)
        if "${kubectl_namespace[@]}" get "deployment/${release}-ue" >/dev/null 2>&1; then
          "${kubectl_namespace[@]}" scale "deployment/${release}-ue" --replicas=0
          "${kubectl_namespace[@]}" rollout status \
            "deployment/${release}-ue" --timeout=120s
        fi
        printf 'controlled_phase05_upgrade_resume=pre-apply\n'
        ;;
      true)
        printf 'controlled_phase05_upgrade_resume=post-apply-convergence\n'
        ;;
      *)
        printf 'error: Phase 5 enablement value is invalid: %s\n' \
          "$current_phase05" >&2
        return 1
        ;;
    esac
  fi
  helm upgrade "$release" "$chart" --kubeconfig "$kubeconfig" \
    --namespace "$namespace" --values "$overlay" --dry-run=server \
    --hide-secret >/dev/null
  printf 'server_side_phase05_upgrade_dry_run=pass\n'
  helm upgrade "$release" "$chart" --kubeconfig "$kubeconfig" \
    --namespace "$namespace" --values "$overlay"
  printf 'helm_phase05_upgrade_submission=pass\n'
  new_revision=$(release_json | jq -er '.version')
  # The first UE PDU-session attempt can precede UPF readiness. Waiting for
  # every UE inside Helm would then deadlock the recovery sequence. Converge
  # the database, subscriber Job, core, UPF, DNNs, and gNB first; afterwards
  # restart the session chain and the UE StatefulSet in dependency order.
  scale_phase05_ues 0
  wait_for_phase05_foundation "$new_revision"
  restart_session_chain
  printf 'phase05_workload_readiness=pass\n'
  reconcile_return_routes
  verify_pvc_identity
  "$validator"
  printf 'phase05_upgrade_revision=%s\nphase05_upgrade=pass\n' "$new_revision"
}

verify_invalid_resource_ownership() {
  local kind=$1 name=$2 object instance part managed
  object=$("${kubectl_namespace[@]}" get "$kind" "$name" --output json)
  instance=$(jq -r '.metadata.labels["app.kubernetes.io/instance"] // ""' \
    <<<"$object")
  part=$(jq -r '.metadata.labels["app.kubernetes.io/part-of"] // ""' \
    <<<"$object")
  managed=$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' \
    <<<"$object")
  if [[ $instance != "$release" || $part != "cn5g-core" || \
        $managed != "cn5g-phase05-lab" ]]; then
    printf 'error: refusing to alter an unrecognized negative-test %s: %s\n' \
      "$kind" "$name" >&2
    return 1
  fi
}

cleanup_invalid_ue() {
  local kind name=cn5g-phase05-invalid-ue
  for kind in pod secret; do
    if "${kubectl_namespace[@]}" get "$kind" "$name" >/dev/null 2>&1; then
      verify_invalid_resource_ownership "$kind" "$name"
      "${kubectl_namespace[@]}" delete "$kind" "$name" \
        --wait=true --timeout=120s
    fi
  done
  printf 'invalid_ue_test_resources=absent\n'
}

invalid_ue_experiment_body() {
  local temp_dir=$1 source_imsi invalid_imsi=999700000000099
  local attempt logs invalid_count managed_count total_count ue_state
  source_imsi=$(jq -er '.subscribers[] | select(.ordinal == 0) | .imsi' "$plan")
  sed "s/${source_imsi}/${invalid_imsi}/g" \
    "$material_dir/ue-0.yaml" > "$temp_dir/ue-invalid.yaml" || return 1
  chmod 0600 "$temp_dir/ue-invalid.yaml" || return 1
  if grep -Fq "$source_imsi" "$temp_dir/ue-invalid.yaml" || \
      ! grep -Fq "$invalid_imsi" "$temp_dir/ue-invalid.yaml"; then
    printf 'error: invalid UE identity substitution failed\n' >&2
    return 1
  fi
  invalid_count=$("${kubectl_namespace[@]}" exec \
    "statefulset/${release}-mongodb" --container mongodb -- \
    mongosh --quiet open5gs --eval \
    "db.subscribers.countDocuments({imsi:'${invalid_imsi}'})") || return 1
  if [[ $invalid_count != "0" ]]; then
    printf 'error: reserved invalid identity is unexpectedly provisioned\n' >&2
    return 1
  fi
  "${kubectl_namespace[@]}" create secret generic cn5g-phase05-invalid-ue \
    --from-file="ue-invalid.yaml=${temp_dir}/ue-invalid.yaml" \
    --dry-run=client --output json | jq \
      --arg instance "$release" '
        .metadata.labels = {
          "app.kubernetes.io/instance": $instance,
          "app.kubernetes.io/part-of": "cn5g-core",
          "app.kubernetes.io/managed-by": "cn5g-phase05-lab"
        }' | "${kubectl_namespace[@]}" apply --server-side \
          --field-manager=cn5g-phase05-lab --filename=- || return 1
  "${kubectl_namespace[@]}" apply --server-side \
    --field-manager=cn5g-phase05-lab --filename "$invalid_ue_manifest" || return 1
  for attempt in $(seq 1 45); do
    logs=$("${kubectl_namespace[@]}" logs cn5g-phase05-invalid-ue \
      --container ue --tail=300 2>/dev/null || true)
    [[ $logs == *"Sending Initial Registration"* ]] && break
    sleep 2
  done
  if [[ ${logs:-} != *"Sending Initial Registration"* ]]; then
    printf 'error: invalid UE did not reach the registration attempt\n' >&2
    return 1
  fi
  sleep 8
  logs=$("${kubectl_namespace[@]}" logs cn5g-phase05-invalid-ue \
    --container ue --tail=500 2>/dev/null || true)
  if [[ $logs == *"Initial Registration is successful"* || \
        $logs == *"PDU Session establishment is successful"* ]]; then
    printf 'error: non-provisioned UE unexpectedly obtained service\n' >&2
    return 1
  fi
  invalid_count=$("${kubectl_namespace[@]}" exec \
    "statefulset/${release}-mongodb" --container mongodb -- \
    mongosh --quiet open5gs --eval \
    "db.subscribers.countDocuments({imsi:'${invalid_imsi}'})") || return 1
  managed_count=$("${kubectl_namespace[@]}" exec \
    "statefulset/${release}-mongodb" --container mongodb -- \
    mongosh --quiet open5gs --eval \
    'db.subscribers.countDocuments({"cn5g_managed.phase":5})') || return 1
  total_count=$("${kubectl_namespace[@]}" exec \
    "statefulset/${release}-mongodb" --container mongodb -- \
    mongosh --quiet open5gs --eval 'db.subscribers.countDocuments({})') || return 1
  ue_state=$("${kubectl_namespace[@]}" get statefulset "${release}-ue" \
    --output json) || return 1
  if [[ $invalid_count != "0" || $managed_count != "5" || \
        $total_count != "5" || \
        $(jq -er '.status.readyReplicas // 0' <<<"$ue_state") != "5" ]]; then
    printf 'error: invalid UE changed the accepted five-UE state\n' >&2
    return 1
  fi
  printf 'invalid_ue_registration=denied\n'
  printf 'invalid_ue_database_side_effects=none\n'
  printf 'valid_ue_readiness_during_negative_test=pass count=5\n'
  "$validator" || return 1
}

test_invalid_ue() {
  local temp_dir result=0
  verify_secret
  verify_release_deployed
  if [[ $(release_phase05_enabled) != "true" ]]; then
    printf 'error: invalid-UE test requires the Phase 5 topology\n' >&2
    return 1
  fi
  cleanup_invalid_ue
  temp_dir=$(mktemp -d)
  chmod 0700 "$temp_dir"
  if ! invalid_ue_experiment_body "$temp_dir"; then
    result=1
  fi
  rm -rf -- "$temp_dir"
  if ! cleanup_invalid_ue; then
    result=1
  fi
  if (( result != 0 )); then
    printf 'error: invalid-UE isolation test failed\n' >&2
    return 1
  fi
  printf 'invalid_ue_isolation_test=pass\n'
}

cleanup_reprovision_job() {
  local name=cn5g-phase05-reprovision
  if "${kubectl_namespace[@]}" get job "$name" >/dev/null 2>&1; then
    verify_invalid_resource_ownership job "$name"
    "${kubectl_namespace[@]}" delete job "$name" \
      --wait=true --timeout=120s
  fi
  printf 'reprovision_test_job=absent\n'
}

wait_for_reprovision_job() {
  local name=cn5g-phase05-reprovision attempt job_json complete failed reasons
  for attempt in $(seq 1 120); do
    job_json=$("${kubectl_namespace[@]}" get job "$name" --output json) || return 1
    complete=$(jq -r \
      '[.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length' \
      <<<"$job_json")
    failed=$(jq -r \
      '[.status.conditions[]? | select(.type == "Failed" and .status == "True")] | length' \
      <<<"$job_json")
    if [[ $complete == "1" ]]; then
      printf 'reprovision_job_completion=pass\n'
      return 0
    fi
    if [[ $failed == "1" ]]; then
      reasons=$("${kubectl_namespace[@]}" get pods \
        --selector="job-name=${name}" --output json | jq -r \
        '[.items[].status.containerStatuses[]? | .state.terminated.reason // empty] | unique | join(",")')
      printf 'error: reprovision Job failed: %s\n' "${reasons:-unknown}" >&2
      return 1
    fi
    sleep 2
  done
  printf 'error: reprovision Job did not finish within 240 seconds\n' >&2
  return 1
}

reprovision_experiment_body() {
  local target_imsi removed result managed_count total_count
  target_imsi=$(jq -er '.subscribers[] | select(.ordinal == 4) | .imsi' "$plan")
  removed=$("${kubectl_namespace[@]}" exec \
    "statefulset/${release}-mongodb" --container mongodb -- \
    mongosh --quiet open5gs --eval \
    "db.subscribers.deleteOne({imsi:'${target_imsi}', 'cn5g_managed.phase':5}).deletedCount") \
    || return 1
  case "$removed" in
    1) printf 'partial_subscriber_state=created missing_records=1\n' ;;
    0) printf 'partial_subscriber_state=preexisting missing_records=1\n' ;;
    *)
      printf 'error: scoped subscriber deletion returned: %s\n' "$removed" >&2
      return 1
      ;;
  esac
  "${kubectl_namespace[@]}" apply --server-side \
    --field-manager=cn5g-phase05-lab --filename "$reprovision_manifest" || return 1
  wait_for_reprovision_job || return 1
  result=$("${kubectl_namespace[@]}" logs job/cn5g-phase05-reprovision \
    --container subscriber-reprovision --tail=50) || return 1
  if [[ $result != *"subscriber_batch_init=pass count=5"* ]]; then
    printf 'error: reprovision Job did not report complete batch convergence\n' >&2
    return 1
  fi
  managed_count=$("${kubectl_namespace[@]}" exec \
    "statefulset/${release}-mongodb" --container mongodb -- \
    mongosh --quiet open5gs --eval \
    'db.subscribers.countDocuments({"cn5g_managed.phase":5})') || return 1
  total_count=$("${kubectl_namespace[@]}" exec \
    "statefulset/${release}-mongodb" --container mongodb -- \
    mongosh --quiet open5gs --eval 'db.subscribers.countDocuments({})') || return 1
  if [[ $managed_count != "5" || $total_count != "5" ]]; then
    printf 'error: reprovision Job did not restore exactly five subscribers\n' >&2
    return 1
  fi
  printf 'partial_subscriber_reprovision=pass restored_records=1 total=5\n'
  restart_session_chain || return 1
  reconcile_return_routes || return 1
  "$validator" || return 1
}

test_reprovision() {
  verify_secret
  verify_release_deployed
  if [[ $(release_phase05_enabled) != "true" ]]; then
    printf 'error: reprovision test requires the Phase 5 topology\n' >&2
    return 1
  fi
  cleanup_reprovision_job
  if ! reprovision_experiment_body; then
    printf 'error: partial subscriber reprovision test failed\n' >&2
    printf 'recovery: rerun test-reprovision; the idempotent Job repairs a missing record\n' >&2
    return 1
  fi
  cleanup_reprovision_job
  printf 'partial_provisioning_recovery_test=pass\n'
}

phase05_cgroup_sample() {
  local target=$1 container=$2
  "${kubectl_namespace[@]}" exec "$target" --container "$container" -- sh -ec '
    cpu=$(awk '\''/^usage_usec / {print $2}'\'' /sys/fs/cgroup/cpu.stat)
    memory=$(cat /sys/fs/cgroup/memory.current)
    if test -r /sys/fs/cgroup/memory.peak; then
      peak=$(cat /sys/fs/cgroup/memory.peak)
    else
      peak=$memory
    fi
    printf "%s %s %s\n" "$cpu" "$memory" "$peak"
  '
}

phase05_resource_contract() {
  local workload=$1 container=$2
  "${kubectl_namespace[@]}" get "$workload" --output json | jq -er \
    --arg container "$container" '
      .spec.template.spec.containers[] |
      select(.name == $container) |
      [
        (.resources.requests.cpu // "<none>"),
        (.resources.requests.memory // "<none>"),
        (.resources.limits.cpu // "<none>"),
        (.resources.limits.memory // "<none>")
      ] | join("|")
    '
}

observe_phase05_resources() {
  local component container sample cpu memory peak now delta_cpu delta_time
  local cpu_millicores memory_mib peak_mib contract
  local request_cpu request_memory limit_cpu limit_memory ordinal index
  local -a labels=() targets=() containers=() contracts=()
  local -A cpu_before=() time_before=()

  verify_secret
  verify_release_deployed
  if [[ $(release_phase05_enabled) != "true" ]]; then
    printf 'error: resource observation requires the Phase 5 topology\n' >&2
    return 1
  fi
  "$validator"

  for component in mongodb nrf scp amf ausf udm udr pcf nssf smf upf \
    data-internet data-enterprise gnb; do
    container=$component
    case "$component" in
      data-internet|data-enterprise) container=data-network ;;
    esac
    labels+=("component=${component}")
    containers+=("$container")
    if [[ $component == "mongodb" ]]; then
      targets+=("statefulset/${release}-mongodb")
      contracts+=("statefulset/${release}-mongodb")
    else
      targets+=("deployment/${release}-${component}")
      contracts+=("deployment/${release}-${component}")
    fi
  done
  for ordinal in 0 1 2 3 4; do
    labels+=("component=ue ordinal=${ordinal}")
    targets+=("${release}-ue-${ordinal}")
    containers+=("ue")
    contracts+=("statefulset/${release}-ue")
  done

  for index in "${!targets[@]}"; do
    sample=$(phase05_cgroup_sample "${targets[$index]}" "${containers[$index]}")
    read -r cpu _ _ <<<"$sample"
    if [[ ! $cpu =~ ^[0-9]+$ ]]; then
      printf 'error: invalid initial CPU sample for %s\n' "${labels[$index]}" >&2
      return 1
    fi
    cpu_before[$index]=$cpu
    time_before[$index]=$(date +%s%N)
  done
  printf 'resource_observation_window_seconds=10\n'
  sleep 10
  for index in "${!targets[@]}"; do
    sample=$(phase05_cgroup_sample "${targets[$index]}" "${containers[$index]}")
    now=$(date +%s%N)
    read -r cpu memory peak <<<"$sample"
    if [[ ! $cpu =~ ^[0-9]+$ || ! $memory =~ ^[0-9]+$ || \
          ! $peak =~ ^[0-9]+$ ]]; then
      printf 'error: invalid cgroup sample for %s\n' "${labels[$index]}" >&2
      return 1
    fi
    delta_cpu=$((cpu - cpu_before[$index]))
    delta_time=$((now - time_before[$index]))
    if (( delta_cpu < 0 || delta_time <= 0 )); then
      printf 'error: non-monotonic resource sample for %s\n' "${labels[$index]}" >&2
      return 1
    fi
    cpu_millicores=$(((delta_cpu * 1000000 + delta_time - 1) / delta_time))
    memory_mib=$(((memory + 1048575) / 1048576))
    peak_mib=$(((peak + 1048575) / 1048576))
    contract=$(phase05_resource_contract \
      "${contracts[$index]}" "${containers[$index]}")
    IFS='|' read -r request_cpu request_memory limit_cpu limit_memory \
      <<<"$contract"
    printf '%s %s\n' "${labels[$index]}" \
      "cpu_average_millicores=${cpu_millicores} memory_current_mib=${memory_mib} memory_peak_mib=${peak_mib} request_cpu=${request_cpu} request_memory=${request_memory} limit_cpu=${limit_cpu} limit_memory=${limit_memory}"
  done
  printf 'resource_observation=pass scope=five-ue-two-dnn-steady-state\n'
}

cleanup_phase05_subscribers() {
  local result
  result=$("${kubectl_namespace[@]}" exec "statefulset/${release}-mongodb" \
    --container mongodb -- mongosh --quiet open5gs --eval '
      const managed = db.subscribers.countDocuments({"cn5g_managed.phase":5});
      const total = db.subscribers.countDocuments({});
      if (managed === 4 && total === 5) {
        const removed = db.subscribers.deleteMany({"cn5g_managed.phase":5});
        if (removed.deletedCount !== 4) throw new Error(`expected four Phase 5-only records, removed ${removed.deletedCount}`);
        if (db.subscribers.countDocuments({}) !== 1) throw new Error("expected one restored Phase 4 subscriber");
        print("phase05_subscriber_cleanup=pass removed=4 remaining=1");
      } else if (managed === 0 && total === 1) {
        print("phase05_subscriber_cleanup=pass removed=0 remaining=1 state=already-clean");
      } else {
        throw new Error(`unexpected subscriber cleanup state managed=${managed} total=${total}`);
      }')
  if [[ $result != "phase05_subscriber_cleanup=pass removed=4 remaining=1" && \
        $result != "phase05_subscriber_cleanup=pass removed=0 remaining=1 state=already-clean" ]]; then
    printf 'error: Phase 5 subscriber cleanup returned an unexpected result\n' >&2
    return 1
  fi
  printf '%s\n' "$result"
}

current_subscriber_job_name() {
  local name object instance component managed
  name=$(helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    get manifest "$release" | awk '
      /^kind: Job$/ {job = 1; next}
      job && /^metadata:$/ {metadata = 1; next}
      job && metadata && /^  name: / {print $2; exit}
    ')
  if [[ ! $name =~ ^${release}-subscriber-init-r[1-9][0-9]*$ ]]; then
    printf 'error: active release manifest has no recognized subscriber Job\n' >&2
    return 1
  fi
  object=$("${kubectl_namespace[@]}" get job "$name" --output json) || return 1
  instance=$(jq -r '.metadata.labels["app.kubernetes.io/instance"] // ""' \
    <<<"$object")
  component=$(jq -r '.metadata.labels["app.kubernetes.io/component"] // ""' \
    <<<"$object")
  managed=$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' \
    <<<"$object")
  if [[ $instance != "$release" || $component != "subscriber-init" || \
        $managed != "Helm" ]]; then
    printf 'error: active subscriber Job ownership contract failed\n' >&2
    return 1
  fi
  printf '%s\n' "$name"
}

controlled_rollback() {
  local current_phase05 rollback_revision status description subscriber_job
  read_state
  verify_pvc_identity
  current_phase05=$(release_phase05_enabled)
  case "$current_phase05" in
    true)
      "${kubectl_namespace[@]}" scale "statefulset/${release}-ue" --replicas=0
      "${kubectl_namespace[@]}" rollout status \
        "statefulset/${release}-ue" --timeout=180s
      remove_enterprise_return_route
      helm rollback "$release" "$BASE_REVISION" --kubeconfig "$kubeconfig" \
        --namespace "$namespace" --wait=watcher --wait-for-jobs --timeout=10m
      rollback_revision=$(release_json | jq -er '.version')
      printf 'controlled_phase05_rollback=post-apply revision=%s\n' \
        "$rollback_revision"
      ;;
    false)
      status=$(release_json | jq -er '.info.status')
      description=$(release_json | jq -er '.info.description')
      rollback_revision=$(release_json | jq -er '.version')
      if [[ $status != "deployed" || \
            $description != "Rollback to ${BASE_REVISION}" ]]; then
        printf 'error: Phase 4 release is not the recorded rollback target\n' >&2
        printf 'status=%s description=%s\n' "$status" "$description" >&2
        return 1
      fi
      remove_enterprise_return_route
      printf 'controlled_phase05_rollback_resume=post-apply revision=%s\n' \
        "$rollback_revision"
      ;;
    *)
      printf 'error: Phase 5 enablement value is invalid during rollback\n' >&2
      return 1
      ;;
  esac
  subscriber_job=$(current_subscriber_job_name)
  "${kubectl_namespace[@]}" wait --for=condition=Complete \
    "job/${subscriber_job}" --timeout=240s
  printf 'subscriber_job=%s completion=pass\n' "$subscriber_job"
  cleanup_phase05_subscribers
  verify_pvc_identity
  "$script_dir/helm-lab.sh" validate
  unlink "$state_file"
  printf 'phase05_rollback_target_revision=%s\n' "$BASE_REVISION"
  printf 'phase05_rollback_result_revision=%s\n' "$rollback_revision"
  printf 'phase05_rollback=pass\n'
}

run_preflight() {
  require_cluster
  verify_resource_budget
  verify_release_deployed
  if [[ $(release_phase05_enabled) != "false" ]]; then
    printf 'error: preflight requires the accepted Phase 4 topology\n' >&2
    return 1
  fi
  if [[ -e $state_file || -L $state_file ]]; then
    printf 'error: unresolved Phase 5 lifecycle state exists; inspect before migration\n' >&2
    return 1
  fi
  "$generator" --validate-plan
  "$generator" --check
  helm lint "$chart" --strict --values "$overlay"
  local render_dir render_cleanup
  render_dir=$(mktemp -d)
  printf -v render_cleanup 'rm -rf -- %q' "$render_dir"
  trap "$render_cleanup" EXIT
  helm template "$release" "$chart" --namespace "$namespace" \
    --kube-version 1.36.1 --values "$overlay" > "$render_dir/first.yaml"
  helm template "$release" "$chart" --namespace "$namespace" \
    --kube-version 1.36.1 --values "$overlay" > "$render_dir/second.yaml"
  cmp --silent "$render_dir/first.yaml" "$render_dir/second.yaml"
  rm -rf -- "$render_dir"
  trap - EXIT
  printf 'deterministic_phase05_chart_render=pass\n'
  printf 'phase05_preflight=pass\n'
}

case "$action" in
  preflight) run_preflight ;;
  prepare-secret) require_cluster; prepare_secret ;;
  upgrade) require_cluster; controlled_upgrade ;;
  repair-sessions) require_cluster; repair_phase05_sessions ;;
  validate) require_cluster; verify_secret; reconcile_return_routes; "$validator" ;;
  test-invalid-ue) require_cluster; test_invalid_ue ;;
  test-reprovision) require_cluster; test_reprovision ;;
  observe-resources) require_cluster; observe_phase05_resources ;;
  rollback) require_cluster; verify_release_deployed; controlled_rollback ;;
  reset-stale-state) require_cluster; reset_stale_state ;;
  status)
    require_cluster
    helm --kubeconfig "$kubeconfig" --namespace "$namespace" list --all
    "${kubectl_namespace[@]}" get deployments,statefulsets,jobs,pods,services,pvc \
      --selector "app.kubernetes.io/instance=${release}" --output wide
    ;;
  remove-secret)
    require_cluster
    if [[ $(release_phase05_enabled) != "false" ]]; then
      printf 'error: refuse to remove the Phase 5 Secret while Phase 5 is deployed\n' >&2
      exit 1
    fi
    verify_secret
    "${kubectl_namespace[@]}" delete secret "$secret_name"
    printf 'phase05_subscriber_secret=removed\n'
    ;;
esac
