#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/phase09-lab.sh ACTION
       sudo ./scripts/phase09-lab.sh image-gate|privileged-gate
       sudo ./scripts/phase09-lab.sh promote-images
       sudo ./scripts/phase09-lab.sh rollback-images --confirm

Actions:
  preflight         Check Phase 9 inputs, repository state, resource budget,
                    and the accepted Phase 7/8 reviewed evidence.
  bootstrap-tools   Download official pinned CI tools into ignored artifacts
                    and verify every archive or binary by SHA-256.
  quality           Run documentation, link, shell, Python, Dockerfile,
                    workflow, deterministic-generator, and privacy checks.
  manifests         Lint and deterministically render both Helm charts, then
                    run Kubernetes schema and policy-as-code checks.
  scan-repository   Scan Git history/worktree for secrets and scan source,
                    configuration, and dependencies with Trivy.
  build-images      Build every released project image from pinned inputs.
  scan-images       Scan all Phase 9 images and retain machine-readable JSON.
  sbom              Generate SPDX JSON SBOMs for all Phase 9 images.
  test-controls     Prove unpinned workflows/images, privileged manifests,
                    and a synthetic secret are rejected.
  safe-gate         Run every non-privileged deterministic hosted-CI gate.
  image-gate        Build, scan, and generate SBOMs for all released images.
  all-safe          Run safe-gate followed by image-gate.
  promote-images    Promote the accepted data-network security rebuild into
                    kind, upgrade the Helm release, and validate Phases 5/6.
  rollback-images   Restore the exact pre-promotion data-network image and
                    Helm revision. Requires the literal --confirm argument.
  privileged-gate  Run the real Phase 5/6 cluster validations and verify the
                    reviewed Phase 7/8 evidence. This action is local only.
  status            Report tool, evidence, and gate state without mutation.

Downloaded tools and raw reports remain under ignored artifacts/phase-09.
This script never registers a self-hosted runner, deploys from CI, pushes an
image, changes host networking, or deletes cluster/host resources.
EOF
}

action=${1:-}
case "$action" in
  rollback-images)
    [[ $# -eq 2 && ${2:-} == --confirm ]] || {
      printf 'error: rollback-images requires the literal --confirm argument\n' >&2
      usage >&2
      exit 2
    }
    ;;
  preflight|bootstrap-tools|quality|manifests|scan-repository|build-images|scan-images|sbom|test-controls|safe-gate|image-gate|all-safe|promote-images|privileged-gate|status)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
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

# shellcheck source=../versions/phase-09.env
source "$project_root/versions/phase-09.env"
# shellcheck source=../versions/phase-02.env
source "$project_root/versions/phase-02.env"
# shellcheck source=../versions/phase-03.env
source "$project_root/versions/phase-03.env"
# shellcheck source=../versions/phase-04.env
source "$project_root/versions/phase-04.env"

tool_root="$project_root/artifacts/tools/phase-09"
report_root="$project_root/artifacts/phase-09"
render_root="$report_root/rendered"
scan_root="$report_root/scans"
sbom_root="$report_root/sbom"
promotion_state="$report_root/image-promotion.json"
bin_root="$tool_root/bin"
export PATH="$bin_root:$PATH"

core_chart="$project_root/charts/cn5g"
obs_chart="$project_root/charts/cn5g-observability"
core_values=(
  --values "$core_chart/values-phase05.yaml"
  --values "$core_chart/values-phase06.yaml"
)

image_names=(open5gs ueransim data-network benchmark feasibility-probe)
core_kubeconfig="$project_root/artifacts/kubernetes/cn5g.kubeconfig"
core_namespace=$CN5G_KUBERNETES_NAMESPACE
core_release=$CN5G_HELM_RELEASE_NAME
data_network_release_image=$DATA_NETWORK_LOCAL_IMAGE
data_network_rollback_image='cn5g/data-network:phase09-rollback'

ensure_normal_user() {
  if (( EUID == 0 )); then
    printf 'error: run this non-privileged action as the normal user\n' >&2
    return 1
  fi
}

ensure_docker_operator() {
  if (( EUID == 0 )) && [[ -z ${SUDO_UID:-} || -z ${SUDO_GID:-} ]]; then
    printf 'error: root Docker actions must be invoked through sudo by the normal user\n' >&2
    return 1
  fi
  docker info >/dev/null 2>&1 || {
    printf 'error: Docker access is unavailable; run this Docker action through sudo locally\n' >&2
    return 1
  }
}

restore_report_ownership() {
  if (( EUID == 0 )) && [[ -n ${SUDO_UID:-} && -n ${SUDO_GID:-} ]]; then
    chown -R "$SUDO_UID:$SUDO_GID" "$report_root"
  fi
}

ensure_cluster_operator() {
  ensure_docker_operator
  if (( EUID != 0 )) || [[ -z ${SUDO_UID:-} || -z ${SUDO_GID:-} ]]; then
    printf 'error: run this cluster action through sudo from the normal account\n' >&2
    return 1
  fi
  [[ -s $core_kubeconfig ]] || {
    printf 'error: project kubeconfig is absent\n' >&2
    return 1
  }
  local context
  context=$(kubectl --kubeconfig "$core_kubeconfig" config current-context)
  [[ $context == "$KIND_CONTEXT_NAME" ]] || {
    printf 'error: unexpected project kubeconfig context: %s\n' "$context" >&2
    return 1
  }
}

require_command() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || {
      printf 'error: required command is unavailable: %s\n' "$command_name" >&2
      return 1
    }
  done
}

verify_resource_budget() {
  local memory_kib docker_path disk_kib
  memory_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  docker_path=/var/lib/docker
  [[ -e $docker_path ]] || docker_path="$project_root"
  disk_kib=$(df -Pk "$docker_path" | awk 'NR == 2 {print $4}')
  printf 'host_memory_available_gib=%s\n' "$((memory_kib / 1024 / 1024))"
  printf 'phase09_filesystem_available_gib=%s\n' "$((disk_kib / 1024 / 1024))"
  (( memory_kib >= 3 * 1024 * 1024 )) || {
    printf 'error: Phase 9 requires at least 3 GiB available memory\n' >&2
    return 1
  }
  (( disk_kib >= 6 * 1024 * 1024 )) || {
    printf 'error: Phase 9 requires at least 6 GiB available disk space\n' >&2
    return 1
  }
  printf 'phase09_resource_budget=pass\n'
}

verify_reviewed_evidence() {
  python3 - "$project_root/benchmarks/phase-07/results/summary.json" \
    "$project_root/benchmarks/phase-08/results/summary.json" <<'PY'
import json, sys
phase7, phase8 = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:])
assert phase7["campaign"]["status"] == "reviewed_complete"
assert phase8["campaign"]["status"] == "reviewed_complete"
assert phase7["campaign"]["accepted_attempt_count"] == 9
assert phase8["campaign"]["accepted_attempt_count"] == 9
PY
  printf 'phase09_dependency_evidence=pass phase07=9 phase08=9\n'
}

verify_version_contract() {
  python3 - "$project_root/versions/phase-09.env" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
assert "latest" not in text.lower()
assert len(re.findall(r"_URL='https://github.com/", text)) == 11
assert len(re.findall(r"_SHA256='[0-9a-f]{64}'", text)) == 11
assert len(re.findall(r"_ACTION_SHA='[0-9a-f]{40}'", text)) == 3
PY
  printf 'phase09_tool_pin_contract=pass tools=11 actions=3\n'
}

preflight() {
  ensure_normal_user
  require_command awk df docker git helm python3 sha256sum tar
  verify_resource_budget
  verify_reviewed_evidence
  verify_version_contract
  "$script_dir/check-phase09-policies.py" dockerfiles
  git -C "$project_root" diff --check
  printf 'phase09_preflight=pass\n'
  printf 'next_step=./scripts/phase09-lab.sh bootstrap-tools\n'
}

download() {
  local url=$1 destination=$2 expected=$3 actual
  if [[ ! -f $destination ]]; then
    curl --fail --location --proto '=https' --tlsv1.2 \
      --retry 3 --output "$destination" "$url"
  fi
  actual=$(sha256sum "$destination" | awk '{print $1}')
  [[ $actual == "$expected" ]] || {
    printf 'error: checksum mismatch for %s\n' "${destination##*/}" >&2
    return 1
  }
}

install_archive() {
  local name=$1 url=$2 checksum=$3 archive temp candidate
  archive="$tool_root/downloads/${name}.tar.gz"
  download "$url" "$archive" "$checksum"
  temp=$(mktemp -d "$tool_root/.extract-${name}.XXXXXX")
  tar --extract --gzip --file "$archive" --directory "$temp"
  candidate=$(find "$temp" -type f -name "$name" -print -quit)
  [[ -n $candidate ]] || { printf 'error: %s binary absent from archive\n' "$name" >&2; return 1; }
  install -m 0755 "$candidate" "$bin_root/$name"
  rm -rf -- "$temp"
}

install_binary() {
  local name=$1 url=$2 checksum=$3 binary
  binary="$tool_root/downloads/$name"
  download "$url" "$binary" "$checksum"
  install -m 0755 "$binary" "$bin_root/$name"
}

bootstrap_tools() {
  ensure_normal_user
  require_command awk curl find install mkdir mktemp rm sha256sum tar
  mkdir -p "$bin_root" "$tool_root/downloads"
  install_archive actionlint "$PHASE_09_ACTIONLINT_URL" "$PHASE_09_ACTIONLINT_SHA256"
  install_archive rumdl "$PHASE_09_RUMDL_URL" "$PHASE_09_RUMDL_SHA256"
  install_archive gitleaks "$PHASE_09_GITLEAKS_URL" "$PHASE_09_GITLEAKS_SHA256"
  install_archive trivy "$PHASE_09_TRIVY_URL" "$PHASE_09_TRIVY_SHA256"
  install_archive syft "$PHASE_09_SYFT_URL" "$PHASE_09_SYFT_SHA256"
  install_archive kubeconform "$PHASE_09_KUBECONFORM_URL" "$PHASE_09_KUBECONFORM_SHA256"
  install_archive conftest "$PHASE_09_CONFTEST_URL" "$PHASE_09_CONFTEST_SHA256"
  install_archive lychee "$PHASE_09_LYCHEE_URL" "$PHASE_09_LYCHEE_SHA256"
  install_archive shellcheck "$PHASE_09_SHELLCHECK_URL" "$PHASE_09_SHELLCHECK_SHA256"
  install_binary hadolint "$PHASE_09_HADOLINT_URL" "$PHASE_09_HADOLINT_SHA256"
  install_binary yq "$PHASE_09_YQ_URL" "$PHASE_09_YQ_SHA256"
  actionlint --version
  rumdl --version
  gitleaks version
  trivy --version
  syft version
  kubeconform -v
  conftest --version
  lychee --version
  shellcheck --version | sed -n '1,2p'
  hadolint --version
  yq --version
  printf 'phase09_tool_bootstrap=pass tools=11 checksums=verified\n'
  printf 'next_step=./scripts/phase09-lab.sh quality\n'
}

require_tools() {
  require_command actionlint conftest gitleaks hadolint kubeconform lychee rumdl shellcheck syft trivy yq
}

quality() {
  ensure_normal_user
  require_tools
  require_command bash find git helm python3 xargs
  "$script_dir/check-phase09-policies.py" all
  find "$project_root/scripts" "$project_root/containers" -type f -name '*.sh' -print0 \
    | xargs -0 -r -n1 bash -n
  shellcheck --severity=warning "$project_root/scripts/phase09-lab.sh"
  # Three warning classes are pre-existing and intentional: compatibility
  # CDPATH syntax, bounded-loop counters used only for retries, and traps that
  # deliberately capture validated temporary paths at definition time.
  find "$project_root/scripts" "$project_root/containers" -type f -name '*.sh' -print0 \
    | xargs -0 -r shellcheck --severity=warning \
      --exclude=SC1007,SC2034,SC2064
  find "$project_root/containers" -type f -name Dockerfile -print0 \
    | xargs -0 -r hadolint --config "$project_root/.hadolint.yaml"
  rumdl check "$project_root/README.md" "$project_root/docs" "$project_root/reports" \
    "$project_root/benchmarks" "$project_root/charts" "$project_root/tests" \
    --disable MD013,MD033
  find "$project_root" -type f -name '*.md' \
    -not -path "$project_root/migration/*" -not -path "$project_root/artifacts/*" -print0 \
    | xargs -0 -r lychee --offline --no-progress --config "$project_root/.lychee.toml"
  actionlint "$project_root/.github/workflows/ci.yml"
  python3 -m unittest discover -s "$project_root/tests" -p 'test_*.py'
  "$script_dir/generate-phase07-dashboard-metrics.py" --check
  "$script_dir/generate-phase08-dashboard-metrics.py" --check
  git -C "$project_root" diff --check
  printf 'phase09_quality_gate=pass\n'
}

render_charts() {
  mkdir -p "$render_root"
  helm lint "$core_chart" --strict "${core_values[@]}"
  helm lint "$obs_chart" --strict
  helm template cn5g "$core_chart" --namespace cn5g \
    --kube-version "$PHASE_09_KUBERNETES_VERSION" "${core_values[@]}" \
    >"$render_root/cn5g.yaml"
  helm template cn5g-observability "$obs_chart" --namespace cn5g-observability \
    --kube-version "$PHASE_09_KUBERNETES_VERSION" \
    >"$render_root/cn5g-observability.yaml"
  helm template cn5g "$core_chart" --namespace cn5g \
    --kube-version "$PHASE_09_KUBERNETES_VERSION" "${core_values[@]}" \
    >"$render_root/cn5g-repeat.yaml"
  cmp "$render_root/cn5g.yaml" "$render_root/cn5g-repeat.yaml"
  rm -f -- "$render_root/cn5g-repeat.yaml"
}

manifests() {
  ensure_normal_user
  require_tools
  require_command cmp helm mkdir rm
  render_charts
  kubeconform -strict -summary -kubernetes-version 1.36.0 \
    "$render_root/cn5g.yaml" "$render_root/cn5g-observability.yaml"
  conftest test --policy "$project_root/policy" \
    "$render_root/cn5g.yaml" "$render_root/cn5g-observability.yaml"
  printf 'phase09_manifest_gate=pass charts=2 schema=kubernetes-1.36 policy=conftest\n'
}

scan_repository() {
  ensure_normal_user
  require_tools
  mkdir -p "$scan_root"
  gitleaks git "$project_root" --no-banner --redact \
    --report-format json --report-path "$scan_root/gitleaks.json"
  trivy fs --no-progress --scanners vuln,misconfig,secret --severity HIGH,CRITICAL \
    --skip-dirs "$project_root/artifacts" \
    --skip-dirs "$project_root/benchmarks/raw" \
    --skip-dirs "$project_root/migration" \
    --ignorefile "$project_root/.trivyignore.yaml" \
    --ignore-unfixed --exit-code 1 --format json \
    --output "$scan_root/repository-trivy.json" "$project_root"
  chmod 0600 "$scan_root/gitleaks.json" "$scan_root/repository-trivy.json"
  printf 'phase09_repository_scan=pass secrets=absent severity=high-critical\n'
}

build_images() {
  ensure_docker_operator
  require_command docker
  docker build --tag cn5g/open5gs:phase09 \
    --file "$project_root/containers/open5gs/Dockerfile" "$project_root"
  docker build --tag cn5g/ueransim:phase09 \
    --file "$project_root/containers/ueransim/Dockerfile" "$project_root"
  docker build --tag cn5g/data-network:phase09 \
    --file "$project_root/containers/data-network/Dockerfile" "$project_root"
  docker build --tag cn5g/benchmark:phase09 \
    --file "$project_root/containers/benchmark/Dockerfile" "$project_root"
  docker build --tag cn5g/feasibility-probe:phase09 \
    --build-arg UERANSIM_BASE_IMAGE=cn5g/ueransim:phase09 \
    --file "$project_root/containers/feasibility-probe/Dockerfile" "$project_root"
  printf 'phase09_image_build=pass images=5 registry_push=none\n'
}

require_images() {
  local image
  for image in "${image_names[@]}"; do
    docker image inspect "cn5g/$image:phase09" >/dev/null 2>&1 || {
      printf 'error: Phase 9 image is absent: cn5g/%s:phase09\n' "$image" >&2
      return 1
    }
  done
}

verify_accepted_alpine_images() {
  local data_id data_size benchmark_id benchmark_size
  data_id=$(docker image inspect --format '{{.Id}}' "$PHASE_09_DATA_NETWORK_IMAGE")
  data_size=$(docker image inspect --format '{{.Size}}' "$PHASE_09_DATA_NETWORK_IMAGE")
  benchmark_id=$(docker image inspect --format '{{.Id}}' "$PHASE_09_BENCHMARK_IMAGE")
  benchmark_size=$(docker image inspect --format '{{.Size}}' "$PHASE_09_BENCHMARK_IMAGE")
  [[ $data_id == "$PHASE_09_DATA_NETWORK_IMAGE_ID" &&
     $data_size == "$PHASE_09_DATA_NETWORK_IMAGE_SIZE_BYTES" ]] || {
    printf 'error: accepted data-network image identity or size changed\n' >&2
    return 1
  }
  [[ $benchmark_id == "$PHASE_09_BENCHMARK_IMAGE_ID" &&
     $benchmark_size == "$PHASE_09_BENCHMARK_IMAGE_SIZE_BYTES" ]] || {
    printf 'error: accepted benchmark image identity or size changed\n' >&2
    return 1
  }
  [[ $PHASE_09_DATA_NETWORK_IMAGE_ID == "$DATA_NETWORK_LOCAL_IMAGE_ID" ]] || {
    printf 'error: Phase 2 and Phase 9 data-network identities diverge\n' >&2
    return 1
  }
  printf 'phase09_alpine_image_identity=pass images=2\n'
}

verify_image_evidence() {
  local image
  for image in "${image_names[@]}"; do
    [[ -s $scan_root/images/$image.json ]] || {
      printf 'error: Phase 9 scan evidence is absent for %s\n' "$image" >&2
      return 1
    }
    jq -e '
      ([.Results[]? | (.Vulnerabilities // [])[]] | length) == 0 and
      ([.Results[]? | (.Secrets // [])[]] | length) == 0
    ' "$scan_root/images/$image.json" >/dev/null || {
      printf 'error: Phase 9 scan evidence contains a finding for %s\n' "$image" >&2
      return 1
    }
    jq -e '
      .spdxVersion == "SPDX-2.3" and
      (.packages | type == "array" and length > 0)
    ' "$sbom_root/$image.spdx.json" >/dev/null || {
      printf 'error: Phase 9 SPDX evidence is absent or invalid for %s\n' "$image" >&2
      return 1
    }
  done
  printf 'phase09_image_evidence=pass scans=5 sboms=5\n'
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
  [[ $config_name =~ ^[0-9a-f]{64}$ ]] || {
    printf 'error: invalid runtime configuration identity for %s\n' "$image" >&2
    return 1
  }
  printf 'sha256:%s\n' "$config_name"
}

capture_promotion_state() {
  local current_id current_size current_revision
  mkdir -p "$report_root"
  if [[ -e $promotion_state || -L $promotion_state ]]; then
    [[ -f $promotion_state && ! -L $promotion_state ]] || {
      printf 'error: Phase 9 promotion state is unsafe\n' >&2
      return 1
    }
    [[ $(stat -c '%a' "$promotion_state") == 600 ]] || {
      printf 'error: Phase 9 promotion state must use mode 600\n' >&2
      return 1
    }
    jq -e '
      (.core_revision | type == "number") and
      (.previous_data_network_image_id | test("^sha256:[0-9a-f]{64}$")) and
      (.accepted_data_network_image_id | test("^sha256:[0-9a-f]{64}$"))
    ' "$promotion_state" >/dev/null || {
      printf 'error: Phase 9 promotion state is invalid\n' >&2
      return 1
    }
    printf 'phase09_promotion_rollback_state=already-recorded\n'
    return 0
  fi
  current_id=$(docker image inspect --format '{{.Id}}' "$data_network_release_image")
  current_size=$(docker image inspect --format '{{.Size}}' "$data_network_release_image")
  [[ $current_id != "$PHASE_09_DATA_NETWORK_IMAGE_ID" ]] || {
    printf 'error: release image is already promoted but rollback state is absent\n' >&2
    return 1
  }
  current_revision=$(helm --kubeconfig "$core_kubeconfig" \
    --namespace "$core_namespace" status "$core_release" --output json | \
    jq -er '.version')
  docker tag "$data_network_release_image" "$data_network_rollback_image"
  jq -n --argjson core_revision "$current_revision" \
    --arg previous_id "$current_id" --argjson previous_size "$current_size" \
    --arg accepted_id "$PHASE_09_DATA_NETWORK_IMAGE_ID" \
    '{schema_version:1,core_revision:$core_revision,previous_data_network_image_id:$previous_id,previous_data_network_size_bytes:$previous_size,accepted_data_network_image_id:$accepted_id}' \
    >"$promotion_state"
  chown "$SUDO_UID:$SUDO_GID" "$promotion_state"
  chmod 0600 "$promotion_state"
  printf 'phase09_promotion_rollback_state=recorded core_revision=%s\n' \
    "$current_revision"
}

verify_node_data_network_image() {
  local expected observed
  expected=$(runtime_config_id "$data_network_release_image")
  observed=$(docker exec "${KIND_CLUSTER_NAME}-control-plane" \
    crictl inspecti "$data_network_release_image" | jq -er '.status.id')
  [[ $observed == "$expected" ]] || {
    printf 'error: kind data-network image identity mismatch\n' >&2
    printf 'observed_id=%s\nexpected_id=%s\n' "$observed" "$expected" >&2
    return 1
  }
  printf 'phase09_node_image=pass image=%s runtime_id=%s\n' \
    "$data_network_release_image" "$observed"
}

data_network_promotion_is_active() {
  local release_id deployments
  release_id=$(helm --kubeconfig "$core_kubeconfig" \
    --namespace "$core_namespace" get values "$core_release" --all \
    --output json | jq -er '.images.dataNetwork.expectedImageID')
  [[ $release_id == "$PHASE_09_DATA_NETWORK_IMAGE_ID" ]] || return 1
  deployments=$(kubectl --kubeconfig "$core_kubeconfig" \
    --namespace "$core_namespace" get deployment \
    cn5g-data-internet cn5g-data-enterprise --output json)
  jq -e --arg expected "$PHASE_09_DATA_NETWORK_IMAGE_ID" '
    (.items | length) == 2 and
    all(.items[];
      .spec.template.metadata.annotations["cn5g.io/expected-image-id"] == $expected and
      (.status.readyReplicas // 0) == 1 and
      (.status.updatedReplicas // 0) == 1)
  ' <<<"$deployments" >/dev/null
}

promote_images() {
  ensure_cluster_operator
  require_tools
  require_command docker helm jq kind kubectl stat tar
  require_images
  verify_accepted_alpine_images
  verify_image_evidence
  capture_promotion_state
  docker tag "$PHASE_09_DATA_NETWORK_IMAGE" "$data_network_release_image"
  [[ $(docker image inspect --format '{{.Id}}' "$data_network_release_image") == \
    "$DATA_NETWORK_LOCAL_IMAGE_ID" ]] || {
    printf 'error: promoted data-network tag identity mismatch\n' >&2
    return 1
  }
  kind load docker-image --name "$KIND_CLUSTER_NAME" "$data_network_release_image"
  verify_node_data_network_image
  if data_network_promotion_is_active; then
    printf 'phase09_core_image_promotion=already-active upgrade=skipped\n'
  else
    helm upgrade "$core_release" "$core_chart" --kubeconfig "$core_kubeconfig" \
      --namespace "$core_namespace" "${core_values[@]}" \
      --dry-run=server --hide-secret >/dev/null
    printf 'server_side_phase09_promotion_dry_run=pass\n'
    helm upgrade "$core_release" "$core_chart" --kubeconfig "$core_kubeconfig" \
      --namespace "$core_namespace" "${core_values[@]}" \
      --rollback-on-failure --wait=watcher --timeout 15m
    kubectl --kubeconfig "$core_kubeconfig" --namespace "$core_namespace" \
      rollout status deployment/cn5g-data-internet --timeout=300s
    kubectl --kubeconfig "$core_kubeconfig" --namespace "$core_namespace" \
      rollout status deployment/cn5g-data-enterprise --timeout=300s
  fi
  "$script_dir/phase05-lab.sh" validate
  "$script_dir/phase06-lab.sh" install
  printf 'phase09_image_promotion=pass image=%s\n' "$data_network_release_image"
  printf 'next_step=sudo ./scripts/phase09-lab.sh privileged-gate\n'
}

rollback_images() {
  ensure_cluster_operator
  require_command docker helm jq kind kubectl
  [[ -f $promotion_state && ! -L $promotion_state ]] || {
    printf 'error: Phase 9 promotion rollback state is absent or unsafe\n' >&2
    return 1
  }
  local revision previous_id restored_id
  revision=$(jq -er '.core_revision' "$promotion_state")
  previous_id=$(jq -er '.previous_data_network_image_id' "$promotion_state")
  restored_id=$(docker image inspect --format '{{.Id}}' "$data_network_rollback_image")
  [[ $restored_id == "$previous_id" ]] || {
    printf 'error: retained rollback image identity changed\n' >&2
    return 1
  }
  docker tag "$data_network_rollback_image" "$data_network_release_image"
  kind load docker-image --name "$KIND_CLUSTER_NAME" "$data_network_release_image"
  helm rollback "$core_release" "$revision" --kubeconfig "$core_kubeconfig" \
    --namespace "$core_namespace" --wait=watcher --timeout 15m
  "$script_dir/phase05-lab.sh" validate
  "$script_dir/phase06-lab.sh" validate
  printf 'phase09_image_promotion_rollback=pass target_revision=%s image_id=%s\n' \
    "$revision" "$previous_id"
}

scan_images() {
  ensure_docker_operator
  require_tools
  require_command chmod docker mkdir
  require_images
  mkdir -p "$scan_root/images"
  trap restore_report_ownership RETURN
  local image
  for image in "${image_names[@]}"; do
    trivy image --no-progress --scanners vuln,secret --severity HIGH,CRITICAL \
      --ignorefile "$project_root/.trivyignore.yaml" \
      --ignore-unfixed --exit-code 1 --format json \
      --output "$scan_root/images/$image.json" "cn5g/$image:phase09"
    chmod 0600 "$scan_root/images/$image.json"
    printf 'phase09_image_scan=pass image=cn5g/%s:phase09\n' "$image"
  done
  restore_report_ownership
  trap - RETURN
  printf 'phase09_image_scans=pass images=5 severity=high-critical\n'
}

sbom() {
  ensure_docker_operator
  require_tools
  require_command chmod docker mkdir python3
  require_images
  mkdir -p "$sbom_root"
  trap restore_report_ownership RETURN
  local image
  for image in "${image_names[@]}"; do
    syft "cn5g/$image:phase09" --output "spdx-json=$sbom_root/$image.spdx.json"
    chmod 0600 "$sbom_root/$image.spdx.json"
  done
  python3 - "$sbom_root" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
files = sorted(root.glob("*.spdx.json"))
assert len(files) == 5
for path in files:
    data = json.load(path.open(encoding="utf-8"))
    assert data["spdxVersion"].startswith("SPDX-")
    assert data["documentNamespace"].startswith("https://")
    assert data["packages"]
PY
  restore_report_ownership
  trap - RETURN
  printf 'phase09_sbom=pass format=spdx-json images=5\n'
}

test_controls() {
  ensure_normal_user
  require_tools
  require_command cp grep mkdir mktemp rm
  local temp cleanup
  mkdir -p "$report_root"
  temp=$(mktemp -d "$report_root/control-test.XXXXXX")
  printf -v cleanup 'rm -rf -- %q' "$temp"
  # Expand the shell-escaped, validated path now so RETURN never depends on locals.
  # shellcheck disable=SC2064
  trap "$cleanup" RETURN

  mkdir -p "$temp/.github/workflows" "$temp/containers/bad" "$temp/secret"
  cp "$project_root/.github/workflows/ci.yml" "$temp/.github/workflows/ci.yml"
  sed -i 's#actions/checkout@[0-9a-f]\{40\}#actions/checkout@main#' \
    "$temp/.github/workflows/ci.yml"
  if PHASE09_WORKFLOW_PATH="$temp/.github/workflows/ci.yml" \
      "$script_dir/check-phase09-policies.py" workflow >"$temp/workflow.out" 2>&1; then
    printf 'error: unpinned action negative control was accepted\n' >&2
    return 1
  fi
  grep -q 'not pinned to a full commit SHA' "$temp/workflow.out"

  printf '%s\n' 'FROM alpine:latest' >"$temp/containers/bad/Dockerfile"
  if PHASE09_DOCKERFILE_ROOT="$temp/containers" \
      "$script_dir/check-phase09-policies.py" dockerfiles >"$temp/docker.out" 2>&1; then
    printf 'error: floating image negative control was accepted\n' >&2
    return 1
  fi
  grep -q 'unpinned base image' "$temp/docker.out"

  printf '%s\n' \
    'apiVersion: v1' 'kind: Pod' 'metadata:' '  name: rejected-privileged-pod' \
    '  namespace: cn5g' 'spec:' '  automountServiceAccountToken: false' \
    '  containers:' '    - name: bad' \
    '      image: alpine:3.22.5@sha256:7c8cb692ae09657cbc4a3f3cbd0e8d5a2690ba38386aaaf252dbb060bf5eb2e6' \
    '      securityContext:' '        privileged: true' \
    >"$temp/privileged.yaml"
  if conftest test --policy "$project_root/policy" "$temp/privileged.yaml" \
      >"$temp/policy.out" 2>&1; then
    printf 'error: privileged Pod negative control was accepted\n' >&2
    return 1
  fi
  grep -q 'must not be privileged' "$temp/policy.out"

  local synthetic_prefix=ghp_ synthetic_body
  synthetic_body='aB3dE5fG7hJ9kL2mN4pQ6rS8tU1vW3xY5zA7'
  printf 'SYNTHETIC_TEST_TOKEN=%s%s\n' "$synthetic_prefix" \
    "${synthetic_body:0:36}" >"$temp/secret/synthetic.env"
  if gitleaks dir "$temp/secret" --no-banner --redact >"$temp/secret.out" 2>&1; then
    printf 'error: synthetic secret negative control was accepted\n' >&2
    return 1
  fi
  rm -rf -- "$temp"
  trap - RETURN
  printf 'phase09_negative_controls=pass workflow=unpinned image=floating manifest=privileged secret=synthetic\n'
}

safe_gate() {
  preflight
  bootstrap_tools
  quality
  manifests
  scan_repository
  test_controls
  printf 'phase09_safe_gate=pass privileged_tests=not-run\n'
}

image_gate() {
  require_tools
  build_images
  scan_images
  sbom
  printf 'phase09_image_gate=pass\n'
}

privileged_gate() {
  if (( EUID != 0 )) || [[ -z ${SUDO_UID:-} || -z ${SUDO_GID:-} ]]; then
    printf 'error: run privileged-gate through sudo from the normal account\n' >&2
    return 1
  fi
  require_command git jq mkdir
  "$script_dir/phase05-lab.sh" validate
  "$script_dir/phase06-lab.sh" validate
  verify_reviewed_evidence
  mkdir -p "$report_root"
  jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg commit "$(git -C "$project_root" rev-parse HEAD)" \
    '{schema_version:1,status:"pass",generated_at:$generated_at,git_commit:$commit,phase05:"pass",phase06:"pass",phase07_reviewed_conditions:9,phase08_reviewed_conditions:9,boundary:"local-privileged"}' \
    >"$report_root/local-privileged-gate.json"
  chown "$SUDO_UID:$SUDO_GID" "$report_root/local-privileged-gate.json"
  chmod 0600 "$report_root/local-privileged-gate.json"
  printf 'phase09_privileged_gate=pass scope=local-only report=%s\n' \
    "$report_root/local-privileged-gate.json"
}

status() {
  local sbom_count=0
  if [[ -d $sbom_root ]]; then
    sbom_count=$(find "$sbom_root" -maxdepth 1 -type f -name '*.spdx.json' | wc -l)
  fi
  printf 'branch=%s\n' "$(git -C "$project_root" branch --show-current)"
  printf 'phase09_tools=%s\n' "$([[ -x $bin_root/trivy ]] && printf present || printf absent)"
  printf 'phase09_repository_scan=%s\n' "$([[ -s $scan_root/repository-trivy.json ]] && printf present || printf absent)"
  printf 'phase09_sbom_count=%s\n' "$sbom_count"
  printf 'phase09_privileged_evidence=%s\n' "$([[ -s $report_root/local-privileged-gate.json ]] && printf present || printf absent)"
  verify_reviewed_evidence
}

case "$action" in
  preflight) preflight ;;
  bootstrap-tools) bootstrap_tools ;;
  quality) quality ;;
  manifests) manifests ;;
  scan-repository) scan_repository ;;
  build-images) build_images ;;
  scan-images) scan_images ;;
  sbom) sbom ;;
  test-controls) test_controls ;;
  safe-gate) safe_gate ;;
  image-gate) image_gate ;;
  all-safe) safe_gate; image_gate; printf 'phase09_all_safe=pass\n' ;;
  promote-images) promote_images ;;
  rollback-images) rollback_images ;;
  privileged-gate) privileged_gate ;;
  status) status ;;
esac
