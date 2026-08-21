#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/cn5g-platform.sh COMMAND [OPTIONS]

Platform commands:
  preflight                      Check the host, cluster boundary, images,
                                 profiles, and deterministic Helm rendering.
  deploy [--profile NAME]        Create the project cluster when absent and
                                 deploy a validated configuration. NAME is
                                 default, core-only, resource-limited, or
                                 single-ue. The default is the accepted
                                 five-UE/two-DNN platform with observability.
  validate                       Validate the active 5G service and, when
                                 installed, the observability stack.
  status                         Show the project cluster and release state.
  dashboard                      Expose Grafana only on 127.0.0.1:13000.
  test alerts                    Exercise the three bounded alert lifecycles.
  test persistence              Recreate MongoDB and verify retained data.
  test subscriber-recovery      Remove and restore one managed subscriber.
  campaign performance ACTION   Run a performance action: prepare, pilot,
                                 run, analyze, status, or rollback.
  campaign resilience ACTION    Run a resilience action: pilot-amf,
                                 pilot-smf, pilot-upf, run, analyze, or status.
  verify supply-chain           Run the local integration and supply-chain gate.
  verify release                Bind the local release gate to the current commit.
  destroy --confirm             Delete only the named cn5g kind cluster and
                                 its project-owned local-path data.

The command never uses the default kubeconfig, publishes Grafana beyond
loopback, prunes Docker, or modifies the protected host Open5GS installation.
EOF
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(cd -- "$script_dir/.." && pwd -P)
[[ ${project_root##*/} == cloud-native-5g-core-platform ]] || {
  printf 'error: refusing to run outside the expected repository\n' >&2
  exit 3
}

command_name=${1:-}
shift || true

require_operator_sudo() {
  if (( EUID != 0 )) || [[ -z ${SUDO_UID:-} || -z ${SUDO_GID:-} ]]; then
    printf 'error: run this command through sudo from the normal account\n' >&2
    return 1
  fi
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq cn5g
}

ensure_cluster() {
  if cluster_exists; then
    "$script_dir/cluster-lifecycle.sh" status >/dev/null
    printf 'cluster=cn5g state=already-ready\n'
  else
    "$script_dir/cluster-lifecycle.sh" preflight
    "$script_dir/cluster-lifecycle.sh" create
  fi
}

ensure_namespace() {
  local kubeconfig="$project_root/artifacts/kubernetes/cn5g.kubeconfig"
  if ! kubectl --kubeconfig "$kubeconfig" get namespace cn5g >/dev/null 2>&1; then
    kubectl --kubeconfig "$kubeconfig" create namespace cn5g
  fi
  kubectl --kubeconfig "$kubeconfig" label namespace cn5g \
    app.kubernetes.io/part-of=cn5g-core \
    app.kubernetes.io/managed-by=cn5g-platform --overwrite >/dev/null
}

active_core_profile() {
  local kubeconfig="$project_root/artifacts/kubernetes/cn5g.kubeconfig"
  local values platform_enabled telemetry_enabled performance_enabled mongo_request
  if ! helm --kubeconfig "$kubeconfig" --namespace cn5g \
      status cn5g >/dev/null 2>&1; then
    printf 'absent\n'
    return
  fi
  values=$(helm --kubeconfig "$kubeconfig" --namespace cn5g \
    get values cn5g --all --output json)
  platform_enabled=$(jq -er '.platform.enabled' <<<"$values")
  telemetry_enabled=$(jq -er '.observability.enabled' <<<"$values")
  performance_enabled=$(jq -er '.performance.enabled' <<<"$values")
  mongo_request=$(jq -er '.mongodb.resources.requests.memory' <<<"$values")
  if [[ $platform_enabled == false ]]; then
    printf 'single-ue\n'
  elif [[ $performance_enabled == true ]]; then
    printf 'performance\n'
  elif [[ $telemetry_enabled == true ]]; then
    printf 'default\n'
  elif [[ $mongo_request == 192Mi ]]; then
    printf 'resource-limited\n'
  else
    printf 'core-only\n'
  fi
}

guard_profile_selection() {
  local requested=$1 active
  active=$(active_core_profile)
  if [[ $active != absent && $active != "$requested" ]]; then
    printf 'error: active profile %s differs from requested profile %s\n' \
      "$active" "$requested" >&2
    printf 'next_step=sudo ./scripts/cn5g-platform.sh destroy --confirm; then deploy the requested profile\n' >&2
    return 1
  fi
  printf 'profile_selection=pass requested=%s active=%s\n' "$requested" "$active"
}

ensure_images() {
  # shellcheck source=../versions/compose-runtime.env
  source "$project_root/versions/compose-runtime.env"
  local image missing=false
  for image in "$OPEN5GS_LOCAL_IMAGE" "$UERANSIM_LOCAL_IMAGE" \
    "$DATA_NETWORK_LOCAL_IMAGE"; do
    docker image inspect "$image" >/dev/null 2>&1 || missing=true
  done
  if [[ $missing == true ]]; then
    "$script_dir/compose-reference.sh" build
  fi
  docker image inspect "$MONGODB_IMAGE" >/dev/null 2>&1 || \
    docker pull "$MONGODB_IMAGE" >/dev/null
  "$script_dir/single-ue-lifecycle.sh" load-images
}

deploy_profile() {
  local profile=$1
  ensure_cluster
  guard_profile_selection "$profile"
  ensure_images
  ensure_namespace
  case "$profile" in
    single-ue)
      if [[ -d $project_root/artifacts/secrets/single-ue ]]; then
        "$script_dir/generate-subscriber-secret.sh" --check
      else
        "$script_dir/generate-subscriber-secret.sh" --generate
      fi
      "$script_dir/single-ue-lifecycle.sh" prepare-secret
      "$script_dir/single-ue-lifecycle.sh" install
      ;;
    default|core-only|resource-limited)
      "$script_dir/generate-subscribers.py" --generate
      CN5G_PROFILE="$profile" "$script_dir/platform-lifecycle.sh" prepare-secret
      CN5G_PROFILE="$profile" "$script_dir/platform-lifecycle.sh" install
      if [[ $profile == default ]]; then
        "$script_dir/observability-lifecycle.sh" prepare-secret
        "$script_dir/observability-lifecycle.sh" install
      fi
      ;;
  esac
  printf 'cn5g_deploy=pass profile=%s\n' "$profile"
}

run_as_operator() {
  sudo -u "#${SUDO_UID}" --preserve-env=PATH "$@"
}

case "$command_name" in
  preflight)
    require_operator_sudo
    if cluster_exists; then
      "$script_dir/platform-lifecycle.sh" preflight
    else
      "$script_dir/cluster-lifecycle.sh" preflight
      helm lint "$project_root/charts/cn5g" --strict \
        --values "$project_root/profiles/default.yaml"
      helm lint "$project_root/charts/cn5g-observability" --strict
      printf 'cn5g_preflight=pass cluster=absent\n'
    fi
    ;;
  deploy)
    require_operator_sudo
    profile=default
    if [[ ${1:-} == --profile ]]; then
      profile=${2:-}
      shift 2 || true
    fi
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    case "$profile" in
      default|core-only|resource-limited|single-ue) ;;
      *) printf 'error: unsupported profile: %s\n' "$profile" >&2; exit 2 ;;
    esac
    deploy_profile "$profile"
    ;;
  validate)
    require_operator_sudo
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    if helm --kubeconfig "$project_root/artifacts/kubernetes/cn5g.kubeconfig" \
        --namespace cn5g-observability status cn5g-observability >/dev/null 2>&1; then
      "$script_dir/observability-lifecycle.sh" validate
    else
      "$script_dir/platform-lifecycle.sh" validate
    fi
    ;;
  status)
    require_operator_sudo
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    if cluster_exists; then
      "$script_dir/cluster-lifecycle.sh" status
      "$script_dir/platform-lifecycle.sh" status
      "$script_dir/observability-lifecycle.sh" status || true
    else
      printf 'cluster=cn5g state=absent\n'
    fi
    ;;
  dashboard)
    require_operator_sudo
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    "$script_dir/observability-lifecycle.sh" grafana
    ;;
  test)
    require_operator_sudo
    case "${1:-}" in
      alerts) "$script_dir/observability-lifecycle.sh" test-alerts ;;
      persistence) "$script_dir/resilience-campaign.sh" test-mongodb ;;
      subscriber-recovery) "$script_dir/platform-lifecycle.sh" test-reprovision ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  campaign)
    require_operator_sudo
    campaign=${1:-}
    campaign_action=${2:-}
    case "$campaign:$campaign_action" in
      performance:prepare)
        "$script_dir/performance-campaign.sh" preflight
        "$script_dir/performance-campaign.sh" build-image
        "$script_dir/performance-campaign.sh" load-image
        "$script_dir/performance-campaign.sh" install
        ;;
      performance:pilot) "$script_dir/performance-campaign.sh" pilot ;;
      performance:run) "$script_dir/performance-campaign.sh" run-matrix ;;
      performance:analyze) run_as_operator "$script_dir/performance-campaign.sh" analyze ;;
      performance:status) "$script_dir/performance-campaign.sh" status ;;
      performance:rollback) "$script_dir/performance-campaign.sh" rollback --confirm ;;
      resilience:pilot-amf) "$script_dir/resilience-campaign.sh" pilot amf ;;
      resilience:pilot-smf) "$script_dir/resilience-campaign.sh" pilot smf ;;
      resilience:pilot-upf) "$script_dir/resilience-campaign.sh" pilot upf ;;
      resilience:run) "$script_dir/resilience-campaign.sh" run-matrix ;;
      resilience:analyze) run_as_operator "$script_dir/resilience-campaign.sh" analyze ;;
      resilience:status) "$script_dir/resilience-campaign.sh" status ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  verify)
    require_operator_sudo
    case "${1:-}" in
      supply-chain) "$script_dir/supply-chain-assurance.sh" privileged-gate ;;
      release) "$script_dir/release-qualification.sh" privileged-gate ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  destroy)
    require_operator_sudo
    [[ ${1:-} == --confirm && $# -eq 1 ]] || { usage >&2; exit 2; }
    "$script_dir/cluster-lifecycle.sh" delete --confirm
    "$script_dir/cluster-lifecycle.sh" verify-delete
    printf 'cn5g_destroy=pass cluster=cn5g\n'
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
