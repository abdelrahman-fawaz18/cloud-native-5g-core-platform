#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/resilience-campaign.sh ACTION [ARGUMENT]
       ./scripts/resilience-campaign.sh analyze

Actions:
  preflight             Validate the accepted platform and observability baseline, resource
                        budget, experiment contract, exact fault targets, and
                        deterministic chart render without injecting a fault.
  pilot amf|smf|upf     Delete one exact component Pod, measure recovery, and
                        restore the complete five-UE baseline.
  run-matrix            Run or resume three repetitions of AMF, SMF, and UPF
                        recovery after all three pilots pass.
  test-mongodb          Recreate only the MongoDB Pod and prove PVC/subscriber
                        persistence plus full service recovery.
  test-invalid-config   Prove invalid Helm values and an invalid Kubernetes
                        object are rejected without changing the release.
  analyze               Generate reviewed CSV/JSON/SVG/report output from one
                        complete accepted raw campaign. This action is no-sudo.
  recover               Run the scoped dependency-ordered recovery path and
                        require complete platform and observability validation.
  status                Show release, fault-target, PVC, campaign, and recent
                        pilot state without changing the cluster.

Raw evidence is permission-restricted and ignored under benchmarks/raw/resilience.
No action deletes a Deployment, StatefulSet, Service, Secret, namespace, PVC,
route, image, or host resource.
EOF
}

action=${1:-}
component=${2:-}
case "$action" in
  preflight|run-matrix|test-mongodb|test-invalid-config|recover|status)
    [[ -z $component ]] || { printf 'error: unexpected argument: %s\n' "$component" >&2; exit 2; }
    ;;
  pilot)
    [[ $component =~ ^(amf|smf|upf)$ ]] || {
      printf 'error: pilot requires exactly one component: amf, smf, or upf\n' >&2
      exit 2
    }
    ;;
  analyze)
    [[ -z $component ]] || { printf 'error: analyze takes no argument\n' >&2; exit 2; }
    ;;
  -h|--help) usage; exit 0 ;;
  *) printf 'error: unknown action: %s\n' "${action:-<empty>}" >&2; usage >&2; exit 2 ;;
esac

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(cd -- "$script_dir/.." && pwd -P)
[[ ${project_root##*/} == cloud-native-5g-core-platform ]] || {
  printf 'error: refusing to run outside the expected repository\n' >&2
  exit 3
}

if [[ $action == analyze ]]; then
  exec "$script_dir/analyze-resilience.py" --project-root "$project_root"
fi

if (( EUID != 0 )) || [[ -z ${SUDO_UID:-} || -z ${SUDO_GID:-} ]]; then
  printf 'error: run this lifecycle through sudo from the normal account\n' >&2
  exit 3
fi

for command_name in awk chmod chown cmp date df docker find grep helm jq kubectl \
  mkdir mktemp nproc python3 rm sed stat; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'error: required command is unavailable: %s\n' "$command_name" >&2
    exit 4
  }
done

# shellcheck source=../versions/kubernetes-runtime.env
source "$project_root/versions/kubernetes-runtime.env"
# shellcheck source=../versions/platform-runtime.env
source "$project_root/versions/platform-runtime.env"

chart="$project_root/charts/cn5g"
default_profile="$project_root/profiles/default.yaml"
experiment="$project_root/benchmarks/resilience/experiment.json"
kubeconfig="$project_root/artifacts/kubernetes/cn5g.kubeconfig"
namespace=$CN5G_KUBERNETES_NAMESPACE
release=$CN5G_HELM_RELEASE_NAME
node_container="${KIND_CLUSTER_NAME}-control-plane"
raw_root="$project_root/benchmarks/raw/resilience"
runner="$script_dir/run-resilience-matrix.py"
campaign_state="$project_root/artifacts/kubernetes/resilience-campaign.json"
kubectl_ns=(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace")

require_cluster() {
  [[ -r $kubeconfig && ! -L $kubeconfig ]] || {
    printf 'error: project kubeconfig is absent or unsafe\n' >&2
    return 1
  }
  docker inspect "$node_container" >/dev/null 2>&1 || {
    printf 'error: exact kind node container is absent: %s\n' "$node_container" >&2
    return 1
  }
  "${kubectl_ns[@]}" wait --for=condition=Ready node "$node_container" --timeout=60s >/dev/null
}

release_values() {
  helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    get values "$release" --all --output json
}

require_observability_baseline() {
  local status values
  status=$(helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    status "$release" --output json | jq -er '.info.status')
  values=$(release_values)
  [[ $status == deployed && $(jq -r '.platform.enabled' <<<"$values") == true && \
    $(jq -r '.observability.enabled' <<<"$values") == true && \
    $(jq -r '.performance.enabled // false' <<<"$values") == false ]] || {
    printf 'error: resilience campaign requires the accepted post-rollback platform and observability release without the performance campaign benchmark overlay\n' >&2
    return 1
  }
  helm --kubeconfig "$kubeconfig" --namespace cn5g-observability \
    status cn5g-observability --output json | jq -e '.info.status == "deployed"' >/dev/null || {
      printf 'error: the accepted observability release is not deployed\n' >&2
      return 1
    }
  printf 'resilience_dependency_releases=deployed-and-enabled\n'
}

verify_resource_budget() {
  local memory_kib disk_kib
  memory_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  disk_kib=$(df -Pk /var/lib/docker | awk 'NR == 2 {print $4}')
  printf 'host_memory_available_gib=%s\n' "$((memory_kib / 1024 / 1024))"
  printf 'docker_filesystem_available_gib=%s\n' "$((disk_kib / 1024 / 1024))"
  (( memory_kib >= 4 * 1024 * 1024 )) || {
    printf 'error: resilience campaign preparation requires at least 4 GiB available memory\n' >&2
    return 1
  }
  (( disk_kib >= 8 * 1024 * 1024 )) || {
    printf 'error: resilience campaign preparation requires at least 8 GiB free Docker space\n' >&2
    return 1
  }
  printf 'resilience_resource_budget=pass\n'
}

verify_experiment_contract() {
  python3 - "$experiment" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema_version"] == 1
assert data["controls"]["repetitions"] == 3
assert data["controls"]["run_order"] == ["amf", "smf", "upf"]
assert data["controls"]["one_intended_fault_per_attempt"] is True
assert data["controls"]["pilot_required_per_component"] is True
assert data["controls"]["automatic_recovery_observation_seconds"] >= 60
assert data["topology"]["replicas_per_faulted_component"] == 1
assert set(data["faults"]) == {"amf", "smf", "upf"}
assert data["evidence"]["raw_data"].startswith("ignored")
assert data["abort_thresholds"]["mongodb_pvc_identity_change_allowed"] is False
assert "high availability" in data["publication"]["prohibited_claims"]
for component, item in data["faults"].items():
    assert item["workload_name"] == f"cn5g-{component}"
    assert item["prometheus_job"] == f"open5gs-{component}"
    assert "replacement_ready" in item["service_recovery_signals"]
    assert "user_plane_paths_five" in item["service_recovery_signals"]
PY
  printf 'resilience_experiment_contract=pass components=amf,smf,upf repetitions=3\n'
}

verify_fault_targets() {
  local component object pods
  for component in amf smf upf; do
    object=$("${kubectl_ns[@]}" get deployment "cn5g-$component" --output json)
    [[ $(jq -r '.spec.replicas' <<<"$object") == 1 && \
      $(jq -r '.status.availableReplicas // 0' <<<"$object") == 1 ]] || {
      printf 'error: %s is not an available one-replica Deployment\n' "$component" >&2
      return 1
    }
    pods=$("${kubectl_ns[@]}" get pods \
      -l "app.kubernetes.io/instance=cn5g,app.kubernetes.io/component=$component" \
      --output json)
    [[ $(jq '.items | length' <<<"$pods") == 1 && \
      $(jq -r '[.items[0].status.conditions[] | select(.type == "Ready")][0].status' <<<"$pods") == True ]] || {
      printf 'error: %s fault selector does not resolve one Ready Pod\n' "$component" >&2
      return 1
    }
  done
  printf 'resilience_fault_targets=pass replicas=1 selectors=exact\n'
}

deterministic_render() {
  local render_dir
  render_dir=$(mktemp -d)
  trap 'rm -rf -- "$render_dir"' RETURN
  helm lint "$chart" --strict --values "$default_profile"
  for suffix in one two; do
    helm template "$release" "$chart" --namespace "$namespace" \
      --kube-version 1.36.1 --values "$default_profile" \
      > "$render_dir/$suffix.yaml"
  done
  cmp --silent "$render_dir/one.yaml" "$render_dir/two.yaml"
  rm -rf -- "$render_dir"
  trap - RETURN
  printf 'deterministic_resilience_baseline_render=pass\n'
}

run_preflight() {
  require_cluster
  verify_resource_budget
  require_observability_baseline
  "$script_dir/platform-lifecycle.sh" validate
  "$script_dir/observability-lifecycle.sh" validate
  verify_experiment_contract
  verify_fault_targets
  deterministic_render
  printf 'resilience_preflight=pass\n'
  printf 'next_step=sudo ./scripts/resilience-campaign.sh pilot amf\n'
}

run_runner() {
  local mode=$1
  shift
  require_cluster
  require_observability_baseline
  verify_experiment_contract
  verify_fault_targets
  verify_resource_budget
  mkdir -p "$raw_root"
  chmod 700 "$raw_root"
  chown "$SUDO_UID:$SUDO_GID" "$raw_root"
  python3 "$runner" \
    --project-root "$project_root" \
    --kubeconfig "$kubeconfig" \
    --namespace "$namespace" \
    --observability-namespace cn5g-observability \
    --experiment "$experiment" \
    --raw-root "$raw_root" \
    --state-file "$campaign_state" \
    --mode "$mode" "$@"
}

run_pilot() {
  run_runner pilot --component "$component"
  case "$component" in
    amf) printf 'next_step=sudo ./scripts/resilience-campaign.sh pilot smf\n' ;;
    smf) printf 'next_step=sudo ./scripts/resilience-campaign.sh pilot upf\n' ;;
    upf) printf 'next_step=sudo ./scripts/resilience-campaign.sh run-matrix\n' ;;
  esac
}

run_matrix() {
  run_runner matrix
  printf 'next_step=return the final matrix output for review before analysis\n'
}

test_mongodb() {
  local run_id run_dir pvc_before pvc_after pod_before pod_after result=0
  require_cluster
  require_observability_baseline
  "$script_dir/platform-lifecycle.sh" validate
  run_id=$(date -u +%Y%m%dT%H%M%SZ)-mongodb
  run_dir="$raw_root/$run_id"
  mkdir -p "$raw_root"
  chmod 700 "$raw_root"
  chown "$SUDO_UID:$SUDO_GID" "$raw_root"
  mkdir -p "$run_dir"
  chmod 700 "$run_dir"
  pvc_before=$("${kubectl_ns[@]}" get pvc mongodb-data-cn5g-mongodb-0 --output json | \
    jq -c '{uid:.metadata.uid,volume:.spec.volumeName}')
  pod_before=$("${kubectl_ns[@]}" get pod cn5g-mongodb-0 --output json | jq -r '.metadata.uid')
  "${kubectl_ns[@]}" delete pod cn5g-mongodb-0 --wait=false
  "${kubectl_ns[@]}" rollout status statefulset/cn5g-mongodb --timeout=10m || result=1
  pod_after=$("${kubectl_ns[@]}" get pod cn5g-mongodb-0 --output json | jq -r '.metadata.uid')
  pvc_after=$("${kubectl_ns[@]}" get pvc mongodb-data-cn5g-mongodb-0 --output json | \
    jq -c '{uid:.metadata.uid,volume:.spec.volumeName}')
  [[ $pod_after != "$pod_before" && $pvc_after == "$pvc_before" ]] || result=1
  "$script_dir/platform-lifecycle.sh" validate > "$run_dir/platform-validation.log" 2>&1 || result=1
  "$script_dir/observability-lifecycle.sh" validate > "$run_dir/observability-validation.log" 2>&1 || result=1
  jq -n --arg run_id "$run_id" --arg pod_before "$pod_before" \
    --arg pod_after "$pod_after" --argjson pvc_before "$pvc_before" \
    --argjson pvc_after "$pvc_after" --argjson result "$result" \
    '{schema_version:1,run_id:$run_id,fault:"mongodb_pod_delete",pod_uid_before:$pod_before,pod_uid_after:$pod_after,pvc_before:$pvc_before,pvc_after:$pvc_after,result:(if $result == 0 then "pass" else "fail" end)}' \
    > "$run_dir/manifest.json"
  chmod 600 "$run_dir"/*
  chown -R "$SUDO_UID:$SUDO_GID" "$run_dir"
  (( result == 0 )) || {
    printf 'error: MongoDB recreation test failed; evidence retained at %s\n' "$run_dir" >&2
    return 1
  }
  printf 'resilience_mongodb_recreation=pass pvc_identity=preserved subscriber_records=5\n'
}

test_invalid_config() {
  local revision_before revision_after render_output api_output manifest
  require_cluster
  require_observability_baseline
  revision_before=$(helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    status "$release" --output json | jq -er '.version')
  render_output=$(mktemp)
  api_output=$(mktemp)
  manifest=$(mktemp)
  trap 'rm -f -- "$render_output" "$api_output" "$manifest"' RETURN
  if helm template "$release" "$chart" --namespace "$namespace" \
    --values "$default_profile" \
    --set platform.ueReplicas=4 > "$render_output" 2>&1; then
    printf 'error: invalid four-UE Helm contract was unexpectedly accepted\n' >&2
    return 1
  fi
  python3 - "$manifest" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text("""apiVersion: apps/v1
kind: Deployment
metadata:
  name: cn5g-resilience-invalid-config
  namespace: cn5g
  labels:
    app.kubernetes.io/part-of: cn5g
    cn5g.io/test: resilience-invalid-config
spec:
  replicas: -1
  selector:
    matchLabels: {app: cn5g-resilience-invalid-config}
  template:
    metadata:
      labels: {app: cn5g-resilience-invalid-config}
    spec:
      containers:
        - name: invalid
          image: cn5g/data-network:0.1.0
""", encoding="utf-8")
PY
  if "${kubectl_ns[@]}" apply --server-side --dry-run=server \
    --field-manager=cn5g-resilience-invalid-config --filename "$manifest" \
    > "$api_output" 2>&1; then
    printf 'error: invalid negative-replica Deployment was unexpectedly admitted\n' >&2
    return 1
  fi
  if "${kubectl_ns[@]}" get deployment cn5g-resilience-invalid-config >/dev/null 2>&1; then
    printf 'error: dry-run test unexpectedly created a Deployment\n' >&2
    return 1
  fi
  revision_after=$(helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    status "$release" --output json | jq -er '.version')
  [[ $revision_after == "$revision_before" ]] || {
    printf 'error: release revision changed during invalid-config tests\n' >&2
    return 1
  }
  rm -f -- "$render_output" "$api_output" "$manifest"
  trap - RETURN
  printf 'resilience_invalid_helm_values=rejected\n'
  printf 'resilience_invalid_kubernetes_object=rejected dry_run=server\n'
  printf 'resilience_invalid_configuration_test=pass release_revision_unchanged=%s\n' "$revision_before"
}

recover_baseline() {
  require_cluster
  require_observability_baseline
  "$script_dir/platform-lifecycle.sh" repair-sessions
  "$script_dir/platform-lifecycle.sh" validate
  "$script_dir/observability-lifecycle.sh" validate
  verify_fault_targets
  printf 'resilience_recovery=pass baseline=platform-and-observability\n'
}

show_status() {
  require_cluster
  helm --kubeconfig "$kubeconfig" --namespace "$namespace" status "$release" \
    --output json | jq '{status:.info.status,revision:.version,chart:.chart.metadata.version}'
  release_values | jq '{platform:.platform.enabled,observability:.observability.enabled,performance:(.performance.enabled // false)}'
  "${kubectl_ns[@]}" get deployment cn5g-amf cn5g-smf cn5g-upf
  "${kubectl_ns[@]}" get statefulset cn5g-mongodb
  "${kubectl_ns[@]}" get pvc mongodb-data-cn5g-mongodb-0 \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volumeName'
  if [[ -f $campaign_state ]]; then
    jq '{campaign_id,status,helm_revision,accepted_conditions:(.accepted | length)}' "$campaign_state"
  else
    printf 'resilience_campaign_state=absent\n'
  fi
  for item in amf smf upf; do
    if find "$raw_root" -maxdepth 2 -path "*-pilot-$item/manifest.json" -print -quit 2>/dev/null | grep -q .; then
      printf 'resilience_pilot_evidence=%s present\n' "$item"
    else
      printf 'resilience_pilot_evidence=%s absent\n' "$item"
    fi
  done
}

case "$action" in
  preflight) run_preflight ;;
  pilot) run_pilot ;;
  run-matrix) run_matrix ;;
  test-mongodb) test_mongodb ;;
  test-invalid-config) test_invalid_config ;;
  recover) recover_baseline ;;
  status) show_status ;;
esac
