#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/performance-campaign.sh analyze
       sudo scripts/performance-campaign.sh ACTION

Actions:
  preflight     Validate the accepted platform and observability baseline, host budget,
                version pins, experiment contract, chart, and render.
  build-image   Build and verify the project-owned pinned iperf3 image.
  load-image    Load only the verified benchmark image into kind.
  install       Add idle benchmark sidecars and ports, restore the five-UE
                session chain, and validate platform and observability plus the new boundary.
  pilot         Run one 15-second, one-UE path/ICMP/TCP/UDP mechanism pilot
                using the matrix traffic contract, then restore five UEs.
  run-matrix    Run or safely resume the accepted 1/3/5-UE matrix with three
                repetitions, concurrent per-UE traffic, and Prometheus data.
  analyze       Validate the complete raw campaign and deterministically write
                reviewed CSV, JSON, SVG plots, and the performance campaign report. No sudo.
  status        Show the exact release state, benchmark Pods, and image state.
  rollback --confirm
                Restore the exact recorded pre-performance campaign Helm revision and
                revalidate platform and observability without deleting retained data.

The full matrix requires preserved successful pilot evidence. Raw results stay
under ignored benchmarks/raw/ until deterministic analysis accepts them.
EOF
}

action=${1:-}
case "$action" in
  preflight|build-image|load-image|install|pilot|run-matrix|analyze|status) ;;
  rollback)
    [[ ${2:-} == --confirm ]] || {
      printf 'error: rollback requires --confirm\n' >&2
      exit 2
    }
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
  exec "$script_dir/analyze-performance.py" --project-root "$project_root"
fi

if (( EUID != 0 )) || [[ -z ${SUDO_UID:-} || -z ${SUDO_GID:-} ]]; then
  printf 'error: run this lifecycle through sudo from the normal account\n' >&2
  exit 3
fi

for command_name in awk chmod chown cmp cut date df docker grep helm ip jq kind \
  kubectl mkdir mktemp nproc python3 rm sed seq sha256sum sleep stat; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'error: required command is unavailable: %s\n' "$command_name" >&2
    exit 4
  }
done

# shellcheck source=../versions/kubernetes-runtime.env
source "$project_root/versions/kubernetes-runtime.env"
# shellcheck source=../versions/platform-runtime.env
source "$project_root/versions/platform-runtime.env"
# shellcheck source=../versions/performance-runtime.env
source "$project_root/versions/performance-runtime.env"

chart="$project_root/charts/cn5g"
performance_profile="$project_root/profiles/performance.yaml"
experiment="$project_root/benchmarks/performance/experiment.json"
dockerfile="$project_root/containers/benchmark/Dockerfile"
kubeconfig="$project_root/artifacts/kubernetes/cn5g.kubeconfig"
namespace=$CN5G_KUBERNETES_NAMESPACE
release=$CN5G_HELM_RELEASE_NAME
node_container="${KIND_CLUSTER_NAME}-control-plane"
image_state="$project_root/artifacts/kubernetes/performance-image.json"
rollback_state="$project_root/artifacts/kubernetes/performance-rollback.json"
raw_root="$project_root/benchmarks/raw/performance"
matrix_runner="$script_dir/run-performance-matrix.py"
matrix_state="$project_root/artifacts/kubernetes/performance-campaign.json"
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
    $(jq -r '.observability.enabled' <<<"$values") == true ]] || {
    printf 'error: performance campaign requires the accepted deployed platform and observability release\n' >&2
    return 1
  }
  printf 'observability_release=deployed-and-enabled\n'
}

verify_resource_budget() {
  local memory_kib disk_kib cores
  memory_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  disk_kib=$(df -Pk /var/lib/docker | awk 'NR == 2 {print $4}')
  cores=$(nproc)
  printf 'host_cpu_logical_cores=%s\n' "$cores"
  printf 'host_memory_available_gib=%s\n' "$((memory_kib / 1024 / 1024))"
  printf 'docker_filesystem_available_gib=%s\n' "$((disk_kib / 1024 / 1024))"
  (( memory_kib >= 5 * 1024 * 1024 )) || {
    printf 'error: performance campaign preparation requires at least 5 GiB available memory\n' >&2
    return 1
  }
  (( disk_kib >= 8 * 1024 * 1024 )) || {
    printf 'error: performance campaign preparation requires at least 8 GiB free Docker space\n' >&2
    return 1
  }
  printf 'performance_resource_budget=pass\n'
}

verify_version_contract() {
  [[ $PERFORMANCE_IMAGE == cn5g/benchmark:0.1.0 && \
    $PERFORMANCE_BASE_IMAGE_DIGEST =~ ^sha256:[0-9a-f]{64}$ && \
    $PERFORMANCE_IPERF3_VERSION == 3.19.1-r0 && \
    $PERFORMANCE_IPERF_PORT == 5201 && $PERFORMANCE_IPERF_PORT_COUNT == 5 ]] || {
    printf 'error: performance campaign version contract is invalid\n' >&2
    return 1
  }
  grep -Fq "FROM ${PERFORMANCE_BASE_IMAGE}@${PERFORMANCE_BASE_IMAGE_DIGEST}" "$dockerfile"
  grep -Fq "iperf3=${PERFORMANCE_IPERF3_VERSION}" "$dockerfile"
  grep -Fq "iproute2=${PERFORMANCE_IPROUTE2_VERSION}" "$dockerfile"
  grep -Fq "iputils=${PERFORMANCE_IPUTILS_VERSION}" "$dockerfile"
  printf 'performance_image_source_pin_validation=pass\n'
}

verify_experiment_contract() {
  python3 - "$experiment" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
data = json.loads(p.read_text(encoding="utf-8"))
assert data["schema_version"] == 1
assert data["topology"]["ue_levels"] == [1, 3, 5]
assert data["controls"]["repetitions"] == 3
assert data["controls"]["warm_up_seconds"] > 0
assert data["controls"]["measurement_seconds"] >= 10
assert data["controls"]["restore_replicas_after_each_run"] == 5
assert data["controls"]["iperf_server_port_by_ordinal"] == {
    str(i): 5201 + i for i in range(5)
}
assert data["controls"]["session_state_reset"]["scope"] == "before_each_condition"
assert data["traffic"]["tcp"]["forward_offered_rate"] == "unbounded"
assert data["traffic"]["tcp"]["reverse_offered_rate_per_ue_bits_per_second"] == 10_000_000
assert data["pilot"]["measurement_seconds"] == data["controls"]["measurement_seconds"]
assert data["pilot"]["reverse_offered_rate_bits_per_second"] == 10_000_000
assert data["abort_thresholds"]["route_bypass_allowed"] is False
assert data["publication"]["raw_data"] == "ignored"
assert len(data["topology"]["dnn_by_ordinal"]) == 5
PY
  printf 'performance_experiment_contract=pass levels=1,3,5 repetitions=3\n'
}

deterministic_render() {
  local render_dir
  render_dir=$(mktemp -d)
  trap 'rm -rf -- "$render_dir"' RETURN
  helm lint "$chart" --strict --values "$performance_profile"
  for suffix in one two; do
    helm template "$release" "$chart" --namespace "$namespace" \
      --kube-version 1.36.1 --values "$performance_profile" \
      > "$render_dir/$suffix.yaml"
  done
  cmp --silent "$render_dir/one.yaml" "$render_dir/two.yaml"
  python3 - "$render_dir/one.yaml" <<'PY'
import sys, yaml
items = [x for x in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if x]
ue = next(x for x in items if x["kind"] == "StatefulSet" and x["metadata"]["name"] == "cn5g-ue")
names = {x["name"] for x in ue["spec"]["template"]["spec"]["containers"]}
assert names == {"ue", "user-plane-metrics", "benchmark-client"}
for component in ("data-internet", "data-enterprise"):
    workload = next(x for x in items if x["kind"] == "Deployment" and x["metadata"]["name"] == f"cn5g-{component}")
    names = {x["name"] for x in workload["spec"]["template"]["spec"]["containers"]}
    assert names == {"data-network", "benchmark-server"}
PY
  rm -rf -- "$render_dir"
  trap - RETURN
  printf 'deterministic_performance_chart_render=pass\n'
}

run_preflight() {
  require_cluster
  verify_resource_budget
  require_observability_baseline
  "$script_dir/observability-lifecycle.sh" validate
  verify_version_contract
  verify_experiment_contract
  deterministic_render
  printf 'performance_preflight=pass\n'
  printf 'next_step=sudo ./scripts/performance-campaign.sh build-image\n'
}

write_image_state() {
  local image_id dockerfile_sha state_dir
  image_id=$(docker image inspect --format '{{.Id}}' "$PERFORMANCE_IMAGE")
  dockerfile_sha=$(sha256sum "$dockerfile" | awk '{print $1}')
  state_dir=${image_state%/*}
  mkdir -p "$state_dir"
  umask 077
  jq -n --arg image "$PERFORMANCE_IMAGE" --arg image_id "$image_id" \
    --arg dockerfile_sha256 "$dockerfile_sha" \
    --arg built_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{image:$image,image_id:$image_id,dockerfile_sha256:$dockerfile_sha256,built_at:$built_at}' \
    > "$image_state"
  chmod 600 "$image_state"
}

verify_local_image() {
  local state_image state_id current_id expected_sha current_sha platform packages
  [[ -f $image_state && ! -L $image_state && $(stat -c '%a' "$image_state") == 600 ]] || {
    printf 'error: verified performance campaign image state is absent or unsafe\n' >&2
    return 1
  }
  state_image=$(jq -er '.image' "$image_state")
  state_id=$(jq -er '.image_id' "$image_state")
  expected_sha=$(jq -er '.dockerfile_sha256' "$image_state")
  current_sha=$(sha256sum "$dockerfile" | awk '{print $1}')
  current_id=$(docker image inspect --format '{{.Id}}' "$PERFORMANCE_IMAGE")
  platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$PERFORMANCE_IMAGE")
  [[ $state_image == "$PERFORMANCE_IMAGE" && $state_id == "$current_id" && \
    $expected_sha == "$current_sha" && $platform == linux/amd64 ]] || {
    printf 'error: local benchmark image identity, source, or platform changed\n' >&2
    return 1
  }
  packages=$(docker run --rm --entrypoint /bin/sh "$PERFORMANCE_IMAGE" -ec \
    "installed=\$(apk info -v 2>/dev/null); \
     printf '%s\\n' \"\$installed\" | grep -Fx 'iperf3-${PERFORMANCE_IPERF3_VERSION}' >/dev/null; \
     printf '%s\\n' \"\$installed\" | grep -Fx 'iproute2-${PERFORMANCE_IPROUTE2_VERSION}' >/dev/null; \
     printf '%s\\n' \"\$installed\" | grep -Fx 'iputils-${PERFORMANCE_IPUTILS_VERSION}' >/dev/null; \
     iperf3 --version | head -n 1; ip -Version")
  printf '%s\n' "$packages"
  printf 'performance_local_image=verified image_id=%s platform=%s\n' "$current_id" "$platform"
}

build_image() {
  verify_version_contract
  docker build --platform linux/amd64 --pull \
    --file "$dockerfile" --tag "$PERFORMANCE_IMAGE" "$project_root"
  write_image_state
  verify_local_image
  printf 'performance_image_build=pass\n'
  printf 'next_step=sudo ./scripts/performance-campaign.sh load-image\n'
}

verify_node_image() {
  local inspect_json labels
  inspect_json=$(docker exec "$node_container" crictl inspecti "$PERFORMANCE_IMAGE")
  labels=$(jq -r '.info.imageSpec.config.Labels // .info.imageSpec.config.labels // {}' <<<"$inspect_json")
  [[ $(jq -r '.["cn5g.io/domain"] // ""' <<<"$labels") == performance && \
    $(jq -r '.["cn5g.io/iperf3-version"] // ""' <<<"$labels") == "$PERFORMANCE_IPERF3_VERSION" ]] || {
    printf 'error: kind runtime benchmark image labels are unexpected\n' >&2
    return 1
  }
  printf 'performance_node_image=verified\n'
}

load_image() {
  require_cluster
  verify_local_image
  kind load docker-image --name "$KIND_CLUSTER_NAME" "$PERFORMANCE_IMAGE"
  verify_node_image
  printf 'performance_image_load=pass\n'
  printf 'next_step=sudo ./scripts/performance-campaign.sh install\n'
}

mongodb_pvc_identity() {
  "${kubectl_ns[@]}" get pvc mongodb-data-cn5g-mongodb-0 --output json | \
    jq -c '{uid:.metadata.uid,volume:.spec.volumeName}'
}

record_rollback_state() {
  local revision pvc identity state_dir
  if [[ -f $rollback_state ]]; then
    [[ ! -L $rollback_state && $(stat -c '%a' "$rollback_state") == 600 ]] || {
      printf 'error: performance campaign rollback state is unsafe\n' >&2
      return 1
    }
    printf 'performance_rollback_state=already-recorded\n'
    return
  fi
  revision=$(helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    status "$release" --output json | jq -er '.version')
  pvc=$(mongodb_pvc_identity)
  identity=$(jq -er '.image_id' "$image_state")
  state_dir=${rollback_state%/*}
  mkdir -p "$state_dir"
  umask 077
  jq -n --argjson revision "$revision" --argjson pvc "$pvc" \
    --arg image_id "$identity" \
    '{baseline_revision:$revision,mongodb_pvc:$pvc,benchmark_image_id:$image_id}' \
    > "$rollback_state"
  chmod 600 "$rollback_state"
  printf 'performance_rollback_state=recorded baseline_revision=%s\n' "$revision"
}

verify_benchmark_workloads() {
  local ue_json deployment_json
  ue_json=$("${kubectl_ns[@]}" get statefulset cn5g-ue --output json)
  [[ $(jq -r '.status.readyReplicas // 0' <<<"$ue_json") == 5 ]] || {
    printf 'error: five UE replicas are not ready\n' >&2
    return 1
  }
  jq -e '
    .spec.template.spec.containers[] |
    select(.name == "benchmark-client") |
    .securityContext.capabilities.drop == ["ALL"] and
    .securityContext.privileged == false and
    .securityContext.allowPrivilegeEscalation == false
  ' >/dev/null <<<"$ue_json"
  for component in data-internet data-enterprise; do
    deployment_json=$("${kubectl_ns[@]}" get deployment "cn5g-$component" --output json)
    jq -e '
      .spec.template.spec.containers[] |
      select(.name == "benchmark-server") |
      .securityContext.capabilities.drop == ["ALL"] and
      .securityContext.privileged == false and
      .securityContext.allowPrivilegeEscalation == false
    ' >/dev/null <<<"$deployment_json"
    jq -e '
      [.spec.template.spec.containers[] |
       select(.name == "benchmark-server") |
       .ports[] | [.name, .containerPort, .protocol]] ==
      [["iperf-tcp-0",5201,"TCP"],["iperf-udp-0",5201,"UDP"],
       ["iperf-tcp-1",5202,"TCP"],["iperf-udp-1",5202,"UDP"],
       ["iperf-tcp-2",5203,"TCP"],["iperf-udp-2",5203,"UDP"],
       ["iperf-tcp-3",5204,"TCP"],["iperf-udp-3",5204,"UDP"],
       ["iperf-tcp-4",5205,"TCP"],["iperf-udp-4",5205,"UDP"]]
    ' >/dev/null <<<"$deployment_json" || {
      printf 'error: benchmark server does not expose the five-port concurrency contract\n' >&2
      return 1
    }
  done
  printf 'performance_benchmark_boundary=pass ue_clients=5 dnn_servers=2 ports_per_server=5 capabilities=none\n'
}

install_overlay() {
  local image_id enabled status
  require_cluster
  verify_resource_budget
  require_observability_baseline
  verify_local_image
  verify_node_image
  verify_experiment_contract
  deterministic_render
  image_id=$(jq -er '.image_id' "$image_state")
  status=$(helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    status "$release" --output json | jq -er '.info.status')
  enabled=$(release_values | jq -r '.performance.enabled // false')
  [[ $status == deployed && $enabled =~ ^(true|false)$ ]] || {
    printf 'error: release state is outside the performance campaign contract\n' >&2
    return 1
  }
  record_rollback_state
  helm upgrade "$release" "$chart" --kubeconfig "$kubeconfig" \
    --namespace "$namespace" --values "$performance_profile" \
    --set-string "images.benchmark.expectedImageID=$image_id" \
    --dry-run=server >/dev/null
  printf 'server_side_performance_dry_run=pass\n'
  helm upgrade "$release" "$chart" --kubeconfig "$kubeconfig" \
    --namespace "$namespace" --values "$performance_profile" \
    --set-string "images.benchmark.expectedImageID=$image_id" \
    --rollback-on-failure --wait=watcher --timeout 15m
  "${kubectl_ns[@]}" rollout status deployment/cn5g-data-internet --timeout=5m
  "${kubectl_ns[@]}" rollout status deployment/cn5g-data-enterprise --timeout=5m
  "${kubectl_ns[@]}" rollout status statefulset/cn5g-ue --timeout=10m
  "$script_dir/platform-lifecycle.sh" repair-sessions
  "$script_dir/observability-lifecycle.sh" validate
  verify_benchmark_workloads
  printf 'performance_install=pass\n'
  printf 'next_step=sudo ./scripts/performance-campaign.sh pilot\n'
}

restart_total() {
  "${kubectl_ns[@]}" get pods -l app.kubernetes.io/instance=cn5g --output json | \
    jq '[.items[].status.containerStatuses[]?.restartCount] | add // 0'
}

host_abort_gate() {
  local memory_kib disk_kib
  memory_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  disk_kib=$(df -Pk /var/lib/docker | awk 'NR == 2 {print $4}')
  printf 'host_available_memory_mib=%s abort_floor_mib=3072\n' "$((memory_kib / 1024))"
  printf 'docker_free_space_mib=%s abort_floor_mib=6144\n' "$((disk_kib / 1024))"
  (( memory_kib >= 3072 * 1024 )) || {
    printf 'error: abort threshold reached: available memory below 3072 MiB\n' >&2
    return 1
  }
  (( disk_kib >= 6144 * 1024 )) || {
    printf 'error: abort threshold reached: Docker free space below 6144 MiB\n' >&2
    return 1
  }
}

wait_for_ue_replicas() {
  local expected=$1 object observed attempt
  for attempt in $(seq 1 300); do
    object=$("${kubectl_ns[@]}" get statefulset cn5g-ue --output json)
    observed=$(jq -r --argjson expected "$expected" '
      (.spec.replicas == $expected) and
      ((.status.observedGeneration // 0) >= .metadata.generation) and
      ((.status.replicas // 0) == $expected) and
      ((.status.currentReplicas // 0) == $expected) and
      ((.status.updatedReplicas // 0) == $expected) and
      ((.status.readyReplicas // 0) == $expected) and
      (.status.currentRevision == .status.updateRevision)
    ' <<<"$object")
    [[ $observed == true ]] && {
      printf 'performance_ue_statefulset=converged replicas=%s\n' "$expected"
      return 0
    }
    sleep 2
  done
  printf 'error: UE StatefulSet did not converge to %s ready replicas\n' "$expected" >&2
  return 1
}

restore_five_ues() {
  "${kubectl_ns[@]}" scale statefulset cn5g-ue --replicas=5 >/dev/null
  wait_for_ue_replicas 5
}

run_pilot() {
  local values run_id run_dir ue_ip endpoint_ip route policy_rule restarts_before restarts_after
  local started finished experiment_sha image_id release_revision
  local warm_up_seconds measurement_seconds reverse_bitrate udp_bitrate
  local pilot_result=0 pilot_restore_pending=0
  require_cluster
  require_observability_baseline
  values=$(release_values)
  [[ $(jq -r '.performance.enabled // false' <<<"$values") == true ]] || {
    printf 'error: install the performance campaign overlay before the pilot\n' >&2
    return 1
  }
  verify_local_image
  verify_benchmark_workloads
  host_abort_gate
  warm_up_seconds=$(jq -er '.controls.warm_up_seconds' "$experiment")
  measurement_seconds=$(jq -er '.pilot.measurement_seconds' "$experiment")
  reverse_bitrate=$(jq -er '.pilot.reverse_offered_rate_bits_per_second' "$experiment")
  udp_bitrate=$(jq -er '.pilot.udp_rate_bits_per_second' "$experiment")
  # Restart the DNN Pods before rebuilding the 5G session chain. Their Pod
  # addresses are installed into the UPF's fail-closed tables 1060/1061 when
  # the UPF starts, so restarting them after the UPF would leave stale /32
  # routes and make the benchmark endpoint unreachable.
  for component in data-internet data-enterprise; do
    "${kubectl_ns[@]}" rollout restart "deployment/cn5g-$component"
    "${kubectl_ns[@]}" rollout status "deployment/cn5g-$component" --timeout=300s
  done
  "$script_dir/platform-lifecycle.sh" repair-sessions
  printf 'performance_pilot_session_state=clean benchmark_servers=clean\n'
  run_id=$(date -u +%Y%m%dT%H%M%SZ)-pilot
  run_dir="$raw_root/$run_id"
  mkdir -p "$run_dir"
  chmod 700 "$run_dir"
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  experiment_sha=$(sha256sum "$experiment" | awk '{print $1}')
  image_id=$(jq -er '.image_id' "$image_state")
  release_revision=$(helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    status "$release" --output json | jq -er '.version')
  restarts_before=$(restart_total)

  pilot_restore_pending=1
  trap 'if (( pilot_restore_pending == 1 )); then restore_five_ues >/dev/null 2>&1 || true; fi' EXIT
  "${kubectl_ns[@]}" scale statefulset cn5g-ue --replicas=1 >/dev/null
  wait_for_ue_replicas 1
  ue_ip=$("${kubectl_ns[@]}" exec cn5g-ue-0 -c benchmark-client -- \
    ip -o -4 address show dev uesimtun0 | awk '{print $4}' | cut -d/ -f1)
  endpoint_ip=$("${kubectl_ns[@]}" get endpointslice \
    -l kubernetes.io/service-name=cn5g-data-internet --output json | \
    jq -er '.items[0].endpoints[0].addresses[0]')
  route=$("${kubectl_ns[@]}" exec cn5g-ue-0 -c benchmark-client -- \
    ip -4 route get "$endpoint_ip" from "$ue_ip")
  policy_rule=$("${kubectl_ns[@]}" exec cn5g-ue-0 -c benchmark-client -- \
    ip -4 rule show)
  printf '%s\n' "$route" > "$run_dir/route.txt"
  printf '%s\n' "$policy_rule" > "$run_dir/policy-rule.txt"
  if [[ $route != *"from $ue_ip dev uesimtun0 table 1000"* || \
        $policy_rule != *"from $ue_ip lookup 1000"* ]]; then
    printf 'error: benchmark route bypasses the UE TUN; traffic was not started\n' >&2
    pilot_result=1
  else
    "${kubectl_ns[@]}" exec cn5g-ue-0 -c ue -- \
      ping -I uesimtun0 -c 5 -i 0.2 -W 2 "$endpoint_ip" \
      > "$run_dir/icmp.txt" || pilot_result=1
    "${kubectl_ns[@]}" exec cn5g-ue-0 -c benchmark-client -- \
      iperf3 --client "$endpoint_ip" --port "$PERFORMANCE_IPERF_PORT" \
      --bind "$ue_ip" --omit "$warm_up_seconds" --time "$measurement_seconds" --json \
      > "$run_dir/tcp-forward.json" || pilot_result=1
    "${kubectl_ns[@]}" exec cn5g-ue-0 -c benchmark-client -- \
      iperf3 --client "$endpoint_ip" --port "$PERFORMANCE_IPERF_PORT" \
      --bind "$ue_ip" --omit "$warm_up_seconds" --time "$measurement_seconds" \
      --reverse --bitrate "$reverse_bitrate" --json \
      > "$run_dir/tcp-reverse.json" || pilot_result=1
    "${kubectl_ns[@]}" exec cn5g-ue-0 -c benchmark-client -- \
      iperf3 --client "$endpoint_ip" --port "$PERFORMANCE_IPERF_PORT" \
      --bind "$ue_ip" --omit "$warm_up_seconds" --time "$measurement_seconds" \
      --udp --bitrate "$udp_bitrate" --json \
      > "$run_dir/udp.json" || pilot_result=1
  fi
  finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  restore_five_ues || pilot_result=1
  pilot_restore_pending=0
  trap - EXIT
  restarts_after=$(restart_total)
  if (( restarts_after != restarts_before )); then
    printf 'error: container restart count changed during pilot: %s -> %s\n' \
      "$restarts_before" "$restarts_after" >&2
    pilot_result=1
  fi
  if (( pilot_result == 0 )); then
    if ! python3 - "$run_dir" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
for name in ("tcp-forward.json", "tcp-reverse.json", "udp.json"):
    data = json.loads((p / name).read_text(encoding="utf-8"))
    if data.get("error"):
        raise SystemExit(f"{name}: {data['error']}")
    if name == "udp.json":
        assert data["end"]["sum"]["bits_per_second"] > 0
        assert data["end"]["sum"]["lost_percent"] >= 0
    else:
        assert data["end"]["sum_received"]["bits_per_second"] > 0
text = (p / "icmp.txt").read_text(encoding="utf-8")
assert "0% packet loss" in text
PY
    then
      printf 'error: pilot output did not satisfy the machine-readable result contract\n' >&2
      pilot_result=1
    fi
  fi
  jq -n --arg run_id "$run_id" --arg started "$started" --arg finished "$finished" \
    --arg ue_ip "$ue_ip" --arg endpoint_ip "$endpoint_ip" \
    --arg route "$route" --arg policy_rule "$policy_rule" \
    --arg experiment_sha256 "$experiment_sha" --arg benchmark_image_id "$image_id" \
    --argjson helm_revision "$release_revision" \
    --argjson restarts_before "$restarts_before" \
    --argjson restarts_after "$restarts_after" --argjson result "$pilot_result" \
    '{run_id:$run_id,started:$started,finished:$finished,ue_level:1,ue_ip:$ue_ip,endpoint_ip:$endpoint_ip,route:$route,policy_rule:$policy_rule,experiment_sha256:$experiment_sha256,benchmark_image_id:$benchmark_image_id,helm_revision:$helm_revision,restarts_before:$restarts_before,restarts_after:$restarts_after,result:(if $result == 0 then "pass" else "fail" end)}' \
    > "$run_dir/manifest.json"
  chmod 600 "$run_dir"/*
  chown -R "$SUDO_UID:$SUDO_GID" "$run_dir"
  host_abort_gate || pilot_result=1
  if ! "$script_dir/platform-lifecycle.sh" validate; then
    printf 'error: five-UE baseline did not recover; run platform repair-sessions\n' >&2
    pilot_result=1
  fi
  (( pilot_result == 0 )) || {
    printf 'performance_pilot=fail raw_evidence=%s\n' "$run_dir" >&2
    return 1
  }
  printf 'performance_route_enforcement=pass device=uesimtun0\n'
  printf 'performance_pilot=pass raw_evidence=%s\n' "$run_dir"
  printf 'next_step=sudo ./scripts/performance-campaign.sh run-matrix\n'
}

run_matrix() {
  require_cluster
  require_observability_baseline
  verify_local_image
  verify_node_image
  verify_experiment_contract
  verify_benchmark_workloads
  host_abort_gate
  if ! python3 "$matrix_runner" \
    --project-root "$project_root" \
    --kubeconfig "$kubeconfig" \
    --namespace "$namespace" \
    --observability-namespace cn5g-observability \
    --experiment "$experiment" \
    --raw-root "$raw_root" \
    --state-file "$matrix_state"; then
    printf 'error: performance campaign matrix stopped; rerun the same command after reviewing the retained failed attempt\n' >&2
    return 1
  fi
  "$script_dir/platform-lifecycle.sh" validate
  "$script_dir/observability-lifecycle.sh" validate
  printf 'performance_matrix_validation=pass\n'
  printf 'next_step=return the final matrix output for evidence review and deterministic analysis\n'
}

rollback_overlay() {
  local baseline expected_pvc current_pvc
  require_cluster
  [[ -f $rollback_state && ! -L $rollback_state && $(stat -c '%a' "$rollback_state") == 600 ]] || {
    printf 'error: performance campaign rollback state is absent or unsafe\n' >&2
    return 1
  }
  baseline=$(jq -er '.baseline_revision' "$rollback_state")
  expected_pvc=$(jq -c '.mongodb_pvc' "$rollback_state")
  current_pvc=$(mongodb_pvc_identity)
  [[ $current_pvc == "$expected_pvc" ]] || {
    printf 'error: MongoDB PVC identity changed before rollback\n' >&2
    return 1
  }
  helm --kubeconfig "$kubeconfig" --namespace "$namespace" rollback \
    "$release" "$baseline" --wait=watcher --timeout 15m
  current_pvc=$(mongodb_pvc_identity)
  [[ $current_pvc == "$expected_pvc" ]] || {
    printf 'error: MongoDB PVC identity changed during rollback\n' >&2
    return 1
  }
  "$script_dir/platform-lifecycle.sh" repair-sessions
  "$script_dir/observability-lifecycle.sh" validate
  rm -- "$rollback_state"
  printf 'performance_rollback=pass target_revision=%s mongodb_pvc_identity=preserved\n' "$baseline"
}

show_status() {
  require_cluster
  helm --kubeconfig "$kubeconfig" --namespace "$namespace" \
    status "$release" --output json | jq '{status:.info.status,revision:.version,chart:.chart.metadata.version}'
  release_values | jq '{platform:.platform.enabled,observability:.observability.enabled,performance:(.performance.enabled // false)}'
  "${kubectl_ns[@]}" get pods -l app.kubernetes.io/instance=cn5g \
    -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount' | \
    grep -E 'NAME|cn5g-(ue|data-internet|data-enterprise)'
  if [[ -f $image_state ]]; then verify_local_image; else printf 'performance_local_image_state=absent\n'; fi
}

case "$action" in
  preflight) run_preflight ;;
  build-image) build_image ;;
  load-image) load_image ;;
  install) install_overlay ;;
  pilot) run_pilot ;;
  run-matrix) run_matrix ;;
  rollback) rollback_overlay ;;
  status) show_status ;;
esac
