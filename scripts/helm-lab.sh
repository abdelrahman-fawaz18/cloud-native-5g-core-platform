#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: sudo scripts/helm-lab.sh ACTION

Actions:
  preflight       Run host/cluster collision checks and verify Helm, chart,
                  local images, and ignored subscriber material.
  load-images     Load only the accepted Phase 2 images into cluster cn5g.
  prepare-secret  Create or verify the exact namespace and file-backed Secret.
  install         Server-dry-run and install the cn5g release, waiting for Jobs
                  and long-running workload readiness.
  recover-failed-install --confirm
                  Remove only a failed release and its verified unbound PVC;
                  preserve the namespace and subscriber Secret for retry.
  status          Show only the release and namespace-scoped workload state.

Cluster creation and deletion remain owned by kind-feasibility.sh. This helper
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
  preflight|load-images|prepare-secret|install|recover-failed-install|status) ;;
  *)
    printf 'error: unknown action: %s\n' "${action:-<empty>}" >&2
    usage >&2
    exit 2
    ;;
esac
confirmation=${2:-}
if [[ $action == "recover-failed-install" && $confirmation != "--confirm" ]]; then
  printf 'error: recover-failed-install requires --confirm\n' >&2
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

for required_command in docker kind kubectl helm jq sha256sum tar; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'error: required command is unavailable: %s\n' \
      "$required_command" >&2
    exit 4
  fi
done

phase02="$project_root/versions/phase-02.env"
phase03="$project_root/versions/phase-03.env"
phase04="$project_root/versions/phase-04.env"
chart="$project_root/charts/cn5g"
kubeconfig="$project_root/artifacts/kubernetes/cn5g.kubeconfig"
secret_dir="$project_root/artifacts/secrets/phase-04"
secret_name=cn5g-subscriber

for required_file in "$phase02" "$phase03" "$phase04" \
  "$chart/Chart.yaml" "$chart/values.yaml" \
  "$script_dir/install-helm.sh" "$script_dir/generate-subscriber-secret.sh"; do
  if [[ ! -r $required_file ]]; then
    printf 'error: required file is missing or unreadable: %s\n' \
      "$required_file" >&2
    exit 4
  fi
done

# shellcheck source=../versions/phase-02.env
source "$phase02"
# shellcheck source=../versions/phase-03.env
source "$phase03"
# shellcheck source=../versions/phase-04.env
source "$phase04"

mongodb_load_reference=${MONGODB_IMAGE%@sha256:*}
mongodb_repository=${mongodb_load_reference%:*}
mongodb_expected_repo_digest="${mongodb_repository}@${MONGODB_IMAGE##*@}"

required_variables=(
  OPEN5GS_LOCAL_IMAGE OPEN5GS_LOCAL_IMAGE_ID
  UERANSIM_LOCAL_IMAGE UERANSIM_LOCAL_IMAGE_ID
  DATA_NETWORK_LOCAL_IMAGE DATA_NETWORK_LOCAL_IMAGE_ID
  MONGODB_IMAGE KIND_CLUSTER_NAME KIND_CONTEXT_NAME
  CN5G_HELM_RELEASE_NAME CN5G_KUBERNETES_NAMESPACE
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
      $CN5G_KUBERNETES_NAMESPACE != "cn5g" ]]; then
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
  if [[ $namespace_owner != "cn5g-helm-lab" ]]; then
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
  if [[ $secret_owner != "cn5g-helm-lab" ]]; then
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

case "$action" in
  preflight)
    "$script_dir/kind-feasibility.sh" preflight
    "$script_dir/install-helm.sh" --check
    "$script_dir/generate-subscriber-secret.sh" --check
    verify_images
    helm lint "$chart" --strict
    render_dir=$(mktemp -d)
    trap 'rm -rf -- "$render_dir"' EXIT
    helm template "$CN5G_HELM_RELEASE_NAME" "$chart" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" --kube-version 1.36.1 \
      > "$render_dir/first.yaml"
    helm template "$CN5G_HELM_RELEASE_NAME" "$chart" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" --kube-version 1.36.1 \
      > "$render_dir/second.yaml"
    cmp --silent "$render_dir/first.yaml" "$render_dir/second.yaml"
    printf 'deterministic_chart_render=pass\n'
    printf 'phase04_preflight=pass\n'
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
    printf 'phase04_image_load=pass\n'
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
        app.kubernetes.io/managed-by=cn5g-helm-lab
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
        app.kubernetes.io/managed-by=cn5g-helm-lab
    fi
    verify_secret
    printf 'phase04_secret_preparation=pass\n'
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
      --dry-run=server --hide-secret >/dev/null
    printf 'server_side_dry_run=pass\n'
    helm install "$CN5G_HELM_RELEASE_NAME" "$chart" \
      --kubeconfig "$kubeconfig" \
      --namespace "$CN5G_KUBERNETES_NAMESPACE" \
      --wait=watcher --wait-for-jobs --timeout=8m
    show_status
    printf 'phase04_install=pass\n'
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
