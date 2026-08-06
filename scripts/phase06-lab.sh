#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: sudo scripts/phase06-lab.sh ACTION

Actions:
  preflight       Validate Phase 5, the resource budget, chart, image pins,
                  and deterministic rendering. The Phase 5 validator may
                  reconcile only its two owned kind-node return routes.
  prepare-secret  Generate or verify the local file-backed Grafana admin
                  credential and its project-owned Kubernetes Secret.
  install         Add bounded UE probe metrics, install the isolated
                  observability release, and run end-to-end validation.
  validate        Revalidate Phase 5 plus Prometheus, Grafana, Loki, Alloy,
                  Kubernetes metrics, telecom metrics, and cardinality.
  test-alerts     Prove firing and resolution for three actionable alert
                  rules using the bounded controlled exercise metric.
  grafana         Record a stability-soak baseline, then expose Grafana only
                  at http://127.0.0.1:13000 until Ctrl-C.
  verify-grafana-soak
                  After at least 30 minutes of interactive dashboard use,
                  verify no Grafana restart/OOM and at least 20% memory
                  headroom under the accepted 768 MiB limit.
  rollback-hardening --confirm
                  Roll back only the observability release to the revision
                  recorded before Stage A, preserving both telemetry PVCs.
  status          Show only the two project releases and their scoped objects.
  uninstall --confirm
                  Remove the observability release and UE probe sidecars while
                  preserving observability PVCs, namespace, and credential.
  destroy --confirm
                  After uninstall, remove only verified Phase 6 PVCs, the
                  Grafana Secret, and the empty observability namespace.

The helper never deletes the kind cluster, MongoDB PVC, Phase 5 subscriber
Secret, container images, or unrelated host resources.
EOF
}

action=${1:-}
case "$action" in
  preflight|prepare-secret|install|validate|test-alerts|grafana|verify-grafana-soak|status) ;;
  rollback-hardening|uninstall|destroy)
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

for required_command in awk base64 chmod cmp curl date df docker grep helm jq \
  kubectl mktemp openssl python3 rm sed sha256sum sleep stat; do
  command -v "$required_command" >/dev/null 2>&1 || {
    printf 'error: required command is unavailable: %s\n' "$required_command" >&2
    exit 4
  }
done

# shellcheck source=../versions/phase-03.env
source "$project_root/versions/phase-03.env"
# shellcheck source=../versions/phase-04.env
source "$project_root/versions/phase-04.env"
# shellcheck source=../versions/phase-06.env
source "$project_root/versions/phase-06.env"

core_chart="$project_root/charts/cn5g"
core_phase05_values="$core_chart/values-phase05.yaml"
core_phase06_values="$core_chart/values-phase06.yaml"
observability_chart="$project_root/charts/cn5g-observability"
kubeconfig="$project_root/artifacts/kubernetes/cn5g.kubeconfig"
core_namespace=$CN5G_KUBERNETES_NAMESPACE
core_release=$CN5G_HELM_RELEASE_NAME
namespace=$CN5G_OBSERVABILITY_NAMESPACE
release=$CN5G_OBSERVABILITY_RELEASE_NAME
node_container="${KIND_CLUSTER_NAME}-control-plane"
secret_name=cn5g-grafana-admin
credential_dir="$project_root/artifacts/secrets/phase-06"
admin_user_file="$credential_dir/admin-user"
admin_password_file="$credential_dir/admin-password"
state_file="$project_root/artifacts/kubernetes/phase-06.state"
grafana_soak_state_file="$project_root/artifacts/kubernetes/phase-06-grafana-soak.json"
hardening_state_file="$project_root/artifacts/kubernetes/phase-06-dashboard-hardening.json"

core_kubectl=(kubectl --kubeconfig "$kubeconfig" --namespace "$core_namespace")
obs_kubectl=(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace")

verify_namespace_ownership() {
  local namespace_json part phase
  namespace_json=$(kubectl --kubeconfig "$kubeconfig" get namespace "$namespace" --output json)
  part=$(jq -r '.metadata.labels["app.kubernetes.io/part-of"] // ""' <<<"$namespace_json")
  phase=$(jq -r '.metadata.labels["cn5g.io/phase"] // ""' <<<"$namespace_json")
  if [[ $part != cn5g-platform || $phase != 06 ]]; then
    printf 'error: observability namespace ownership labels are unexpected\n' >&2
    return 1
  fi
}

require_cluster() {
  [[ -r $kubeconfig && ! -L $kubeconfig ]] || {
    printf 'error: project kubeconfig is absent or unsafe\n' >&2
    return 1
  }
  docker inspect "$node_container" >/dev/null 2>&1 || {
    printf 'error: exact kind node container is absent: %s\n' "$node_container" >&2
    return 1
  }
  kubectl --kubeconfig "$kubeconfig" get node "$node_container" >/dev/null
}

verify_phase05_release() {
  local status enabled
  status=$(helm --kubeconfig "$kubeconfig" --namespace "$core_namespace" \
    status "$core_release" --output json | jq -er '.info.status')
  enabled=$(helm --kubeconfig "$kubeconfig" --namespace "$core_namespace" \
    get values "$core_release" --all --output json | jq -er '.phase05.enabled')
  if [[ $status != deployed || $enabled != true ]]; then
    printf 'error: Phase 6 requires the accepted deployed Phase 5 topology\n' >&2
    return 1
  fi
  printf 'phase05_release=deployed-and-enabled\n'
}

verify_resource_budget() {
  local memory_kib disk_kib
  memory_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  disk_kib=$(df -Pk /var/lib/docker | awk 'NR == 2 {print $4}')
  printf 'host_memory_available_gib=%s\n' "$((memory_kib / 1024 / 1024))"
  printf 'docker_filesystem_available_gib=%s\n' "$((disk_kib / 1024 / 1024))"
  if (( memory_kib < 4 * 1024 * 1024 )); then
    printf 'error: Phase 6 requires at least 4 GiB available memory\n' >&2
    return 1
  fi
  if (( disk_kib < 6 * 1024 * 1024 )); then
    printf 'error: Phase 6 requires at least 6 GiB on the Docker filesystem\n' >&2
    return 1
  fi
  printf 'phase06_resource_budget=pass\n'
}

verify_image_pins() {
  local variable image digest
  for variable in PROMETHEUS GRAFANA LOKI ALLOY KUBE_STATE_METRICS UE_PROBE_PYTHON; do
    image_variable="${variable}_IMAGE"
    digest_variable="${variable}_IMAGE_DIGEST"
    image=${!image_variable}
    digest=${!digest_variable}
    [[ $image != *:latest && $digest =~ ^sha256:[0-9a-f]{64}$ ]] || {
      printf 'error: invalid Phase 6 image pin: %s\n' "$variable" >&2
      return 1
    }
    printf 'image=%s@%s identity=pinned\n' "$image" "$digest"
  done
  printf 'phase06_image_pin_validation=pass\n'
}

deterministic_render() {
  local render_dir cleanup
  render_dir=$(mktemp -d)
  printf -v cleanup 'rm -rf -- %q' "$render_dir"
  trap "$cleanup" RETURN
  helm lint "$core_chart" --strict --values "$core_phase05_values" \
    --values "$core_phase06_values"
  helm lint "$observability_chart" --strict
  helm template "$core_release" "$core_chart" --namespace "$core_namespace" \
    --kube-version 1.36.1 --values "$core_phase05_values" \
    --values "$core_phase06_values" > "$render_dir/core-one.yaml"
  helm template "$core_release" "$core_chart" --namespace "$core_namespace" \
    --kube-version 1.36.1 --values "$core_phase05_values" \
    --values "$core_phase06_values" > "$render_dir/core-two.yaml"
  helm template "$release" "$observability_chart" --namespace "$namespace" \
    --kube-version 1.36.1 > "$render_dir/obs-one.yaml"
  helm template "$release" "$observability_chart" --namespace "$namespace" \
    --kube-version 1.36.1 > "$render_dir/obs-two.yaml"
  cmp --silent "$render_dir/core-one.yaml" "$render_dir/core-two.yaml"
  cmp --silent "$render_dir/obs-one.yaml" "$render_dir/obs-two.yaml"
  python3 - "$render_dir/core-one.yaml" "$render_dir/obs-one.yaml" <<'PY'
import sys
import yaml
for path in sys.argv[1:]:
    list(yaml.safe_load_all(open(path, encoding="utf-8")))
PY
  rm -rf -- "$render_dir"
  trap - RETURN
  printf 'deterministic_phase06_chart_render=pass\n'
}

run_preflight() {
  local phase05_output phase05_result
  require_cluster
  verify_resource_budget
  verify_phase05_release
  if phase05_output=$("$script_dir/phase05-lab.sh" validate 2>&1); then
    printf '%s\n' "$phase05_output"
  else
    phase05_result=$?
    printf '%s\n' "$phase05_output"
    if [[ $phase05_output == *"curl: (28)"* || \
          $phase05_output == *"UPF does not expose five complete PFCP/GTP-U sessions"* ]]; then
      printf 'error: Phase 5 session state is stale; run the scoped recovery and retry:\n' >&2
      printf '  sudo ./scripts/phase05-lab.sh repair-sessions\n' >&2
    fi
    return "$phase05_result"
  fi
  verify_image_pins
  deterministic_render
  printf 'phase06_preflight=pass\n'
}

verify_secret() {
  local mode user_hash password_hash secret_json cluster_user_hash cluster_password_hash
  for file in "$admin_user_file" "$admin_password_file"; do
    [[ -f $file && ! -L $file ]] || {
      printf 'error: local Grafana credential material is absent or unsafe\n' >&2
      return 1
    }
    mode=$(stat -c '%a' "$file")
    [[ $mode == 600 ]] || {
      printf 'error: Grafana credential file must use mode 600: %s\n' "$file" >&2
      return 1
    }
  done
  secret_json=$("${obs_kubectl[@]}" get secret "$secret_name" --output json)
  [[ $(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$secret_json") == cn5g-phase06-lab ]] || {
    printf 'error: Grafana Secret ownership is unexpected\n' >&2
    return 1
  }
  user_hash=$(sha256sum "$admin_user_file" | awk '{print $1}')
  password_hash=$(sha256sum "$admin_password_file" | awk '{print $1}')
  cluster_user_hash=$(jq -r '.data["admin-user"]' <<<"$secret_json" | base64 --decode | sha256sum | awk '{print $1}')
  cluster_password_hash=$(jq -r '.data["admin-password"]' <<<"$secret_json" | base64 --decode | sha256sum | awk '{print $1}')
  [[ $user_hash == "$cluster_user_hash" && $password_hash == "$cluster_password_hash" ]] || {
    printf 'error: Grafana Secret differs from restricted local material\n' >&2
    return 1
  }
  printf 'grafana_admin_secret=present-matching-and-project-owned\n'
}

prepare_secret() {
  require_cluster
  install -d -m 0700 -o "$SUDO_UID" -g "$SUDO_GID" "$credential_dir"
  if [[ ! -e $admin_user_file && ! -e $admin_password_file ]]; then
    printf 'admin\n' > "$admin_user_file"
    openssl rand -hex 24 > "$admin_password_file"
    chown "$SUDO_UID:$SUDO_GID" "$admin_user_file" "$admin_password_file"
    chmod 0600 "$admin_user_file" "$admin_password_file"
    printf 'grafana_admin_material=generated-restricted\n'
  fi
  if ! kubectl --kubeconfig "$kubeconfig" get namespace "$namespace" >/dev/null 2>&1; then
    kubectl --kubeconfig "$kubeconfig" create namespace "$namespace"
    kubectl --kubeconfig "$kubeconfig" label namespace "$namespace" \
      app.kubernetes.io/part-of=cn5g-platform cn5g.io/phase=06
  fi
  verify_namespace_ownership
  if ! "${obs_kubectl[@]}" get secret "$secret_name" >/dev/null 2>&1; then
    "${obs_kubectl[@]}" create secret generic "$secret_name" \
      "--from-file=admin-user=$admin_user_file" \
      "--from-file=admin-password=$admin_password_file"
    "${obs_kubectl[@]}" label secret "$secret_name" \
      app.kubernetes.io/instance="$release" \
      app.kubernetes.io/part-of=cn5g-platform \
      app.kubernetes.io/managed-by=cn5g-phase06-lab \
      cn5g.io/phase=06
  fi
  verify_secret
  printf 'phase06_secret_preparation=pass\n'
}

server_dry_run() {
  local render_dir cleanup
  render_dir=$(mktemp -d)
  printf -v cleanup 'rm -rf -- %q' "$render_dir"
  trap "$cleanup" RETURN
  helm template "$core_release" "$core_chart" --namespace "$core_namespace" \
    --values "$core_phase05_values" --values "$core_phase06_values" \
    > "$render_dir/core.yaml"
  helm template "$release" "$observability_chart" --namespace "$namespace" \
    > "$render_dir/observability.yaml"
  kubectl --kubeconfig "$kubeconfig" apply --server-side --dry-run=server \
    --field-manager=cn5g-phase06-preflight --filename "$render_dir/core.yaml" >/dev/null
  kubectl --kubeconfig "$kubeconfig" apply --server-side --dry-run=server \
    --field-manager=cn5g-phase06-preflight --filename "$render_dir/observability.yaml" >/dev/null
  rm -rf -- "$render_dir"
  trap - RETURN
  printf 'server_side_phase06_dry_run=pass\n'
}

capture_hardening_rollback_state() {
  local mode revision prometheus_uid loki_uid
  if [[ -e $hardening_state_file || -L $hardening_state_file ]]; then
    [[ -f $hardening_state_file && ! -L $hardening_state_file ]] || {
      printf 'error: dashboard-hardening rollback state is unsafe\n' >&2
      return 1
    }
    mode=$(stat -c '%a' "$hardening_state_file")
    [[ $mode == 600 ]] || {
      printf 'error: dashboard-hardening rollback state must use mode 600\n' >&2
      return 1
    }
    jq -e '
      (.observability_revision | type == "number") and
      (.prometheus_pvc_uid | type == "string" and length > 0) and
      (.loki_pvc_uid | type == "string" and length > 0)
    ' "$hardening_state_file" >/dev/null || {
      printf 'error: dashboard-hardening rollback state is invalid\n' >&2
      return 1
    }
    printf 'dashboard_hardening_rollback_state=already-recorded\n'
    return 0
  fi
  if ! helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    status "$release" >/dev/null 2>&1; then
    printf 'dashboard_hardening_rollback_state=not-required-fresh-install\n'
    return 0
  fi
  revision=$(helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    status "$release" --output json | jq -er '.version')
  prometheus_uid=$("${obs_kubectl[@]}" get pvc "data-${release}-prometheus-0" \
    --output json | jq -er '.metadata.uid')
  loki_uid=$("${obs_kubectl[@]}" get pvc "data-${release}-loki-0" \
    --output json | jq -er '.metadata.uid')
  jq -n --argjson revision "$revision" --arg prometheus_uid "$prometheus_uid" \
    --arg loki_uid "$loki_uid" \
    '{observability_revision:$revision,prometheus_pvc_uid:$prometheus_uid,loki_pvc_uid:$loki_uid}' \
    > "$hardening_state_file"
  chown "$SUDO_UID:$SUDO_GID" "$hardening_state_file"
  chmod 0600 "$hardening_state_file"
  printf 'dashboard_hardening_rollback_state=recorded observability_revision=%s\n' "$revision"
}

install_phase06() {
  local core_revision phase06_enabled
  require_cluster
  verify_resource_budget
  verify_phase05_release
  verify_secret
  deterministic_render
  server_dry_run
  if [[ ! -e $state_file ]]; then
    core_revision=$(helm --kubeconfig "$kubeconfig" --namespace "$core_namespace" \
      status "$core_release" --output json | jq -er '.version')
    printf 'BASE_CORE_REVISION=%q\n' "$core_revision" > "$state_file"
    chown "$SUDO_UID:$SUDO_GID" "$state_file"
    chmod 0600 "$state_file"
  fi
  phase06_enabled=$(helm --kubeconfig "$kubeconfig" --namespace "$core_namespace" \
    get values "$core_release" --all --output json | jq -r '.phase06.enabled // false')
  if [[ $phase06_enabled == true ]]; then
    printf 'phase06_core_overlay=already-active upgrade=skipped\n'
  else
    helm upgrade "$core_release" "$core_chart" --kubeconfig "$kubeconfig" \
      --namespace "$core_namespace" --values "$core_phase05_values" \
      --values "$core_phase06_values" --wait=watcher --timeout 15m
  fi
  "${core_kubectl[@]}" rollout status statefulset/cn5g-ue --timeout=600s
  printf 'phase06_ue_probe_rollout=pass replicas=5\n'
  "$script_dir/phase05-lab.sh" validate
  capture_hardening_rollback_state
  helm upgrade --install "$release" "$observability_chart" \
    --kubeconfig "$kubeconfig" --namespace "$namespace" \
    --create-namespace --rollback-on-failure --wait=watcher --timeout 15m
  validate_phase06
  printf 'phase06_install=pass\n'
}

forward_pid=''
forward_log=''
grafana_netrc=''
stop_forward() {
  if [[ -n $forward_pid ]]; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
    forward_pid=''
  fi
  if [[ -n $forward_log && -f $forward_log ]]; then
    rm -f -- "$forward_log"
    forward_log=''
  fi
}

cleanup_runtime() {
  stop_forward
  if [[ -n $grafana_netrc && -f $grafana_netrc ]]; then
    rm -f -- "$grafana_netrc"
    grafana_netrc=''
  fi
}
trap cleanup_runtime EXIT

start_forward() {
  local service=$1 local_port=$2 remote_port=$3 ready_url=$4 attempt
  stop_forward
  forward_log=$(mktemp)
  kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" port-forward \
    --address 127.0.0.1 "service/$service" "${local_port}:${remote_port}" \
    >"$forward_log" 2>&1 &
  forward_pid=$!
  for attempt in $(seq 1 30); do
    if curl --fail --silent --show-error "$ready_url" >/dev/null 2>&1; then
      return 0
    fi
    kill -0 "$forward_pid" 2>/dev/null || {
      sed -n '1,80p' "$forward_log" >&2
      return 1
    }
    sleep 1
  done
  printf 'error: port-forward did not become ready: %s\n' "$service" >&2
  return 1
}

prometheus_query() {
  curl --fail --silent --show-error --get \
    --data-urlencode "query=$1" http://127.0.0.1:19090/api/v1/query
}

verify_observability_release() {
  local status
  status=$(helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    status "$release" --output json | jq -er '.info.status')
  [[ $status == deployed ]] || {
    printf 'error: observability Helm release is not deployed: %s\n' "$status" >&2
    return 1
  }
  "${obs_kubectl[@]}" wait --for=condition=Ready pods --all --timeout=300s >/dev/null
  printf 'observability_workload_readiness=pass\n'
}

validate_prometheus() {
  local targets_json query_json value series_count
  start_forward "${release}-prometheus" 19090 9090 http://127.0.0.1:19090/-/ready
  targets_json=$(curl --fail --silent --show-error http://127.0.0.1:19090/api/v1/targets)
  jq -e '
    ([.data.activeTargets[] | select(.labels.job == "cn5g-ue-user-plane")] | length) == 5 and
    ([.data.activeTargets[] | select(.labels.job | test("^(alert-exercise|open5gs-(amf|pcf|smf|upf)|cn5g-ue-user-plane|kube-state-metrics|kubernetes-node|kubernetes-cadvisor)$")) | .health] | all(. == "up"))
  ' <<<"$targets_json" >/dev/null || {
    printf 'error: required Prometheus targets are absent or unhealthy\n' >&2
    return 1
  }
  printf 'prometheus_target_health=pass ue_targets=5\n'
  for query_expected in \
    'max(amf_session):5' \
    'max(pfcp_sessions_active):5' \
    'count(cn5g_ue_user_plane_probe_success):5' \
    'sum(cn5g_ue_user_plane_probe_success):5'; do
    query=${query_expected%:*}
    expected=${query_expected##*:}
    query_json=$(prometheus_query "$query")
    value=$(jq -er '.data.result | if length == 1 then .[0].value[1] else error("unexpected vector") end' <<<"$query_json")
    awk -v observed="$value" -v expected="$expected" 'BEGIN {exit !(observed+0 == expected+0)}' || {
      printf 'error: Prometheus query did not meet contract: %s observed=%s\n' "$query" "$value" >&2
      return 1
    }
  done
  printf 'telecom_metric_validation=pass active_ues=5 active_pfcp_sessions=5\n'
  query_json=$(prometheus_query 'count(kube_pod_status_ready{namespace="cn5g",condition="true"})')
  jq -e '.data.result | length == 1' <<<"$query_json" >/dev/null
  query_json=$(prometheus_query 'count(container_memory_working_set_bytes{namespace="cn5g",container!=""})')
  jq -e '.data.result | length == 1' <<<"$query_json" >/dev/null
  printf 'kubernetes_node_container_metrics=pass\n'
  query_json=$(prometheus_query 'count({__name__=~"cn5g_ue_.*"})')
  series_count=$(jq -er '
    .data.result |
    if length == 1 then .[0].value[1] else error("missing current UE series count") end
  ' <<<"$query_json")
  if ! awk -v observed="$series_count" 'BEGIN {exit !(observed+0 <= 30)}'; then
    printf 'error: UE custom metric cardinality exceeds bound: %s\n' "$series_count" >&2
    return 1
  fi
  printf 'metric_cardinality=bounded series=%s limit=30\n' "$series_count"
  stop_forward
}

validate_loki() {
  local attempt result value=0
  start_forward "${release}-loki" 13100 3100 http://127.0.0.1:13100/ready
  for attempt in $(seq 1 24); do
    result=$(curl --fail --silent --show-error --get \
      --data-urlencode 'query=sum(count_over_time({namespace="cn5g"}[5m]))' \
      http://127.0.0.1:13100/loki/api/v1/query)
    value=$(jq -r '.data.result[0].value[1] // "0"' <<<"$result")
    awk -v value="$value" 'BEGIN {exit !(value+0 > 0)}' && break
    sleep 5
  done
  awk -v value="$value" 'BEGIN {exit !(value+0 > 0)}' || {
    printf 'error: Loki has no recent project workload logs\n' >&2
    return 1
  }
  printf 'centralized_log_ingestion=pass recent_entries=%s\n' "$value"
  stop_forward
}

validate_grafana() {
  local dashboards datasources deployment_json
  deployment_json=$("${obs_kubectl[@]}" get deployment "${release}-grafana" --output json)
  jq -e '
    .spec.template.spec.containers[0] as $container |
    ($container.resources.requests.memory == "192Mi") and
    ($container.resources.limits.memory == "768Mi") and
    ([
      "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES",
      "GF_PLUGINS_PREINSTALL_AUTO_UPDATE",
      "GF_PLUGINS_PLUGIN_ADMIN_ENABLED"
    ] - [$container.env[] | select(.value == "false") | .name] | length == 0) and
    ([$container.env[] | select(.name == "GF_PLUGINS_PREINSTALL_DISABLED" and .value == "true")] | length == 1)
  ' <<<"$deployment_json" >/dev/null || {
    printf 'error: Grafana hardening or resource contract is not active\n' >&2
    return 1
  }
  printf 'grafana_runtime_hardening=pass request_memory=192Mi limit_memory=768Mi runtime_plugin_installation=disabled\n'
  grafana_netrc=$(mktemp)
  chmod 0600 "$grafana_netrc"
  printf 'machine 127.0.0.1 login %s password %s\n' \
    "$(tr -d '\n' < "$admin_user_file")" \
    "$(tr -d '\n' < "$admin_password_file")" > "$grafana_netrc"
  start_forward "${release}-grafana" 13000 3000 http://127.0.0.1:13000/api/health
  datasources=$(curl --fail --silent --show-error --netrc-file "$grafana_netrc" \
    http://127.0.0.1:13000/api/datasources)
  jq -e '([.[].uid] | sort) == ["loki", "prometheus"]' <<<"$datasources" >/dev/null
  dashboards=$(curl --fail --silent --show-error --netrc-file "$grafana_netrc" \
    'http://127.0.0.1:13000/api/search?type=dash-db')
  jq -e '
    ([.[] | select(.tags | index("phase-06")) | .title] | sort) == [
      "CN5G Control, Sessions, UEs, And DNNs",
      "CN5G Kubernetes Resources",
      "CN5G Logs And Troubleshooting",
      "CN5G Service Overview"
    ]
  ' <<<"$dashboards" >/dev/null || {
    printf 'error: expected the four exact provisioned Stage A dashboards\n' >&2
    return 1
  }
  rm -f -- "$grafana_netrc"
  grafana_netrc=''
  printf 'grafana_provisioning=pass datasources=2 dashboards=4\n'
  stop_forward
}

prepare_grafana_soak() {
  local pod_json pod_count pod_name pod_uid restart_count started_epoch
  verify_observability_release
  if [[ -L $grafana_soak_state_file || \
        ( -e $grafana_soak_state_file && ! -f $grafana_soak_state_file ) ]]; then
    printf 'error: Grafana soak state target is unsafe\n' >&2
    return 1
  fi
  pod_json=$("${obs_kubectl[@]}" get pods \
    --selector app.kubernetes.io/component=grafana --output json)
  pod_count=$(jq -er '.items | length' <<<"$pod_json")
  [[ $pod_count == 1 ]] || {
    printf 'error: expected exactly one Grafana Pod before the soak\n' >&2
    return 1
  }
  pod_name=$(jq -er '.items[0].metadata.name' <<<"$pod_json")
  pod_uid=$(jq -er '.items[0].metadata.uid' <<<"$pod_json")
  restart_count=$(jq -er '.items[0].status.containerStatuses[0].restartCount' <<<"$pod_json")
  started_epoch=$(date +%s)
  jq -n \
    --argjson started_epoch "$started_epoch" \
    --arg pod_name "$pod_name" \
    --arg pod_uid "$pod_uid" \
    --argjson restart_count "$restart_count" \
    '{started_epoch:$started_epoch,pod_name:$pod_name,pod_uid:$pod_uid,restart_count:$restart_count}' \
    > "$grafana_soak_state_file"
  chown "$SUDO_UID:$SUDO_GID" "$grafana_soak_state_file"
  chmod 0600 "$grafana_soak_state_file"
  printf 'grafana_soak_baseline=recorded pod=%s restart_count=%s minimum_duration_seconds=1800\n' \
    "$pod_name" "$restart_count"
}

verify_grafana_soak() {
  local mode started_epoch pod_name pod_uid baseline_restarts now elapsed pod_json
  local current_uid current_restarts query_json peak_bytes limit_bytes=805306368
  local peak_mib log_since recent_logs
  require_cluster
  verify_secret
  verify_observability_release
  [[ -f $grafana_soak_state_file && ! -L $grafana_soak_state_file ]] || {
    printf 'error: Grafana soak baseline is absent; start it with the grafana action\n' >&2
    return 1
  }
  mode=$(stat -c '%a' "$grafana_soak_state_file")
  [[ $mode == 600 ]] || {
    printf 'error: Grafana soak state must use mode 600\n' >&2
    return 1
  }
  started_epoch=$(jq -er '.started_epoch' "$grafana_soak_state_file")
  pod_name=$(jq -er '.pod_name' "$grafana_soak_state_file")
  pod_uid=$(jq -er '.pod_uid' "$grafana_soak_state_file")
  baseline_restarts=$(jq -er '.restart_count' "$grafana_soak_state_file")
  now=$(date +%s)
  elapsed=$((now - started_epoch))
  if (( elapsed < 1800 )); then
    printf 'error: Grafana soak is too short: elapsed_seconds=%s required_seconds=1800\n' "$elapsed" >&2
    return 1
  fi
  pod_json=$("${obs_kubectl[@]}" get pod "$pod_name" --output json)
  current_uid=$(jq -er '.metadata.uid' <<<"$pod_json")
  current_restarts=$(jq -er '.status.containerStatuses[0].restartCount' <<<"$pod_json")
  [[ $current_uid == "$pod_uid" ]] || {
    printf 'error: Grafana Pod identity changed during the soak\n' >&2
    return 1
  }
  [[ $current_restarts == "$baseline_restarts" ]] || {
    printf 'error: Grafana restarted during the soak: before=%s after=%s\n' \
      "$baseline_restarts" "$current_restarts" >&2
    return 1
  }
  start_forward "${release}-prometheus" 19090 9090 http://127.0.0.1:19090/-/ready
  query_json=$(prometheus_query \
    "max(max_over_time(container_memory_working_set_bytes{namespace=\"$namespace\",pod=\"$pod_name\",container=\"grafana\"}[30m]))")
  peak_bytes=$(jq -er '.data.result | if length == 1 then .[0].value[1] else error("missing Grafana memory series") end' \
    <<<"$query_json")
  stop_forward
  awk -v peak="$peak_bytes" -v limit="$limit_bytes" 'BEGIN {exit !(peak < limit * 0.80)}' || {
    printf 'error: Grafana memory headroom is below 20 percent: peak_bytes=%s limit_bytes=%s\n' \
      "$peak_bytes" "$limit_bytes" >&2
    return 1
  }
  log_since=$(date -u -d "@$started_epoch" '+%Y-%m-%dT%H:%M:%SZ')
  recent_logs=$("${obs_kubectl[@]}" logs "$pod_name" --container grafana --since-time "$log_since")
  if grep -Eqi 'Installing plugin|Downloading plugin|Plugin update available' <<<"$recent_logs"; then
    printf 'error: Grafana attempted runtime plugin installation/update during the soak\n' >&2
    return 1
  fi
  peak_mib=$(awk -v bytes="$peak_bytes" 'BEGIN {printf "%.1f", bytes / 1024 / 1024}')
  rm -f -- "$grafana_soak_state_file" "$hardening_state_file"
  printf 'grafana_interactive_soak=pass duration_seconds=%s restarts_delta=0 peak_memory_mib=%s limit_memory_mib=768 headroom=pass\n' \
    "$elapsed" "$peak_mib"
}

rollback_hardening() {
  local mode revision expected_prometheus_uid expected_loki_uid
  local observed_prometheus_uid observed_loki_uid
  require_cluster
  [[ -f $hardening_state_file && ! -L $hardening_state_file ]] || {
    printf 'error: no verified pre-hardening observability revision is recorded\n' >&2
    return 1
  }
  mode=$(stat -c '%a' "$hardening_state_file")
  [[ $mode == 600 ]] || {
    printf 'error: dashboard-hardening rollback state must use mode 600\n' >&2
    return 1
  }
  revision=$(jq -er '.observability_revision' "$hardening_state_file")
  expected_prometheus_uid=$(jq -er '.prometheus_pvc_uid' "$hardening_state_file")
  expected_loki_uid=$(jq -er '.loki_pvc_uid' "$hardening_state_file")
  helm --kubeconfig "$kubeconfig" --namespace "$namespace" rollback \
    "$release" "$revision" --wait=watcher --timeout 15m
  verify_observability_release
  observed_prometheus_uid=$("${obs_kubectl[@]}" get pvc "data-${release}-prometheus-0" \
    --output json | jq -er '.metadata.uid')
  observed_loki_uid=$("${obs_kubectl[@]}" get pvc "data-${release}-loki-0" \
    --output json | jq -er '.metadata.uid')
  [[ $observed_prometheus_uid == "$expected_prometheus_uid" && \
     $observed_loki_uid == "$expected_loki_uid" ]] || {
    printf 'error: a telemetry PVC identity changed during rollback\n' >&2
    return 1
  }
  "$script_dir/phase05-lab.sh" validate
  rm -f -- "$hardening_state_file"
  if [[ -f $grafana_soak_state_file && ! -L $grafana_soak_state_file ]]; then
    rm -f -- "$grafana_soak_state_file"
  fi
  printf 'dashboard_hardening_rollback=pass target_revision=%s telemetry_pvc_identity=preserved\n' \
    "$revision"
}

validate_phase06() {
  trap stop_forward RETURN
  require_cluster
  verify_phase05_release
  verify_secret
  "$script_dir/phase05-lab.sh" validate
  verify_observability_release
  validate_prometheus
  validate_loki
  validate_grafana
  stop_forward
  trap - RETURN
  printf 'phase06_validation=pass\n'
}

write_exercise_metric() {
  local active=$1
  "${obs_kubectl[@]}" exec "deployment/${release}-alert-exercise" -- \
    /bin/sh -ec "printf '%s\\n' '# HELP cn5g_observability_alert_exercise Controlled alert lifecycle input.' '# TYPE cn5g_observability_alert_exercise gauge' 'cn5g_observability_alert_exercise{scenario=\"target-down\"} $([[ $active == target-down ]] && printf 1 || printf 0)' 'cn5g_observability_alert_exercise{scenario=\"ue-count\"} $([[ $active == ue-count ]] && printf 1 || printf 0)' 'cn5g_observability_alert_exercise{scenario=\"user-plane\"} $([[ $active == user-plane ]] && printf 1 || printf 0)' > /metrics/metrics"
}

alert_is_active() {
  local alert_name=$1
  curl --fail --silent --show-error http://127.0.0.1:19090/api/v1/alerts | \
    jq -e --arg name "$alert_name" \
      '.data.alerts | any(.labels.alertname == $name and .state == "firing")' >/dev/null
}

wait_alert_state() {
  local alert_name=$1 expected=$2 attempt
  for attempt in $(seq 1 36); do
    if [[ $expected == active ]] && alert_is_active "$alert_name"; then
      return 0
    fi
    if [[ $expected == resolved ]] && ! alert_is_active "$alert_name"; then
      return 0
    fi
    sleep 5
  done
  printf 'error: alert did not reach state %s: %s\n' "$expected" "$alert_name" >&2
  return 1
}

test_alerts() {
  local scenario alert_name
  require_cluster
  verify_observability_release
  trap 'write_exercise_metric none >/dev/null 2>&1 || true; stop_forward' RETURN
  start_forward "${release}-prometheus" 19090 9090 http://127.0.0.1:19090/-/ready
  for pair in \
    'target-down:Cn5gPrometheusTargetDown' \
    'ue-count:Cn5gRegisteredUeMismatch' \
    'user-plane:Cn5gUserPlaneProbeFailed'; do
    scenario=${pair%:*}
    alert_name=${pair##*:}
    write_exercise_metric "$scenario"
    wait_alert_state "$alert_name" active
    printf 'alert=%s firing=pass scenario=%s\n' "$alert_name" "$scenario"
    write_exercise_metric none
    wait_alert_state "$alert_name" resolved
    printf 'alert=%s resolution=pass scenario=%s\n' "$alert_name" "$scenario"
  done
  stop_forward
  trap - RETURN
  printf 'phase06_alert_lifecycle=pass tested=3\n'
}

uninstall_phase06() {
  local base_revision
  require_cluster
  if helm --kubeconfig "$kubeconfig" --namespace "$namespace" status "$release" >/dev/null 2>&1; then
    helm --kubeconfig "$kubeconfig" --namespace "$namespace" uninstall "$release"
  else
    printf 'observability_release=already-absent\n'
  fi
  helm upgrade "$core_release" "$core_chart" --kubeconfig "$kubeconfig" \
    --namespace "$core_namespace" --values "$core_phase05_values" \
    --wait=watcher --timeout 15m
  "$script_dir/phase05-lab.sh" validate
  if [[ -f $state_file && ! -L $state_file ]]; then
    # shellcheck disable=SC1090
    source "$state_file"
    base_revision=${BASE_CORE_REVISION:-unknown}
    rm -f -- "$state_file"
    printf 'phase06_base_core_revision=%s state=removed\n' "$base_revision"
  fi
  if [[ -f $grafana_soak_state_file && ! -L $grafana_soak_state_file ]]; then
    rm -f -- "$grafana_soak_state_file"
  fi
  printf 'phase06_uninstall=pass persistent_data=retained\n'
}

destroy_phase06() {
  local remaining
  require_cluster
  if helm --kubeconfig "$kubeconfig" --namespace "$namespace" status "$release" >/dev/null 2>&1; then
    printf 'error: uninstall the observability release before destroy\n' >&2
    return 1
  fi
  if kubectl --kubeconfig "$kubeconfig" get namespace "$namespace" >/dev/null 2>&1; then
    verify_namespace_ownership
    remaining=$("${obs_kubectl[@]}" get all --output name 2>/dev/null || true)
    [[ -z $remaining ]] || {
      printf 'error: unexpected workload resources remain in observability namespace\n%s\n' "$remaining" >&2
      return 1
    }
    for pvc in "data-${release}-prometheus-0" "data-${release}-loki-0"; do
      if "${obs_kubectl[@]}" get pvc "$pvc" >/dev/null 2>&1; then
        [[ $("${obs_kubectl[@]}" get pvc "$pvc" --output json | jq -r '.metadata.labels["app.kubernetes.io/instance"] // ""') == "$release" ]] || {
          printf 'error: refusing to remove PVC with unexpected ownership: %s\n' "$pvc" >&2
          return 1
        }
      fi
    done
    "${obs_kubectl[@]}" delete pvc \
      "data-${release}-prometheus-0" "data-${release}-loki-0" --ignore-not-found
    "${obs_kubectl[@]}" delete secret "$secret_name" --ignore-not-found
    kubectl --kubeconfig "$kubeconfig" delete namespace "$namespace"
  fi
  printf 'phase06_destroy=pass scoped_data_and_credentials=removed\n'
}

case "$action" in
  preflight) run_preflight ;;
  prepare-secret) prepare_secret ;;
  install) install_phase06 ;;
  validate) validate_phase06 ;;
  test-alerts) test_alerts ;;
  grafana)
    require_cluster
    verify_secret
    prepare_grafana_soak
    printf 'grafana_url=http://127.0.0.1:13000\n'
    printf 'grafana_credentials=%s and restricted local password file\n' "$(tr -d '\n' < "$admin_user_file")"
    exec kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      port-forward --address 127.0.0.1 "service/${release}-grafana" 13000:3000
    ;;
  verify-grafana-soak) verify_grafana_soak ;;
  rollback-hardening) rollback_hardening ;;
  status)
    require_cluster
    helm --kubeconfig "$kubeconfig" --namespace "$core_namespace" list --filter "^${core_release}$"
    helm --kubeconfig "$kubeconfig" --namespace "$namespace" list --all
    "${obs_kubectl[@]}" get deployments,statefulsets,pods,services,pvc --output wide
    ;;
  uninstall) uninstall_phase06 ;;
  destroy) destroy_phase06 ;;
esac
