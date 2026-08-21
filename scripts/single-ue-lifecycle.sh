#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: sudo scripts/single-ue-lifecycle.sh ACTION

Actions:
  preflight       Run host/cluster collision checks and verify Helm, chart,
                  local images, and ignored subscriber material.
  load-images     Load only the accepted Compose reference images into cluster cn5g.
  prepare-secret  Create or verify the exact namespace and file-backed Secret.
  install         Server-dry-run and install the cn5g release, waiting for Jobs
                  and long-running workload readiness.
  validate        Reconcile the exact kind-node N6 return route and prove the
                  single-UE signalling and bidirectional user plane.
  observe-resources
                  Sample per-container cgroup CPU and memory usage and print
                  it beside the declared Kubernetes requests and limits.
  test-persistence
                  Recreate the MongoDB Pod and prove its PVC and a temporary
                  synthetic marker survive with unchanged identities.
  upgrade         Apply one controlled rollout-token revision, preserve the
                  MongoDB PVC, converge the release, and revalidate it.
  rollback        Roll back the controlled upgrade, preserve the MongoDB PVC,
                  converge the release, and revalidate it.
  uninstall --confirm
                  Mark persistence, remove the exact N6 route and Helm release,
                  retain the bound PVC, namespace, and subscriber Secret, and
                  verify scoped removal.
  verify-reinstall
                  After a fresh install, prove the uninstall marker and exact
                  PVC survived, then remove the temporary evidence collection.
  repair-failed-release
                  Repair a failed or incomplete release in dependency order,
                  clear stale service-discovery state, and prove that its
                  bound MongoDB PVC identity is preserved.
  recover-failed-install --confirm
                  Remove only a failed release and its verified unbound PVC;
                  preserve the namespace and subscriber Secret for retry.
  status          Show only the release and namespace-scoped workload state.

Cluster creation and deletion remain owned by cluster-lifecycle.sh. This helper
does not print Secret values, use the default kubeconfig, publish host ports,
alter host routes, delete bound persistent data, or invoke a Docker prune
operation.
EOF
}

action=${1:-}
if [[ $action == "-h" || $action == "--help" ]]; then
  usage
  exit 0
fi
case "$action" in
  preflight|load-images|prepare-secret|install|validate|observe-resources|\
  test-persistence|\
  upgrade|rollback|verify-reinstall|repair-failed-release) ;;
  recover-failed-install|uninstall|status) ;;
  *)
    printf 'error: unknown action: %s\n' "${action:-<empty>}" >&2
    usage >&2
    exit 2
    ;;
esac
confirmation=${2:-}
if [[ ( $action == "recover-failed-install" || $action == "uninstall" ) && \
      $confirmation != "--confirm" ]]; then
  printf 'error: %s requires --confirm\n' "$action" >&2
  exit 2
fi

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

for required_command in awk base64 chmod cmp date docker helm install jq kind \
  kubectl sha256sum tar; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'error: required command is unavailable: %s\n' \
      "$required_command" >&2
    exit 4
  fi
done

compose_reference="$project_root/versions/compose-runtime.env"
networking="$project_root/versions/kubernetes-runtime.env"
single_ue="$project_root/versions/platform-runtime.env"
chart="$project_root/charts/cn5g"
single_ue_profile="$project_root/profiles/single-ue.yaml"
kubeconfig="$project_root/artifacts/kubernetes/cn5g.kubeconfig"
secret_dir="$project_root/artifacts/secrets/single-ue"
secret_name=cn5g-subscriber
upgrade_state="$project_root/artifacts/kubernetes/single-ue-upgrade.state"
uninstall_state="$project_root/artifacts/kubernetes/single-ue-uninstall.state"
validator="$script_dir/validate-single-ue.sh"

for required_file in "$compose_reference" "$networking" "$single_ue" \
  "$chart/Chart.yaml" "$chart/values.yaml" "$single_ue_profile" \
  "$script_dir/install-helm.sh" "$script_dir/generate-subscriber-secret.sh" \
  "$validator"; do
  if [[ ! -r $required_file ]]; then
    printf 'error: required file is missing or unreadable: %s\n' \
      "$required_file" >&2
    exit 4
  fi
done

# shellcheck source=../versions/compose-runtime.env
source "$compose_reference"
# shellcheck source=../versions/kubernetes-runtime.env
source "$networking"
# shellcheck source=../versions/platform-runtime.env
source "$single_ue"
node_container="${KIND_CLUSTER_NAME}-control-plane"

mongodb_load_reference=${MONGODB_IMAGE%@sha256:*}
mongodb_repository=${mongodb_load_reference%:*}
mongodb_expected_repo_digest="${mongodb_repository}@${MONGODB_IMAGE##*@}"

required_variables=(
  OPEN5GS_LOCAL_IMAGE OPEN5GS_LOCAL_IMAGE_ID
  UERANSIM_LOCAL_IMAGE UERANSIM_LOCAL_IMAGE_ID
  DATA_NETWORK_LOCAL_IMAGE DATA_NETWORK_LOCAL_IMAGE_ID
  MONGODB_IMAGE KIND_CLUSTER_NAME KIND_CONTEXT_NAME
  CN5G_HELM_RELEASE_NAME CN5G_KUBERNETES_NAMESPACE
  CN5G_N6_RETURN_SUBNET CN5G_N6_RETURN_PROTOCOL CN5G_N6_RETURN_METRIC
)
for variable_name in "${required_variables[@]}"; do
  if [[ -z ${!variable_name:-} ]]; then
    printf 'error: %s is not set in the version manifests\n' \
      "$variable_name" >&2
    exit 4
  fi
done
if [[ $KIND_CLUSTER_NAME != "cn5g" || \
      $CN5G_HELM_RELEASE_NAME != "cn5g" || \
      $CN5G_KUBERNETES_NAMESPACE != "cn5g" || \
      $CN5G_N6_RETURN_SUBNET != "10.60.0.0/24" || \
      $CN5G_N6_RETURN_PROTOCOL != "186" || \
      $CN5G_N6_RETURN_METRIC != "46060" ]]; then
  printf 'error: cluster, release, or namespace ownership contract changed\n' >&2
  exit 5
fi

verify_local_image() {
  local image=$1 expected_id=$2 observed_id platform
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    printf 'error: required local image is absent: %s\n' "$image" >&2
    return 1
  fi
  observed_id=$(docker image inspect --format '{{.Id}}' "$image")
  platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
  if [[ $observed_id != "$expected_id" || $platform != "linux/amd64" ]]; then
    printf 'error: local image identity or platform mismatch: %s\n' \
      "$image" >&2
    printf 'observed_id=%s\nexpected_id=%s\nplatform=%s\n' \
      "$observed_id" "$expected_id" "$platform" >&2
    return 1
  fi
  printf 'image=%s identity=accepted platform=%s\n' "$image" "$platform"
}

verify_images() {
  local mongodb_id mongodb_platform mongodb_repo_digests
  verify_local_image "$OPEN5GS_LOCAL_IMAGE" "$OPEN5GS_LOCAL_IMAGE_ID"
  verify_local_image "$UERANSIM_LOCAL_IMAGE" "$UERANSIM_LOCAL_IMAGE_ID"
  verify_local_image "$DATA_NETWORK_LOCAL_IMAGE" \
    "$DATA_NETWORK_LOCAL_IMAGE_ID"
  if [[ $mongodb_load_reference == "$MONGODB_IMAGE" ]]; then
    printf 'error: MongoDB image contract is missing an immutable digest\n' >&2
    return 1
  fi
  if ! docker image inspect "$MONGODB_IMAGE" >/dev/null 2>&1; then
    printf 'error: exact MongoDB image is absent: %s\n' "$MONGODB_IMAGE" >&2
    return 1
  fi
  mongodb_repo_digests=$(docker image inspect --format \
    '{{range .RepoDigests}}{{println .}}{{end}}' "$MONGODB_IMAGE")
  if [[ $mongodb_repo_digests != *"$mongodb_expected_repo_digest"* ]]; then
    printf 'error: local MongoDB tag does not carry the accepted RepoDigest\n' \
      >&2
    printf 'expected_repo_digest=%s\n' "$mongodb_expected_repo_digest" >&2
    return 1
  fi
  mongodb_id=$(docker image inspect --format '{{.Id}}' "$MONGODB_IMAGE")
  mongodb_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' \
    "$MONGODB_IMAGE")
  if [[ $mongodb_platform != "linux/amd64" ]]; then
    printf 'error: MongoDB image platform mismatch: %s\n' \
      "$mongodb_platform" >&2
    return 1
  fi
  printf 'image=%s image_id=%s identity=digest-pinned platform=%s\n' \
    "$MONGODB_IMAGE" "$mongodb_id" "$mongodb_platform"
  printf 'image_verification=pass\n'
}

stage_mongodb_load_reference() {
  local digest_id tag_id
  digest_id=$(docker image inspect --format '{{.Id}}' "$MONGODB_IMAGE")
  if docker image inspect "$mongodb_load_reference" >/dev/null 2>&1; then
    tag_id=$(docker image inspect --format '{{.Id}}' "$mongodb_load_reference")
    if [[ $tag_id != "$digest_id" ]]; then
      printf 'error: refusing to overwrite conflicting MongoDB tag: %s\n' \
        "$mongodb_load_reference" >&2
      printf 'digest_image_id=%s\ntag_image_id=%s\n' \
        "$digest_id" "$tag_id" >&2
      return 1
    fi
    printf 'mongodb_load_reference=%s state=present-and-matching\n' \
      "$mongodb_load_reference"
    return
  fi
  docker image tag "$MONGODB_IMAGE" "$mongodb_load_reference"
  tag_id=$(docker image inspect --format '{{.Id}}' "$mongodb_load_reference")
  if [[ $tag_id != "$digest_id" ]]; then
    printf 'error: staged MongoDB tag identity mismatch\n' >&2
    return 1
  fi
  printf 'mongodb_load_reference=%s state=created-from-accepted-digest\n' \
    "$mongodb_load_reference"
}

require_cluster() {
  if ! kind get clusters 2>/dev/null | grep -Fxq "$KIND_CLUSTER_NAME"; then
    printf 'error: required kind cluster is absent: %s\n' \
      "$KIND_CLUSTER_NAME" >&2
    return 1
  fi
  if [[ ! -f $kubeconfig || -L $kubeconfig || ! -r $kubeconfig ]]; then
    printf 'error: project kubeconfig is absent or unsafe: %s\n' \
      "$kubeconfig" >&2
    return 1
  fi
  observed_context=$(kubectl --kubeconfig "$kubeconfig" config current-context)
  if [[ $observed_context != "$KIND_CONTEXT_NAME" ]]; then
    printf 'error: unexpected kubeconfig context: %s\n' \
      "$observed_context" >&2
    return 1
  fi
  kubectl --kubeconfig "$kubeconfig" wait \
    --for=condition=Ready nodes --all --timeout=60s >/dev/null
}

verify_node_images() {
  local open5gs_runtime_id ueransim_runtime_id data_network_runtime_id
  local mongodb_runtime_id
  open5gs_runtime_id=$(runtime_config_id "$OPEN5GS_LOCAL_IMAGE")
  ueransim_runtime_id=$(runtime_config_id "$UERANSIM_LOCAL_IMAGE")
  data_network_runtime_id=$(runtime_config_id "$DATA_NETWORK_LOCAL_IMAGE")
  mongodb_runtime_id=$(runtime_config_id "$mongodb_load_reference")
  verify_node_image "$OPEN5GS_LOCAL_IMAGE" "$open5gs_runtime_id" || return 1
  verify_node_image "$UERANSIM_LOCAL_IMAGE" "$ueransim_runtime_id" || return 1
  verify_node_image "$DATA_NETWORK_LOCAL_IMAGE" \
    "$data_network_runtime_id" || return 1
  verify_node_image "$mongodb_load_reference" "$mongodb_runtime_id" || return 1
  printf 'node_runtime_image_verification=pass\n'
}

runtime_config_id() {
  local image=$1 config_path config_name
  config_path=$(docker image save "$image" | tar -xOf - manifest.json | \
    jq -er '
      [.[] | select(((.RepoTags // []) | length) > 0)] |
      if length == 1 then .[0].Config
      else error("expected exactly one tagged image manifest")
      end
    ')
  config_name=${config_path##*/}
  config_name=${config_name%.json}
  if [[ ! $config_name =~ ^[0-9a-f]{64}$ ]]; then
    printf 'error: invalid runtime configuration identity for %s\n' \
      "$image" >&2
    return 1
  fi
  printf 'sha256:%s\n' "$config_name"
}

verify_node_image() {
  local image=$1 expected_id=$2 observed_id
  observed_id=$(docker exec cn5g-control-plane crictl inspecti "$image" | \
    jq -er '.status.id')
  if [[ $observed_id != "$expected_id" ]]; then
    printf 'error: node runtime image identity mismatch: %s\n' "$image" >&2
    printf 'observed_id=%s\nexpected_id=%s\n' \
      "$observed_id" "$expected_id" >&2
    return 1
  fi
  printf 'node_image=%s image_id=%s identity=accepted\n' \
    "$image" "$observed_id"
}

verify_namespace() {
  if ! kubectl --kubeconfig "$kubeconfig" get namespace \
      "$CN5G_KUBERNETES_NAMESPACE" >/dev/null 2>&1; then
    printf 'error: project namespace is absent: %s\n' \
      "$CN5G_KUBERNETES_NAMESPACE" >&2
    return 1
  fi
  namespace_owner=$(kubectl --kubeconfig "$kubeconfig" get namespace \
    "$CN5G_KUBERNETES_NAMESPACE" \
    -o go-template='{{index .metadata.labels "app.kubernetes.io/managed-by"}}')
  if [[ $namespace_owner != "cn5g-platform" ]]; then
    printf 'error: project namespace ownership label is unexpected\n' >&2
    return 1
  fi
}

verify_secret_file() {
  local key=$1 path=$2 local_hash cluster_hash
  local_hash=$(sha256sum "$path" | awk '{print $1}')
  cluster_hash=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" get secret "$secret_name" \
    -o "go-template={{index .data \"$key\"}}" | base64 --decode | \
    sha256sum | awk '{print $1}')
  if [[ $local_hash != "$cluster_hash" ]]; then
    printf 'error: cluster Secret file does not match local material: %s\n' \
      "$key" >&2
    return 1
  fi
}

verify_secret() {
  verify_namespace
  if ! kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      get secret "$secret_name" >/dev/null 2>&1; then
    printf 'error: required project Secret is absent: %s\n' \
      "$secret_name" >&2
    return 1
  fi
  secret_owner=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" get secret "$secret_name" \
    -o go-template='{{index .metadata.labels "app.kubernetes.io/managed-by"}}')
  if [[ $secret_owner != "cn5g-platform" ]]; then
    printf 'error: Secret ownership label is unexpected\n' >&2
    return 1
  fi
  verify_secret_file ue.yaml "$secret_dir/ue.yaml"
  verify_secret_file subscriber-init.js "$secret_dir/subscriber-init.js"
  verify_secret_file imsi "$secret_dir/imsi"
  printf 'subscriber_secret=present-matching-and-project-owned\n'
}

show_status() {
  require_cluster
  helm --kubeconfig "$kubeconfig" --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    list --filter "^${CN5G_HELM_RELEASE_NAME}$"
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" get \
    deployments,statefulsets,jobs,pods,services,endpointslices,persistentvolumeclaims \
    -o wide
}

verify_owned_deployment() {
  local component=$1 deployment_name deployment_json
  local observed_instance observed_component observed_manager
  deployment_name="${CN5G_HELM_RELEASE_NAME}-${component}"
  deployment_json=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    get deployment "$deployment_name" --output json)
  observed_instance=$(jq -r \
    '.metadata.labels["app.kubernetes.io/instance"] // ""' \
    <<<"$deployment_json")
  observed_component=$(jq -r \
    '.metadata.labels["app.kubernetes.io/component"] // ""' \
    <<<"$deployment_json")
  observed_manager=$(jq -r \
    '.metadata.labels["app.kubernetes.io/managed-by"] // ""' \
    <<<"$deployment_json")
  if [[ $observed_instance != "$CN5G_HELM_RELEASE_NAME" || \
        $observed_component != "$component" || \
        $observed_manager != "Helm" ]]; then
    printf 'error: deployment ownership contract failed: %s\n' \
      "$deployment_name" >&2
    return 1
  fi
}

wait_for_deployment() {
  local component=$1
  verify_owned_deployment "$component"
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    rollout status "deployment/${CN5G_HELM_RELEASE_NAME}-${component}" \
    --timeout=120s
  printf 'deployment=%s readiness=pass\n' "$component"
}

restart_project_deployment() {
  local component=$1 selector
  selector="app.kubernetes.io/component=${component},app.kubernetes.io/instance=${CN5G_HELM_RELEASE_NAME}"
  verify_owned_deployment "$component"
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" delete pod \
    --selector "$selector" \
    --wait=true --timeout=90s
  wait_for_deployment "$component"
  printf 'deployment=%s cache_reset=pass\n' "$component"
}

wait_for_subscriber_job() {
  local revision=$1 job_name job_json complete failed attempt
  job_name="${CN5G_HELM_RELEASE_NAME}-subscriber-init-r${revision}"
  for attempt in $(seq 1 90); do
    job_json=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      get job "$job_name" --output json 2>/dev/null || true)
    if [[ -n $job_json ]]; then
      complete=$(jq -r \
        '[.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length' \
        <<<"$job_json")
      failed=$(jq -r \
        '[.status.conditions[]? | select(.type == "Failed" and .status == "True")] | length' \
        <<<"$job_json")
      if [[ $failed != "0" ]]; then
        printf 'error: subscriber initialization Job failed: %s\n' \
          "$job_name" >&2
        return 1
      fi
      if [[ $complete == "1" ]]; then
        printf 'subscriber_job=%s completion=pass\n' "$job_name"
        return
      fi
    fi
    sleep 2
  done
  printf 'error: subscriber initialization Job timed out: %s\n' \
    "$job_name" >&2
  return 1
}

verify_runtime_sbi_advertisements() {
  local component expected
  for component in nrf scp amf ausf udm udr pcf nssf smf; do
    expected="advertise: ${CN5G_HELM_RELEASE_NAME}-${component}."
    expected+="${CN5G_KUBERNETES_NAMESPACE}.svc.cluster.local"
    if ! kubectl --kubeconfig "$kubeconfig" \
        --namespace "$CN5G_KUBERNETES_NAMESPACE" \
        exec "deployment/${CN5G_HELM_RELEASE_NAME}-${component}" \
        --container "$component" -- grep -Fq "$expected" \
        "/etc/open5gs/${component}.yaml"; then
      printf 'error: stable SBI advertisement is absent: %s\n' \
        "$component" >&2
      return 1
    fi
  done
  printf 'stable_sbi_advertisements=pass\n'
}

get_nrf_collection() {
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    exec "deployment/${CN5G_HELM_RELEASE_NAME}-nrf" --container nrf -- \
    curl --http2-prior-knowledge --fail --silent --show-error \
    "http://${CN5G_HELM_RELEASE_NAME}-nrf:7777/nnrf-nfm/v1/nf-instances"
}

nrf_collection_count() {
  local collection=$1 count
  if count=$(jq -er '
      ._links.totalItemCount // 0 |
      if type == "number" and . >= 0 and floor == . then tostring
      else error("invalid NRF profile count")
      end
    ' <<<"$collection" 2>/dev/null); then
    printf '%s\n' "$count"
  else
    printf '0\n'
  fi
}

wait_for_nrf_profiles() {
  local collection count attempt
  for attempt in $(seq 1 45); do
    collection=$(get_nrf_collection 2>/dev/null || true)
    count=$(nrf_collection_count "${collection:-}")
    if [[ $count == "9" ]]; then
      printf '%s\n' "$collection"
      return
    fi
    sleep 2
  done
  printf 'error: NRF did not converge to nine registered SBI profiles\n' >&2
  return 1
}

verify_nrf_profiles() {
  local collection profile_url profile_json nf_type expected_fqdn
  local observed_fqdn stale_address
  local -a profile_urls
  collection=$(wait_for_nrf_profiles)
  mapfile -t profile_urls < <(jq -er '._links.item[].href' <<<"$collection")
  if [[ ${#profile_urls[@]} -ne 9 ]]; then
    printf 'error: NRF profile URL count is unexpected\n' >&2
    return 1
  fi
  for profile_url in "${profile_urls[@]}"; do
    profile_json=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      exec "deployment/${CN5G_HELM_RELEASE_NAME}-nrf" --container nrf -- \
      curl --http2-prior-knowledge --fail --silent --show-error \
      "$profile_url")
    nf_type=$(jq -er '.nfType' <<<"$profile_json")
    expected_fqdn="${CN5G_HELM_RELEASE_NAME}-${nf_type,,}."
    expected_fqdn+="${CN5G_KUBERNETES_NAMESPACE}.svc.cluster.local"
    observed_fqdn=$(jq -r '.fqdn // ""' <<<"$profile_json")
    stale_address=$(jq -r \
      '[.ipv4Addresses[]?, .nfServiceList[]?.ipEndPoints[]?.ipv4Address] | map(select(startswith("10.244."))) | length' \
      <<<"$profile_json")
    if [[ $observed_fqdn != "$expected_fqdn" || $stale_address != "0" ]]; then
      printf 'error: NRF profile uses an unstable endpoint: %s\n' \
        "$nf_type" >&2
      printf 'observed_fqdn=%s expected_fqdn=%s pod_addresses=%s\n' \
        "${observed_fqdn:-<none>}" "$expected_fqdn" "$stale_address" >&2
      return 1
    fi
  done
  printf 'nrf_stable_service_profiles=pass count=9\n'
}

nrf_profile_count_once() {
  local collection
  collection=$(get_nrf_collection 2>/dev/null || true)
  nrf_collection_count "${collection:-}"
}

ensure_service_discovery_convergence() {
  local count component
  count=$(nrf_profile_count_once)
  if [[ $count == "9" ]]; then
    verify_nrf_profiles
    printf 'service_discovery_recovery=not-required\n'
    return
  fi
  printf 'nrf_profile_count=%s state=incomplete\n' "$count"
  restart_project_deployment nrf
  for component in udr udm ausf pcf nssf smf; do
    restart_project_deployment "$component"
  done
  restart_project_deployment scp
  restart_project_deployment amf
  verify_nrf_profiles
  printf 'service_discovery_recovery=pass\n'
}

verify_ue_protocol_state() {
  local ue_logs
  ue_logs=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    logs "deployment/${CN5G_HELM_RELEASE_NAME}-ue" --container ue \
    --tail=200)
  if [[ $ue_logs != *"Initial Registration is successful"* || \
        $ue_logs != *"PDU Session establishment is successful"* || \
        $ue_logs != *"TUN interface[uesimtun0"* ]]; then
    printf 'error: UE protocol milestones are incomplete after repair\n' >&2
    return 1
  fi
  printf 'ue_registration=pass\npdu_session=pass\nue_tun=pass\n'
}

wait_for_upf_protocol_state() {
  local upf_logs attempt
  for attempt in $(seq 1 45); do
    upf_logs=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      logs "deployment/${CN5G_HELM_RELEASE_NAME}-upf" --container upf \
      --tail=300 2>/dev/null || true)
    if [[ $upf_logs == *"PFCP associated"* && \
          $upf_logs == *"[Added] Number of UPF-Sessions is now 1"* && \
          $upf_logs == *"gtp_connect()"* ]]; then
      printf 'pfcp_association=pass\npfcp_session=pass\ngtpu_session=pass\n'
      return
    fi
    sleep 2
  done
  printf 'error: UPF did not establish the expected PFCP/GTP-U session\n' >&2
  return 1
}

reconcile_5g_session_chain() {
  # UPF state is keyed to the current SMF PFCP peer. Start a fresh UPF first,
  # then a fresh SMF so the association is learned before the RAN and UE
  # establish a new PDU session.
  restart_project_deployment upf
  restart_project_deployment smf
  verify_nrf_profiles
  restart_project_deployment gnb
  restart_project_deployment ue
  verify_ue_protocol_state
  wait_for_upf_protocol_state
  printf 'session_chain_reconciliation=pass\n'
}

require_deployed_release() {
  local release_json release_status
  release_json=$(helm --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    status "$CN5G_HELM_RELEASE_NAME" --output json)
  release_status=$(jq -er '.info.status' <<<"$release_json")
  if [[ $release_status != "deployed" ]]; then
    printf 'error: Helm release is not deployed: %s\n' \
      "$release_status" >&2
    return 1
  fi
}

bound_pvc_json() {
  local pvc_name pvc_json phase volume storage_class instance component
  pvc_name=mongodb-data-cn5g-mongodb-0
  pvc_json=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" get pvc "$pvc_name" \
    --output json)
  phase=$(jq -r '.status.phase // ""' <<<"$pvc_json")
  volume=$(jq -r '.spec.volumeName // ""' <<<"$pvc_json")
  storage_class=$(jq -r '.spec.storageClassName // ""' <<<"$pvc_json")
  instance=$(jq -r \
    '.metadata.labels["app.kubernetes.io/instance"] // ""' <<<"$pvc_json")
  component=$(jq -r \
    '.metadata.labels["app.kubernetes.io/component"] // ""' <<<"$pvc_json")
  if [[ $phase != "Bound" || -z $volume || \
        $storage_class != "standard" || $instance != "cn5g" || \
        $component != "mongodb" ]]; then
    printf 'error: MongoDB PVC is outside the bound project contract\n' >&2
    printf 'phase=%s volume=%s class=%s instance=%s component=%s\n' \
      "$phase" "${volume:-<none>}" "$storage_class" \
      "$instance" "$component" >&2
    return 1
  fi
  printf '%s\n' "$pvc_json"
}

component_pod_ip() {
  local component=$1
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" get pod \
    --selector "app.kubernetes.io/component=${component},app.kubernetes.io/instance=${CN5G_HELM_RELEASE_NAME}" \
    --output json | jq -er '
      [.items[] | select(.status.phase == "Running") | .status.podIP] |
      if length == 1 then .[0]
      else error("expected exactly one running component Pod")
      end
    '
}

pod_node_interface() {
  local pod_ip=$1 pod_route interface
  pod_route=$(docker exec "$node_container" ip -4 route show "$pod_ip/32")
  interface=$(awk '{for (field = 1; field <= NF; field++) {
    if ($field == "dev") {print $(field + 1); exit}}}' <<<"$pod_route")
  if [[ -z $interface || \
        $pod_route != "$pod_ip dev $interface scope host"* ]]; then
    printf 'error: could not identify Pod node-side interface\n' >&2
    printf 'observed_pod_route=%s\n' "${pod_route:-<absent>}" >&2
    return 1
  fi
  printf '%s\n' "$interface"
}

recognized_n6_route() {
  local route=$1
  [[ $route == "$CN5G_N6_RETURN_SUBNET via 10.244."* && \
     $route == *" dev veth"* && \
     $route == *" proto $CN5G_N6_RETURN_PROTOCOL "* && \
     $route == *" metric $CN5G_N6_RETURN_METRIC "* && \
     $route == *" onlink"* ]]
}

reconcile_n6_return_route() {
  local upf_ip upf_interface existing expected_prefix
  verify_owned_deployment upf
  wait_for_deployment upf
  upf_ip=$(component_pod_ip upf)
  upf_interface=$(pod_node_interface "$upf_ip")
  existing=$(docker exec "$node_container" \
    ip -N -4 route show "$CN5G_N6_RETURN_SUBNET")
  expected_prefix="$CN5G_N6_RETURN_SUBNET via $upf_ip dev $upf_interface"
  if [[ -n $existing ]] && ! recognized_n6_route "$existing"; then
    printf 'error: refusing to replace an unrecognized kind-node route\n' >&2
    printf 'observed_node_return_route=%s\n' "$existing" >&2
    return 1
  fi
  if [[ $existing == "$expected_prefix "* ]]; then
    printf 'kind_node_return_route=%s state=already-current\n' "$existing"
    return
  fi
  if [[ -n $existing ]]; then
    docker exec "$node_container" ip -4 route del \
      "$CN5G_N6_RETURN_SUBNET" proto "$CN5G_N6_RETURN_PROTOCOL" \
      metric "$CN5G_N6_RETURN_METRIC"
    printf 'kind_node_return_route=removed-stale-project-route\n'
  fi
  docker exec "$node_container" ip -4 route add \
    "$CN5G_N6_RETURN_SUBNET" via "$upf_ip" dev "$upf_interface" onlink \
    proto "$CN5G_N6_RETURN_PROTOCOL" metric "$CN5G_N6_RETURN_METRIC"
  existing=$(docker exec "$node_container" \
    ip -N -4 route show "$CN5G_N6_RETURN_SUBNET")
  if [[ $existing != "$expected_prefix "* ]] || \
      ! recognized_n6_route "$existing"; then
    printf 'error: N6 return route did not converge\n' >&2
    printf 'observed_node_return_route=%s\n' \
      "${existing:-<absent>}" >&2
    return 1
  fi
  printf 'kind_node_return_route=%s state=reconciled\n' "$existing"
}

remove_n6_return_route() {
  local existing
  existing=$(docker exec "$node_container" \
    ip -N -4 route show "$CN5G_N6_RETURN_SUBNET")
  if [[ -z $existing ]]; then
    printf 'kind_node_return_route=absent\n'
    return
  fi
  if ! recognized_n6_route "$existing"; then
    printf 'error: refusing to remove an unrecognized kind-node route\n' >&2
    printf 'observed_node_return_route=%s\n' "$existing" >&2
    return 1
  fi
  docker exec "$node_container" ip -4 route del \
    "$CN5G_N6_RETURN_SUBNET" proto "$CN5G_N6_RETURN_PROTOCOL" \
    metric "$CN5G_N6_RETURN_METRIC"
  printf 'kind_node_return_route=removed\n'
}

wait_for_current_subscriber_job() {
  local jobs complete failed attempt
  for attempt in $(seq 1 90); do
    jobs=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" get jobs \
      --selector "app.kubernetes.io/component=subscriber-init,app.kubernetes.io/instance=${CN5G_HELM_RELEASE_NAME}" \
      --output json)
    failed=$(jq -r '[.items[] | select(
      [.status.conditions[]? | select(.type == "Failed" and .status == "True")] |
      length > 0)] | length' <<<"$jobs")
    complete=$(jq -r '[.items[] | select(.status.succeeded == 1)] | length' \
      <<<"$jobs")
    if [[ $failed != "0" ]]; then
      printf 'error: a release-owned subscriber Job failed\n' >&2
      return 1
    fi
    if (( complete >= 1 )); then
      printf 'subscriber_job_completion=pass\n'
      return
    fi
    sleep 2
  done
  printf 'error: no release-owned subscriber Job completed\n' >&2
  return 1
}

converge_deployed_release() {
  local subscriber_job_revision=${1:-} component
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" rollout status \
    "statefulset/${CN5G_HELM_RELEASE_NAME}-mongodb" --timeout=180s
  printf 'mongodb_statefulset_readiness=pass\n'
  if [[ -n $subscriber_job_revision ]]; then
    wait_for_subscriber_job "$subscriber_job_revision"
  else
    wait_for_current_subscriber_job
  fi
  for component in nrf udr udm ausf pcf nssf smf scp amf upf data-network gnb ue; do
    wait_for_deployment "$component"
  done
  verify_runtime_sbi_advertisements
  ensure_service_discovery_convergence
  reconcile_5g_session_chain
  reconcile_n6_return_route
  require_deployed_release
  printf 'helm_release_convergence=pass\n'
}

run_kubernetes_validation() {
  require_deployed_release
  verify_runtime_sbi_advertisements
  verify_nrf_profiles
  reconcile_n6_return_route
  "$validator"
}

run_kubernetes_validation_with_session_repair() {
  local output result
  if output=$(run_kubernetes_validation 2>&1); then
    printf '%s\n' "$output"
    return
  else
    result=$?
  fi
  printf '%s\n' "$output"
  if [[ $output != *"error: UPF PFCP/GTP-U session evidence is incomplete"* ]]; then
    return "$result"
  fi
  printf 'single_ue_session_evidence=stale repair=targeted-session-chain-reconciliation\n'
  reconcile_5g_session_chain
  reconcile_n6_return_route
  run_kubernetes_validation
  printf 'single_ue_session_evidence_repair=pass\n'
}

component_cgroup_sample() {
  local component=$1 workload
  if [[ $component == "mongodb" ]]; then
    workload="statefulset/${CN5G_HELM_RELEASE_NAME}-mongodb"
  else
    workload="deployment/${CN5G_HELM_RELEASE_NAME}-${component}"
  fi
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" exec "$workload" \
    --container "$component" -- sh -ec '
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

component_resource_contract() {
  local component=$1 workload
  if [[ $component == "mongodb" ]]; then
    workload="statefulset/${CN5G_HELM_RELEASE_NAME}-mongodb"
  else
    workload="deployment/${CN5G_HELM_RELEASE_NAME}-${component}"
  fi
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" get "$workload" \
    --output json | jq -er --arg container "$component" '
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

observe_runtime_resources() {
  local component sample cpu memory peak now delta_cpu delta_time
  local cpu_millicores memory_mib peak_mib contract
  local request_cpu request_memory limit_cpu limit_memory
  local -a components=(
    mongodb nrf scp amf ausf udm udr pcf nssf smf upf data-network gnb ue
  )
  local -A cpu_before time_before
  require_deployed_release
  for component in "${components[@]}"; do
    sample=$(component_cgroup_sample "$component")
    read -r cpu _ _ <<<"$sample"
    if [[ ! $cpu =~ ^[0-9]+$ ]]; then
      printf 'error: invalid initial CPU sample for %s\n' "$component" >&2
      return 1
    fi
    cpu_before[$component]=$cpu
    time_before[$component]=$(date +%s%N)
  done
  printf 'resource_observation_window_seconds=10\n'
  sleep 10
  for component in "${components[@]}"; do
    sample=$(component_cgroup_sample "$component")
    now=$(date +%s%N)
    read -r cpu memory peak <<<"$sample"
    if [[ ! $cpu =~ ^[0-9]+$ || ! $memory =~ ^[0-9]+$ || \
          ! $peak =~ ^[0-9]+$ ]]; then
      printf 'error: invalid cgroup sample for %s\n' "$component" >&2
      return 1
    fi
    delta_cpu=$((cpu - cpu_before[$component]))
    delta_time=$((now - time_before[$component]))
    if (( delta_cpu < 0 || delta_time <= 0 )); then
      printf 'error: non-monotonic resource sample for %s\n' "$component" >&2
      return 1
    fi
    cpu_millicores=$(((delta_cpu * 1000000 + delta_time - 1) / delta_time))
    memory_mib=$(((memory + 1048575) / 1048576))
    peak_mib=$(((peak + 1048575) / 1048576))
    contract=$(component_resource_contract "$component")
    IFS='|' read -r request_cpu request_memory limit_cpu limit_memory \
      <<<"$contract"
    printf '%s\n' \
      "component=$component cpu_average_millicores=$cpu_millicores memory_current_mib=$memory_mib memory_peak_mib=$peak_mib request_cpu=$request_cpu request_memory=$request_memory limit_cpu=$limit_cpu limit_memory=$limit_memory"
  done
  printf 'resource_observation=pass scope=single-ue-steady-state\n'
}

mongodb_evidence_collection_absent() {
  local exists
  exists=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" exec \
    "statefulset/${CN5G_HELM_RELEASE_NAME}-mongodb" --container mongodb -- \
    mongosh --quiet open5gs --eval \
    'db.getCollectionNames().includes("cn5g_single_ue_evidence")')
  if [[ $exists != "false" ]]; then
    printf 'error: persistence evidence collection already exists\n' >&2
    return 1
  fi
}

create_mongodb_evidence_marker() {
  mongodb_evidence_collection_absent
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" exec \
    "statefulset/${CN5G_HELM_RELEASE_NAME}-mongodb" --container mongodb -- \
    mongosh --quiet open5gs --eval '
      db.cn5g_single_ue_evidence.insertOne({
        _id: "single_ue-persistence-marker",
        value: "synthetic-persistence-evidence"
      });
    ' >/dev/null
  printf 'persistence_marker=prepared\n'
}

verify_and_remove_mongodb_evidence_marker() {
  local marker_count
  marker_count=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" exec \
    "statefulset/${CN5G_HELM_RELEASE_NAME}-mongodb" --container mongodb -- \
    mongosh --quiet open5gs --eval '
      db.cn5g_single_ue_evidence.countDocuments({
        _id: "single_ue-persistence-marker",
        value: "synthetic-persistence-evidence"
      })
    ')
  if [[ $marker_count != "1" ]]; then
    printf 'error: synthetic persistence marker did not survive\n' >&2
    return 1
  fi
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" exec \
    "statefulset/${CN5G_HELM_RELEASE_NAME}-mongodb" --container mongodb -- \
    mongosh --quiet open5gs --eval \
    'db.cn5g_single_ue_evidence.drop()' >/dev/null
  printf 'persistence_marker=survived\n'
  printf 'persistence_evidence_collection=removed\n'
}

test_mongodb_persistence() {
  local pvc_json pvc_uid pvc_volume repaired_pvc_json
  local mongodb_pod pod_uid recreated_pod_uid attempt
  pvc_json=$(bound_pvc_json)
  pvc_uid=$(jq -er '.metadata.uid' <<<"$pvc_json")
  pvc_volume=$(jq -er '.spec.volumeName' <<<"$pvc_json")
  mongodb_pod=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" get pod \
    --selector "app.kubernetes.io/component=mongodb,app.kubernetes.io/instance=${CN5G_HELM_RELEASE_NAME}" \
    --output json | jq -er \
    'if .items | length == 1 then .items[0].metadata.name else error("expected one MongoDB Pod") end')
  pod_uid=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" get pod "$mongodb_pod" \
    --output jsonpath='{.metadata.uid}')
  create_mongodb_evidence_marker
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" delete pod "$mongodb_pod" \
    --wait=true --timeout=120s
  for attempt in $(seq 1 60); do
    if kubectl --kubeconfig "$kubeconfig" \
        --namespace "$CN5G_KUBERNETES_NAMESPACE" get pod "$mongodb_pod" \
        >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  if ! kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" get pod "$mongodb_pod" \
      >/dev/null 2>&1; then
    printf 'error: replacement MongoDB Pod was not created\n' >&2
    return 1
  fi
  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" rollout status \
    "statefulset/${CN5G_HELM_RELEASE_NAME}-mongodb" --timeout=180s
  recreated_pod_uid=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" get pod "$mongodb_pod" \
    --output jsonpath='{.metadata.uid}')
  if [[ -z $recreated_pod_uid || $recreated_pod_uid == "$pod_uid" ]]; then
    printf 'error: MongoDB Pod identity did not change during recreation\n' >&2
    return 1
  fi
  repaired_pvc_json=$(bound_pvc_json)
  if [[ $(jq -er '.metadata.uid' <<<"$repaired_pvc_json") != "$pvc_uid" || \
        $(jq -er '.spec.volumeName' <<<"$repaired_pvc_json") != "$pvc_volume" ]]; then
    printf 'error: MongoDB PVC identity changed during Pod recreation\n' >&2
    return 1
  fi
  verify_and_remove_mongodb_evidence_marker
  printf 'mongodb_pod_identity=changed\n'
  printf 'mongodb_pvc_identity=preserved\n'
  printf 'mongodb_pod_recreation_persistence=pass\n'
}

write_lifecycle_state() {
  local path=$1
  shift
  if [[ -e $path || -L $path ]]; then
    printf 'error: lifecycle state already exists: %s\n' "$path" >&2
    return 1
  fi
  install -d -m 0700 "$(dirname -- "$path")"
  umask 077
  printf '%s\n' "$@" > "$path"
  chmod 0600 "$path"
}

replace_lifecycle_state() {
  local path=$1
  shift
  if [[ ! -f $path || -L $path ]]; then
    printf 'error: lifecycle state is absent or unsafe: %s\n' "$path" >&2
    return 1
  fi
  umask 077
  printf '%s\n' "$@" > "$path"
  chmod 0600 "$path"
}

migrate_recreate_strategies() {
  local component deployment_json strategy_type rolling_update preview_json
  local migrated_json
  local strategy_patch
  strategy_patch='[
    {"op":"remove","path":"/spec/strategy/rollingUpdate"},
    {"op":"replace","path":"/spec/strategy/type","value":"Recreate"}
  ]'
  for component in nrf scp amf ausf udm udr pcf nssf smf; do
    verify_owned_deployment "$component"
    deployment_json=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" get deployment \
      "${CN5G_HELM_RELEASE_NAME}-${component}" --output json)
    strategy_type=$(jq -r '.spec.strategy.type // ""' <<<"$deployment_json")
    rolling_update=$(jq -r \
      'if .spec.strategy.rollingUpdate == null then "absent" else "present" end' \
      <<<"$deployment_json")
    if [[ $strategy_type == "Recreate" && $rolling_update == "absent" ]]; then
      printf 'deployment=%s strategy_migration=already-current\n' \
        "$component"
      continue
    fi
    if [[ $strategy_type != "RollingUpdate" || \
          $rolling_update != "present" ]]; then
      printf 'error: deployment strategy is outside the migratable contract: %s\n' \
        "$component" >&2
      printf 'strategy_type=%s rolling_update=%s\n' \
        "$strategy_type" "$rolling_update" >&2
      return 1
    fi
    preview_json=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" patch deployment \
      "${CN5G_HELM_RELEASE_NAME}-${component}" --type=json \
      --patch "$strategy_patch" --dry-run=server --output json)
    if [[ $(jq -r '.spec.strategy.type // ""' <<<"$preview_json") != \
            "Recreate" || \
          $(jq -r \
            'if .spec.strategy.rollingUpdate == null then "absent" else "present" end' \
            <<<"$preview_json") != "absent" ]]; then
      printf 'error: server-side strategy migration preview failed: %s\n' \
        "$component" >&2
      return 1
    fi
    kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" patch deployment \
      "${CN5G_HELM_RELEASE_NAME}-${component}" --type=json \
      --patch "$strategy_patch" >/dev/null
    migrated_json=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" get deployment \
      "${CN5G_HELM_RELEASE_NAME}-${component}" --output json)
    if [[ $(jq -r '.spec.strategy.type // ""' <<<"$migrated_json") != \
            "Recreate" || \
          $(jq -r \
            'if .spec.strategy.rollingUpdate == null then "absent" else "present" end' \
            <<<"$migrated_json") != "absent" ]]; then
      printf 'error: deployment strategy migration did not converge: %s\n' \
        "$component" >&2
      return 1
    fi
    printf 'deployment=%s strategy_migration=rolling-update-to-recreate\n' \
      "$component"
  done
  printf 'deployment_strategy_migration=pass\n'
}

migrate_rolling_update_strategies() {
  local component deployment_json strategy_type rolling_update preview_json
  local migrated_json
  local strategy_patch
  strategy_patch='[
    {"op":"replace","path":"/spec/strategy/type","value":"RollingUpdate"}
  ]'
  for component in nrf scp amf ausf udm udr pcf nssf smf; do
    verify_owned_deployment "$component"
    deployment_json=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" get deployment \
      "${CN5G_HELM_RELEASE_NAME}-${component}" --output json)
    strategy_type=$(jq -r '.spec.strategy.type // ""' <<<"$deployment_json")
    rolling_update=$(jq -r \
      'if .spec.strategy.rollingUpdate == null then "absent" else "present" end' \
      <<<"$deployment_json")
    if [[ $strategy_type == "RollingUpdate" && \
          $rolling_update == "present" ]]; then
      printf 'deployment=%s rollback_strategy=already-current\n' "$component"
      continue
    fi
    if [[ $strategy_type != "Recreate" || $rolling_update != "absent" ]]; then
      printf 'error: deployment strategy is outside the rollback contract: %s\n' \
        "$component" >&2
      printf 'strategy_type=%s rolling_update=%s\n' \
        "$strategy_type" "$rolling_update" >&2
      return 1
    fi
    preview_json=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" patch deployment \
      "${CN5G_HELM_RELEASE_NAME}-${component}" --type=json \
      --patch "$strategy_patch" --dry-run=server --output json)
    if [[ $(jq -r '.spec.strategy.type // ""' <<<"$preview_json") != \
            "RollingUpdate" || \
          $(jq -r \
            'if .spec.strategy.rollingUpdate == null then "absent" else "present" end' \
            <<<"$preview_json") != "present" ]]; then
      printf 'error: server-side rollback strategy preview failed: %s\n' \
        "$component" >&2
      return 1
    fi
    kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" patch deployment \
      "${CN5G_HELM_RELEASE_NAME}-${component}" --type=json \
      --patch "$strategy_patch" >/dev/null
    migrated_json=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" get deployment \
      "${CN5G_HELM_RELEASE_NAME}-${component}" --output json)
    if [[ $(jq -r '.spec.strategy.type // ""' <<<"$migrated_json") != \
            "RollingUpdate" || \
          $(jq -r \
            'if .spec.strategy.rollingUpdate == null then "absent" else "present" end' \
            <<<"$migrated_json") != "present" ]]; then
      printf 'error: rollback strategy migration did not converge: %s\n' \
        "$component" >&2
      return 1
    fi
    printf 'deployment=%s rollback_strategy=recreate-to-rolling-update\n' \
      "$component"
  done
  printf 'rollback_strategy_migration=pass\n'
}

read_lifecycle_state() {
  local path=$1 key=$2 value
  if [[ ! -f $path || -L $path || ! -r $path ]]; then
    printf 'error: lifecycle state is absent or unsafe: %s\n' "$path" >&2
    return 1
  fi
  value=$(awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2)}' \
    "$path")
  if [[ -z $value ]]; then
    printf 'error: lifecycle state key is absent: %s\n' "$key" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

controlled_upgrade() {
  local release_json release_status current_revision baseline_revision
  local expected_revision rollout_token state_release state_namespace
  local state_pvc_uid state_pvc_volume pvc_json pvc_uid pvc_volume
  local upgraded_json upgraded_revision
  release_json=$(helm --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    status "$CN5G_HELM_RELEASE_NAME" --output json)
  release_status=$(jq -er '.info.status' <<<"$release_json")
  current_revision=$(jq -er '.version' <<<"$release_json")
  pvc_json=$(bound_pvc_json)
  pvc_uid=$(jq -er '.metadata.uid' <<<"$pvc_json")
  pvc_volume=$(jq -er '.spec.volumeName' <<<"$pvc_json")
  if [[ -e $upgrade_state || -L $upgrade_state ]]; then
    state_release=$(read_lifecycle_state "$upgrade_state" release)
    state_namespace=$(read_lifecycle_state "$upgrade_state" namespace)
    baseline_revision=$(read_lifecycle_state \
      "$upgrade_state" baseline_revision)
    expected_revision=$(read_lifecycle_state \
      "$upgrade_state" expected_upgrade_revision)
    state_pvc_uid=$(read_lifecycle_state "$upgrade_state" pvc_uid)
    state_pvc_volume=$(read_lifecycle_state "$upgrade_state" pvc_volume)
    if [[ $state_release != "$CN5G_HELM_RELEASE_NAME" || \
          $state_namespace != "$CN5G_KUBERNETES_NAMESPACE" || \
          ! $baseline_revision =~ ^[1-9][0-9]*$ || \
          ! $expected_revision =~ ^[1-9][0-9]*$ || \
          $pvc_uid != "$state_pvc_uid" || \
          $pvc_volume != "$state_pvc_volume" ]]; then
      printf 'error: saved upgrade state does not match the live release\n' >&2
      return 1
    fi
    case "$release_status" in
      failed)
        if (( current_revision < expected_revision )); then
          printf 'error: failed revision precedes the saved upgrade attempt\n' \
            >&2
          return 1
        fi
        expected_revision=$((current_revision + 1))
        replace_lifecycle_state "$upgrade_state" \
          "release=$CN5G_HELM_RELEASE_NAME" \
          "namespace=$CN5G_KUBERNETES_NAMESPACE" \
          "baseline_revision=$baseline_revision" \
          "expected_upgrade_revision=$expected_revision" \
          "pvc_uid=$pvc_uid" \
          "pvc_volume=$pvc_volume"
        printf 'controlled_upgrade_resume=failed-revision-%s\n' \
          "$current_revision"
        ;;
      deployed)
        if [[ $current_revision == "$baseline_revision" ]]; then
          printf 'controlled_upgrade_resume=pre-apply-retry\n'
        elif [[ $current_revision == "$expected_revision" ]]; then
          printf 'controlled_upgrade_resume=post-apply-validation\n'
          converge_deployed_release "$expected_revision"
          run_kubernetes_validation
          printf 'helm_upgrade_revision=%s\n' "$current_revision"
          printf 'mongodb_pvc_identity=preserved\n'
          printf 'single_ue_upgrade=pass\n'
          return
        else
          printf 'error: deployed revision does not match saved upgrade state\n' \
            >&2
          return 1
        fi
        ;;
      *)
        printf 'error: upgrade cannot resume from release status: %s\n' \
          "$release_status" >&2
        return 1
        ;;
    esac
  else
    if [[ $release_status != "deployed" ]]; then
      printf 'error: controlled upgrade requires a deployed release; observed=%s\n' \
        "$release_status" >&2
      return 1
    fi
    baseline_revision=$current_revision
    expected_revision=$((baseline_revision + 1))
    write_lifecycle_state "$upgrade_state" \
      "release=$CN5G_HELM_RELEASE_NAME" \
      "namespace=$CN5G_KUBERNETES_NAMESPACE" \
      "baseline_revision=$baseline_revision" \
      "expected_upgrade_revision=$expected_revision" \
      "pvc_uid=$pvc_uid" \
      "pvc_volume=$pvc_volume"
  fi
  rollout_token="upgrade-r${expected_revision}"
  migrate_recreate_strategies
  helm upgrade "$CN5G_HELM_RELEASE_NAME" "$chart" \
    --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    --reuse-values \
    --set-string global.rolloutToken="$rollout_token" \
    --set-string global.ranRolloutToken="$rollout_token" \
    --dry-run=server --hide-secret >/dev/null
  printf 'server_side_upgrade_dry_run=pass\n'
  helm upgrade "$CN5G_HELM_RELEASE_NAME" "$chart" \
    --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    --reuse-values \
    --set-string global.rolloutToken="$rollout_token" \
    --set-string global.ranRolloutToken="$rollout_token"
  printf 'helm_upgrade_submission=pass\n'
  converge_deployed_release "$expected_revision"
  upgraded_json=$(helm --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    status "$CN5G_HELM_RELEASE_NAME" --output json)
  upgraded_revision=$(jq -er '.version' <<<"$upgraded_json")
  if [[ $upgraded_revision != "$expected_revision" ]]; then
    printf 'error: controlled upgrade revision is unexpected: %s\n' \
      "$upgraded_revision" >&2
    return 1
  fi
  pvc_json=$(bound_pvc_json)
  if [[ $(jq -er '.metadata.uid' <<<"$pvc_json") != "$pvc_uid" || \
        $(jq -er '.spec.volumeName' <<<"$pvc_json") != "$pvc_volume" ]]; then
    printf 'error: MongoDB PVC identity changed during upgrade\n' >&2
    return 1
  fi
  run_kubernetes_validation
  printf 'helm_upgrade_revision=%s\n' "$upgraded_revision"
  printf 'mongodb_pvc_identity=preserved\n'
  printf 'single_ue_upgrade=pass\n'
}

controlled_rollback() {
  local state_release state_namespace baseline_revision expected_upgrade
  local expected_pvc_uid expected_pvc_volume current_json current_revision
  local release_status expected_rollback rollback_json rollback_revision pvc_json
  local resume_post_apply=false
  state_release=$(read_lifecycle_state "$upgrade_state" release)
  state_namespace=$(read_lifecycle_state "$upgrade_state" namespace)
  baseline_revision=$(read_lifecycle_state "$upgrade_state" baseline_revision)
  expected_upgrade=$(read_lifecycle_state \
    "$upgrade_state" expected_upgrade_revision)
  expected_pvc_uid=$(read_lifecycle_state "$upgrade_state" pvc_uid)
  expected_pvc_volume=$(read_lifecycle_state "$upgrade_state" pvc_volume)
  if [[ $state_release != "$CN5G_HELM_RELEASE_NAME" || \
        $state_namespace != "$CN5G_KUBERNETES_NAMESPACE" || \
        ! $baseline_revision =~ ^[1-9][0-9]*$ || \
        ! $expected_upgrade =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: upgrade state does not match the release contract\n' >&2
    return 1
  fi
  current_json=$(helm --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    status "$CN5G_HELM_RELEASE_NAME" --output json)
  current_revision=$(jq -er '.version' <<<"$current_json")
  release_status=$(jq -er '.info.status' <<<"$current_json")
  expected_rollback=$(awk -F= \
    '$1 == "expected_rollback_revision" {print $2}' "$upgrade_state")
  if [[ -z $expected_rollback ]]; then
    if [[ $release_status != "deployed" || \
          $current_revision != "$expected_upgrade" ]]; then
      printf 'error: rollback must start from the controlled upgrade revision\n' \
        >&2
      printf 'status=%s revision=%s expected=%s\n' \
        "$release_status" "$current_revision" "$expected_upgrade" >&2
      return 1
    fi
    expected_rollback=$((current_revision + 1))
    replace_lifecycle_state "$upgrade_state" \
      "release=$CN5G_HELM_RELEASE_NAME" \
      "namespace=$CN5G_KUBERNETES_NAMESPACE" \
      "baseline_revision=$baseline_revision" \
      "expected_upgrade_revision=$expected_upgrade" \
      "expected_rollback_revision=$expected_rollback" \
      "pvc_uid=$expected_pvc_uid" \
      "pvc_volume=$expected_pvc_volume"
  elif [[ ! $expected_rollback =~ ^[1-9][0-9]*$ ]]; then
    printf 'error: saved rollback revision is invalid\n' >&2
    return 1
  fi
  case "$release_status:$current_revision" in
    "deployed:$expected_upgrade")
      printf 'controlled_rollback_resume=pre-apply\n'
      ;;
    "deployed:$expected_rollback")
      printf 'controlled_rollback_resume=post-apply-validation\n'
      resume_post_apply=true
      ;;
    "failed:$expected_rollback")
      expected_rollback=$((current_revision + 1))
      replace_lifecycle_state "$upgrade_state" \
        "release=$CN5G_HELM_RELEASE_NAME" \
        "namespace=$CN5G_KUBERNETES_NAMESPACE" \
        "baseline_revision=$baseline_revision" \
        "expected_upgrade_revision=$expected_upgrade" \
        "expected_rollback_revision=$expected_rollback" \
        "pvc_uid=$expected_pvc_uid" \
        "pvc_volume=$expected_pvc_volume"
      printf 'controlled_rollback_resume=failed-revision-%s\n' \
        "$current_revision"
      ;;
    *)
      printf 'error: release state is outside the controlled rollback contract\n' \
        >&2
      printf 'status=%s revision=%s upgrade=%s rollback=%s\n' \
        "$release_status" "$current_revision" "$expected_upgrade" \
        "$expected_rollback" >&2
      return 1
      ;;
  esac
  pvc_json=$(bound_pvc_json)
  if [[ $(jq -er '.metadata.uid' <<<"$pvc_json") != "$expected_pvc_uid" || \
        $(jq -er '.spec.volumeName' <<<"$pvc_json") != "$expected_pvc_volume" ]]; then
    printf 'error: MongoDB PVC identity changed before rollback\n' >&2
    return 1
  fi
  if [[ $resume_post_apply == false ]]; then
    migrate_rolling_update_strategies
    helm rollback "$CN5G_HELM_RELEASE_NAME" "$baseline_revision" \
      --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" --dry-run=server >/dev/null
    printf 'server_side_rollback_dry_run=pass\n'
    helm rollback "$CN5G_HELM_RELEASE_NAME" "$baseline_revision" \
      --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE"
    printf 'helm_rollback_submission=pass\n'
  fi
  converge_deployed_release "$baseline_revision"
  rollback_json=$(helm --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    status "$CN5G_HELM_RELEASE_NAME" --output json)
  rollback_revision=$(jq -er '.version' <<<"$rollback_json")
  if [[ $rollback_revision != "$expected_rollback" ]]; then
    printf 'error: rollback result revision is unexpected: %s\n' \
      "$rollback_revision" >&2
    return 1
  fi
  pvc_json=$(bound_pvc_json)
  if [[ $(jq -er '.metadata.uid' <<<"$pvc_json") != "$expected_pvc_uid" || \
        $(jq -er '.spec.volumeName' <<<"$pvc_json") != "$expected_pvc_volume" ]]; then
    printf 'error: MongoDB PVC identity changed during rollback\n' >&2
    return 1
  fi
  run_kubernetes_validation
  rm -f -- "$upgrade_state"
  printf 'helm_rollback_target_revision=%s\n' "$baseline_revision"
  printf 'helm_rollback_result_revision=%s\n' "$rollback_revision"
  printf 'mongodb_pvc_identity=preserved\n'
  printf 'single_ue_rollback=pass\n'
}

remove_completed_historical_subscriber_jobs() {
  local jobs unexpected job_name removed=0
  jobs=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" get jobs \
    --selector "app.kubernetes.io/component=subscriber-init,app.kubernetes.io/instance=${CN5G_HELM_RELEASE_NAME}" \
    --output json)
  unexpected=$(jq -r --arg release "$CN5G_HELM_RELEASE_NAME" \
    --arg namespace "$CN5G_KUBERNETES_NAMESPACE" '
      .items[] | select(
        (.metadata.name | test("^" + $release + "-subscriber-init-r[1-9][0-9]*$") | not) or
        .metadata.labels["app.kubernetes.io/managed-by"] != "Helm" or
        .metadata.annotations["meta.helm.sh/release-name"] != $release or
        .metadata.annotations["meta.helm.sh/release-namespace"] != $namespace or
        ([.status.conditions[]? |
          select(.type == "Complete" and .status == "True")] | length) != 1 or
        ([.status.conditions[]? |
          select(.type == "Failed" and .status == "True")] | length) != 0
      ) | .metadata.name
    ' <<<"$jobs")
  if [[ -n $unexpected ]]; then
    printf 'error: refusing to remove subscriber Jobs outside the completed Helm ownership contract:\n%s\n' \
      "$unexpected" >&2
    return 1
  fi
  while IFS= read -r job_name; do
    [[ -z $job_name ]] && continue
    kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" delete job "$job_name" \
      --wait=true --timeout=90s
    removed=$((removed + 1))
  done < <(jq -r '.items[].metadata.name' <<<"$jobs")
  printf 'historical_subscriber_jobs_removed=%s\n' "$removed"
}

scoped_uninstall() {
  local release_json release_revision pvc_json pvc_uid pvc_volume
  local state_release state_namespace state_revision state_pvc_uid
  local state_pvc_volume remaining attempt retained_pvc_json
  local release_present=false
  verify_secret
  if [[ -e $uninstall_state || -L $uninstall_state ]]; then
    state_release=$(read_lifecycle_state "$uninstall_state" release)
    state_namespace=$(read_lifecycle_state "$uninstall_state" namespace)
    state_revision=$(read_lifecycle_state \
      "$uninstall_state" uninstalled_revision)
    state_pvc_uid=$(read_lifecycle_state "$uninstall_state" pvc_uid)
    state_pvc_volume=$(read_lifecycle_state "$uninstall_state" pvc_volume)
    pvc_json=$(bound_pvc_json)
    pvc_uid=$(jq -er '.metadata.uid' <<<"$pvc_json")
    pvc_volume=$(jq -er '.spec.volumeName' <<<"$pvc_json")
    if [[ $state_release != "$CN5G_HELM_RELEASE_NAME" || \
          $state_namespace != "$CN5G_KUBERNETES_NAMESPACE" || \
          ! $state_revision =~ ^[1-9][0-9]*$ || \
          $state_pvc_uid != "$pvc_uid" || \
          $state_pvc_volume != "$pvc_volume" ]]; then
      printf 'error: saved uninstall state does not match retained resources\n' \
        >&2
      return 1
    fi
    if release_json=$(helm --kubeconfig "$kubeconfig" \
        --namespace "$CN5G_KUBERNETES_NAMESPACE" \
        status "$CN5G_HELM_RELEASE_NAME" --output json 2>/dev/null); then
      release_present=true
      release_revision=$(jq -er '.version' <<<"$release_json")
      if [[ $(jq -er '.info.status' <<<"$release_json") != "deployed" || \
            $release_revision != "$state_revision" ]]; then
        printf 'error: live release does not match saved uninstall state\n' >&2
        return 1
      fi
      printf 'scoped_uninstall_resume=pre-release-removal\n'
    else
      printf 'scoped_uninstall_resume=post-release-removal\n'
    fi
  else
    require_deployed_release
    release_present=true
    release_json=$(helm --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      status "$CN5G_HELM_RELEASE_NAME" --output json)
    release_revision=$(jq -er '.version' <<<"$release_json")
    pvc_json=$(bound_pvc_json)
    pvc_uid=$(jq -er '.metadata.uid' <<<"$pvc_json")
    pvc_volume=$(jq -er '.spec.volumeName' <<<"$pvc_json")
    create_mongodb_evidence_marker
    write_lifecycle_state "$uninstall_state" \
      "release=$CN5G_HELM_RELEASE_NAME" \
      "namespace=$CN5G_KUBERNETES_NAMESPACE" \
      "uninstalled_revision=$release_revision" \
      "pvc_uid=$pvc_uid" \
      "pvc_volume=$pvc_volume"
  fi
  remove_n6_return_route
  if [[ $release_present == true ]]; then
    helm uninstall "$CN5G_HELM_RELEASE_NAME" \
      --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      --wait --timeout=5m
  fi
  remove_completed_historical_subscriber_jobs
  for attempt in $(seq 1 60); do
    remaining=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      get all,configmaps,serviceaccounts \
      --selector "app.kubernetes.io/instance=${CN5G_HELM_RELEASE_NAME}" \
      --output name)
    [[ -z $remaining ]] && break
    sleep 2
  done
  if [[ -n $remaining ]]; then
    printf 'error: Helm-owned resources remain after uninstall:\n%s\n' \
      "$remaining" >&2
    return 1
  fi
  retained_pvc_json=$(bound_pvc_json)
  if [[ $(jq -er '.metadata.uid' <<<"$retained_pvc_json") != "$pvc_uid" || \
        $(jq -er '.spec.volumeName' <<<"$retained_pvc_json") != "$pvc_volume" ]]; then
    printf 'error: retained MongoDB PVC identity changed during uninstall\n' >&2
    return 1
  fi
  verify_namespace
  verify_secret
  printf 'helm_release=absent\n'
  printf 'mongodb_pvc=retained-bound\n'
  printf 'namespace=retained-project-owned\n'
  printf 'subscriber_secret=retained-project-owned\n'
  printf 'single_ue_uninstall=pass\n'
}

verify_reinstall_persistence() {
  local state_release state_namespace expected_pvc_uid expected_pvc_volume
  local pvc_json
  require_deployed_release
  state_release=$(read_lifecycle_state "$uninstall_state" release)
  state_namespace=$(read_lifecycle_state "$uninstall_state" namespace)
  expected_pvc_uid=$(read_lifecycle_state "$uninstall_state" pvc_uid)
  expected_pvc_volume=$(read_lifecycle_state "$uninstall_state" pvc_volume)
  if [[ $state_release != "$CN5G_HELM_RELEASE_NAME" || \
        $state_namespace != "$CN5G_KUBERNETES_NAMESPACE" ]]; then
    printf 'error: uninstall state does not match the release contract\n' >&2
    return 1
  fi
  pvc_json=$(bound_pvc_json)
  if [[ $(jq -er '.metadata.uid' <<<"$pvc_json") != "$expected_pvc_uid" || \
        $(jq -er '.spec.volumeName' <<<"$pvc_json") != "$expected_pvc_volume" ]]; then
    printf 'error: MongoDB PVC identity changed across uninstall/reinstall\n' >&2
    return 1
  fi
  verify_and_remove_mongodb_evidence_marker
  rm -f -- "$uninstall_state"
  printf 'mongodb_pvc_identity=preserved\n'
  printf 'helm_reinstall_persistence=pass\n'
}

recover_failed_install() {
  local release_json release_status release_count release_present=false
  local pvc_name pvc_json pvc_phase pvc_volume pvc_class pvc_present=false
  local pvc_instance pvc_component remaining attempt
  pvc_name=mongodb-data-cn5g-mongodb-0
  if release_json=$(helm --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      status "$CN5G_HELM_RELEASE_NAME" --output json 2>/dev/null); then
    release_status=$(jq -er '.info.status' <<<"$release_json")
    if [[ $release_status != "failed" ]]; then
      printf 'error: recovery only accepts a failed release; observed=%s\n' \
        "$release_status" >&2
      return 1
    fi
    release_present=true
  else
    release_count=$(helm --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" list \
      --filter "^${CN5G_HELM_RELEASE_NAME}$" --output json | jq -er 'length')
    if [[ $release_count != "0" ]]; then
      printf 'error: release state is not safely recoverable\n' >&2
      return 1
    fi
  fi
  pvc_json=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" get pvc "$pvc_name" \
    --ignore-not-found --output json)
  if [[ -n $pvc_json ]]; then
    pvc_present=true
    pvc_phase=$(jq -r '.status.phase // ""' <<<"$pvc_json")
    pvc_volume=$(jq -r '.spec.volumeName // ""' <<<"$pvc_json")
    pvc_class=$(jq -r '.spec.storageClassName // ""' <<<"$pvc_json")
    pvc_instance=$(jq -r \
      '.metadata.labels["app.kubernetes.io/instance"] // ""' <<<"$pvc_json")
    pvc_component=$(jq -r \
      '.metadata.labels["app.kubernetes.io/component"] // ""' <<<"$pvc_json")
    if [[ $pvc_phase != "Pending" || -n $pvc_volume || \
          $pvc_class != "local-path" || $pvc_instance != "cn5g" || \
          $pvc_component != "mongodb" ]]; then
      printf 'error: refusing to remove PVC outside the failed unbound contract\n' \
        >&2
      printf 'phase=%s volume=%s class=%s instance=%s component=%s\n' \
        "$pvc_phase" "${pvc_volume:-<none>}" "$pvc_class" \
        "$pvc_instance" "$pvc_component" >&2
      return 1
    fi
  fi
  if [[ $release_present == true ]]; then
    printf 'failed_release=%s status=verified\n' "$CN5G_HELM_RELEASE_NAME"
    helm uninstall "$CN5G_HELM_RELEASE_NAME" \
      --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      --wait --timeout=3m
  else
    printf 'failed_release=%s state=already-absent\n' \
      "$CN5G_HELM_RELEASE_NAME"
  fi
  if [[ $pvc_present == true ]]; then
    printf 'unbound_pvc=%s state=verified-pending-without-volume\n' "$pvc_name"
    kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" delete pvc "$pvc_name" \
      --wait=true --timeout=60s
  else
    printf 'unbound_pvc=%s state=already-absent\n' "$pvc_name"
  fi
  if helm --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      status "$CN5G_HELM_RELEASE_NAME" >/dev/null 2>&1; then
    printf 'error: failed Helm release still exists after recovery\n' >&2
    return 1
  fi
  if kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      get pvc "$pvc_name" >/dev/null 2>&1; then
    printf 'error: unbound PVC still exists after recovery\n' >&2
    return 1
  fi
  for attempt in $(seq 1 60); do
    remaining=$(kubectl --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      get all,configmaps,serviceaccounts \
      --selector app.kubernetes.io/instance=cn5g --output name)
    [[ -z $remaining ]] && break
    sleep 2
  done
  if [[ -n $remaining ]]; then
    printf 'error: release-owned resources remain after recovery\n%s\n' \
      "$remaining" >&2
    return 1
  fi
  verify_namespace
  verify_secret
  printf 'failed_install_recovery=pass\n'
}

repair_failed_release() {
  local release_json release_status release_version next_revision rollout_token
  local pvc_name pvc_json pvc_phase pvc_volume
  local pvc_class pvc_instance pvc_component pvc_uid repaired_pvc_json
  local repaired_pvc_uid repaired_pvc_volume ue_available component
  pvc_name=mongodb-data-cn5g-mongodb-0
  release_json=$(helm --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    status "$CN5G_HELM_RELEASE_NAME" --output json)
  release_status=$(jq -er '.info.status' <<<"$release_json")
  case "$release_status" in
    failed)
      printf 'failed_release=%s status=verified\n' \
        "$CN5G_HELM_RELEASE_NAME"
      ;;
    deployed)
      ue_available=$(kubectl --kubeconfig "$kubeconfig" \
        --namespace "$CN5G_KUBERNETES_NAMESPACE" \
        get deployment "${CN5G_HELM_RELEASE_NAME}-ue" \
        --output json | jq -r '.status.availableReplicas // 0')
      if [[ $ue_available != "0" ]]; then
        printf 'error: release is already deployed and UE is available\n' >&2
        return 1
      fi
      printf 'incomplete_release=%s status=deployed-ue-unavailable\n' \
        "$CN5G_HELM_RELEASE_NAME"
      ;;
    *)
      printf 'error: repair requires a failed or incomplete release; observed=%s\n' \
        "$release_status" >&2
      return 1
      ;;
  esac
  release_version=$(jq -er \
    '.version | select(type == "number" and . >= 1)' <<<"$release_json")
  next_revision=$((release_version + 1))
  rollout_token="repair-r${next_revision}"
  pvc_json=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" get pvc "$pvc_name" \
    --output json)
  pvc_phase=$(jq -r '.status.phase // ""' <<<"$pvc_json")
  pvc_volume=$(jq -r '.spec.volumeName // ""' <<<"$pvc_json")
  pvc_class=$(jq -r '.spec.storageClassName // ""' <<<"$pvc_json")
  pvc_instance=$(jq -r \
    '.metadata.labels["app.kubernetes.io/instance"] // ""' <<<"$pvc_json")
  pvc_component=$(jq -r \
    '.metadata.labels["app.kubernetes.io/component"] // ""' <<<"$pvc_json")
  pvc_uid=$(jq -er '.metadata.uid' <<<"$pvc_json")
  if [[ $pvc_phase != "Bound" || -z $pvc_volume || \
        $pvc_class != "standard" || $pvc_instance != "cn5g" || \
        $pvc_component != "mongodb" ]]; then
    printf 'error: failed release PVC is outside the bound repair contract\n' \
      >&2
    printf 'phase=%s volume=%s class=%s instance=%s component=%s\n' \
      "$pvc_phase" "${pvc_volume:-<none>}" "$pvc_class" \
      "$pvc_instance" "$pvc_component" >&2
    return 1
  fi
  printf 'mongodb_pvc=%s state=bound-and-preserved\n' "$pvc_name"
  printf 'repair_rollout_token=%s\n' "$rollout_token"
  helm upgrade "$CN5G_HELM_RELEASE_NAME" "$chart" \
    --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    --reuse-values --set-string global.ranRolloutToken="$rollout_token" \
    --dry-run=server --hide-secret >/dev/null
  printf 'server_side_upgrade_dry_run=pass\n'
  helm upgrade "$CN5G_HELM_RELEASE_NAME" "$chart" \
    --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    --reuse-values --set-string global.ranRolloutToken="$rollout_token"
  printf 'helm_upgrade_submission=pass\n'

  kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    rollout status "statefulset/${CN5G_HELM_RELEASE_NAME}-mongodb" \
    --timeout=120s
  printf 'mongodb_statefulset_readiness=pass\n'
  wait_for_subscriber_job "$next_revision"
  for component in nrf udr udm ausf pcf nssf smf scp amf upf data-network; do
    wait_for_deployment "$component"
  done
  verify_runtime_sbi_advertisements

  restart_project_deployment nrf
  for component in udr udm ausf pcf nssf smf; do
    restart_project_deployment "$component"
  done
  restart_project_deployment scp
  restart_project_deployment amf
  verify_nrf_profiles
  reconcile_5g_session_chain
  reconcile_n6_return_route

  repaired_pvc_json=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" get pvc "$pvc_name" \
    --output json)
  repaired_pvc_uid=$(jq -er '.metadata.uid' <<<"$repaired_pvc_json")
  repaired_pvc_volume=$(jq -er '.spec.volumeName' <<<"$repaired_pvc_json")
  if [[ $repaired_pvc_uid != "$pvc_uid" || \
        $repaired_pvc_volume != "$pvc_volume" ]]; then
    printf 'error: MongoDB PVC identity changed during repair\n' >&2
    return 1
  fi
  printf 'mongodb_pvc_identity=preserved\n'
  release_json=$(helm --kubeconfig "$kubeconfig" \
    --namespace "$CN5G_KUBERNETES_NAMESPACE" \
    status "$CN5G_HELM_RELEASE_NAME" --output json)
  release_status=$(jq -er '.info.status' <<<"$release_json")
  if [[ $release_status != "deployed" ]]; then
    printf 'error: repaired Helm release is not deployed: %s\n' \
      "$release_status" >&2
    return 1
  fi
  printf 'helm_release_status=deployed\n'
  show_status
  printf 'single_ue_failed_release_repair=pass\n'
}

case "$action" in
  preflight)
    "$script_dir/cluster-lifecycle.sh" preflight
    "$script_dir/install-helm.sh" --check
    "$script_dir/generate-subscriber-secret.sh" --check
    verify_images
    helm lint "$chart" --strict --values "$single_ue_profile"
    render_dir=$(mktemp -d)
    trap 'rm -rf -- "$render_dir"' EXIT
    helm template "$CN5G_HELM_RELEASE_NAME" "$chart" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" --kube-version 1.36.1 \
      --values "$single_ue_profile" \
      > "$render_dir/first.yaml"
    helm template "$CN5G_HELM_RELEASE_NAME" "$chart" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" --kube-version 1.36.1 \
      --values "$single_ue_profile" \
      > "$render_dir/second.yaml"
    cmp --silent "$render_dir/first.yaml" "$render_dir/second.yaml"
    printf 'deterministic_chart_render=pass\n'
    printf 'single_ue_preflight=pass\n'
    ;;
  load-images)
    require_cluster
    verify_images
    stage_mongodb_load_reference
    if node_verification=$(verify_node_images 2>/dev/null); then
      printf 'node_image_import=skipped-already-present-and-accepted\n'
      printf '%s\n' "$node_verification"
    else
      kind load docker-image --name "$KIND_CLUSTER_NAME" \
        "$OPEN5GS_LOCAL_IMAGE" "$UERANSIM_LOCAL_IMAGE" \
        "$DATA_NETWORK_LOCAL_IMAGE" "$mongodb_load_reference"
      printf 'node_image_import=completed\n'
      verify_node_images
    fi
    printf 'single_ue_image_load=pass\n'
    ;;
  prepare-secret)
    require_cluster
    "$script_dir/generate-subscriber-secret.sh" --check
    if ! kubectl --kubeconfig "$kubeconfig" get namespace \
        "$CN5G_KUBERNETES_NAMESPACE" >/dev/null 2>&1; then
      kubectl --kubeconfig "$kubeconfig" create namespace \
        "$CN5G_KUBERNETES_NAMESPACE"
      kubectl --kubeconfig "$kubeconfig" label namespace \
        "$CN5G_KUBERNETES_NAMESPACE" \
        app.kubernetes.io/part-of=cn5g-core \
        app.kubernetes.io/managed-by=cn5g-platform
    fi
    verify_namespace
    if ! kubectl --kubeconfig "$kubeconfig" \
        --namespace "$CN5G_KUBERNETES_NAMESPACE" \
        get secret "$secret_name" >/dev/null 2>&1; then
      kubectl --kubeconfig "$kubeconfig" \
        --namespace "$CN5G_KUBERNETES_NAMESPACE" \
        create secret generic "$secret_name" \
        --from-file=ue.yaml="$secret_dir/ue.yaml" \
        --from-file=subscriber-init.js="$secret_dir/subscriber-init.js" \
        --from-file=imsi="$secret_dir/imsi"
      kubectl --kubeconfig "$kubeconfig" \
        --namespace "$CN5G_KUBERNETES_NAMESPACE" label secret "$secret_name" \
        app.kubernetes.io/part-of=cn5g-core \
        app.kubernetes.io/managed-by=cn5g-platform
    fi
    verify_secret
    printf 'single_ue_secret_preparation=pass\n'
    ;;
  install)
    require_cluster
    verify_images
    verify_node_images
    verify_secret
    if helm --kubeconfig "$kubeconfig" \
        --namespace "$CN5G_KUBERNETES_NAMESPACE" \
        status "$CN5G_HELM_RELEASE_NAME" >/dev/null 2>&1; then
      printf 'error: release already exists: %s\n' \
        "$CN5G_HELM_RELEASE_NAME" >&2
      exit 20
    fi
    helm install "$CN5G_HELM_RELEASE_NAME" "$chart" \
      --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      --values "$single_ue_profile" \
      --dry-run=server --hide-secret >/dev/null
    printf 'server_side_dry_run=pass\n'
    helm install "$CN5G_HELM_RELEASE_NAME" "$chart" \
      --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      --values "$single_ue_profile" \
      --wait=watcher --wait-for-jobs --timeout=8m
    installed_revision=$(helm --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      status "$CN5G_HELM_RELEASE_NAME" --output json | \
      jq -er '.version')
    converge_deployed_release "$installed_revision"
    show_status
    printf 'single_ue_install=pass\n'
    ;;
  validate)
    require_cluster
    verify_secret
    run_kubernetes_validation_with_session_repair
    printf 'single_ue_validation=pass\n'
    ;;
  observe-resources)
    require_cluster
    observe_runtime_resources
    ;;
  test-persistence)
    require_cluster
    require_deployed_release
    test_mongodb_persistence
    ;;
  upgrade)
    require_cluster
    verify_images
    verify_node_images
    verify_secret
    controlled_upgrade
    ;;
  rollback)
    require_cluster
    verify_secret
    controlled_rollback
    ;;
  uninstall)
    require_cluster
    scoped_uninstall
    ;;
  verify-reinstall)
    require_cluster
    verify_secret
    verify_reinstall_persistence
    ;;
  repair-failed-release)
    require_cluster
    verify_images
    verify_node_images
    verify_secret
    repair_failed_release
    ;;
  recover-failed-install)
    require_cluster
    verify_namespace
    verify_secret
    recover_failed_install
    ;;
  status)
    show_status
    ;;
esac
