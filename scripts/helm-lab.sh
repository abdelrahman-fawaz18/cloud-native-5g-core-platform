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
  status          Show only the release and namespace-scoped workload state.

Cluster creation and deletion remain owned by kind-feasibility.sh. This helper
does not print Secret values, use the default kubeconfig, publish host ports,
alter host routes, delete persistent data, or invoke a Docker prune operation.
EOF
}

action=${1:-}
if [[ $action == "-h" || $action == "--help" ]]; then
  usage
  exit 0
fi
case "$action" in
  preflight|load-images|prepare-secret|install|status) ;;
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
  docker exec cn5g-control-plane crictl inspecti \
    "$OPEN5GS_LOCAL_IMAGE" >/dev/null
  docker exec cn5g-control-plane crictl inspecti \
    "$UERANSIM_LOCAL_IMAGE" >/dev/null
  docker exec cn5g-control-plane crictl inspecti \
    "$DATA_NETWORK_LOCAL_IMAGE" >/dev/null
  docker exec cn5g-control-plane crictl inspecti \
    "$MONGODB_IMAGE" >/dev/null
  printf 'node_runtime_image_verification=pass\n'
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
    kind load docker-image --name "$KIND_CLUSTER_NAME" \
      "$OPEN5GS_LOCAL_IMAGE" "$UERANSIM_LOCAL_IMAGE" \
      "$DATA_NETWORK_LOCAL_IMAGE" "$mongodb_load_reference"
    verify_node_images
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
  status)
    show_status
    ;;
esac
