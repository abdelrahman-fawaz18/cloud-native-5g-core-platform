#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/release-qualification.sh ACTION
       sudo ./scripts/release-qualification.sh privileged-gate|clean-runtime-preflight|rebind-clean-runtime|verify-clean-deployment|verify-clean-teardown

Actions:
  preflight       Check the release qualification candidate structure, claim links,
                  publication boundary, and existing supply-chain assurance policies.
  quality         Run the complete supply-chain assurance quality gate plus release qualification checks.
  clean-checkout  Clone the exact committed candidate into ignored evidence
                  storage and rerun quality and manifest gates there.
  clean-runtime-preflight
                  Record the exact existing project cluster/PVC targets before
                  the separately confirmed clean deployment exercise.
  rebind-clean-runtime
                  After a stopped lifecycle exposes and fixes repository code,
                  preserve the deleted-node identity while rebinding the
                  in-progress clean exercise to its descendant commit.
  verify-clean-deployment
                  Require a newly created kind node, run the local privileged
                  gate, and record the clean deployment for this Git commit.
  verify-clean-teardown
                  After separately confirmed scoped teardown, prove the cn5g
                  cluster, node, kubeconfig, and kind network are absent.
  verify-visuals  Verify accepted dashboard PNGs, metadata absence, source
                  UIDs, capture records, dimensions, and SHA-256 checksums.
  privileged-gate Run the accepted local supply-chain assurance privileged gate and bind its
                  platform and observability result to the current Git commit.
  hosted-gate     Run all non-privileged gates required by the final hosted
                  release workflow, including accepted public evidence.
  release-audit   Require matching clean-clone, privileged, claim, privacy,
                  visual, and public readiness evidence for the current commit.
  status          Report release qualification candidate and local-evidence state.

This helper does not delete a cluster, namespace, volume, image, route, or
file. It does not create a tag, GitHub release, or public container image.
EOF
}

action=${1:-}
case "$action" in
  preflight|quality|clean-checkout|clean-runtime-preflight|rebind-clean-runtime|verify-clean-deployment|verify-clean-teardown|verify-visuals|privileged-gate|hosted-gate|release-audit|status)
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

report_root="$project_root/artifacts/release"
clean_evidence="$report_root/clean-checkout.json"
privileged_evidence="$report_root/local-privileged-gate.json"
clean_runtime_state="$report_root/clean-runtime-state.json"
clean_runtime_evidence="$report_root/clean-runtime.json"
assurance_bin="$project_root/artifacts/tools/supply-chain/bin"
export PATH="$assurance_bin:$PATH"

# shellcheck source=../versions/kubernetes-runtime.env
source "$project_root/versions/kubernetes-runtime.env"
node_container="${KIND_CLUSTER_NAME}-control-plane"
kubeconfig="$project_root/artifacts/kubernetes/cn5g.kubeconfig"

ensure_normal_user() {
  if (( EUID == 0 )); then
    printf 'error: run this non-privileged action as the normal user\n' >&2
    return 1
  fi
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

require_assurance_tools() {
  local command_name
  for command_name in actionlint conftest gitleaks hadolint kubeconform lychee \
    rumdl shellcheck syft trivy yq; do
    command -v "$command_name" >/dev/null 2>&1 || {
      printf 'error: supply-chain assurance tool is absent: %s; run assurance bootstrap-tools\n' \
        "$command_name" >&2
      return 1
    }
  done
}

current_commit() {
  git -C "$project_root" rev-parse HEAD
}

require_clean_candidate() {
  [[ -z $(git -C "$project_root" status --porcelain --untracked-files=normal) ]] || {
    printf 'error: commit or remove candidate worktree changes before clean reproduction\n' >&2
    return 1
  }
}

preflight() {
  ensure_normal_user
  require_command git python3
  "$script_dir/check-supply-chain-policies.py" all
  "$script_dir/check-release.py" candidate
  git -C "$project_root" diff --check
  printf 'release_preflight=pass\n'
  printf 'next_step=./scripts/release-qualification.sh quality\n'
}

quality() {
  ensure_normal_user
  require_assurance_tools
  "$script_dir/supply-chain-assurance.sh" quality
  "$script_dir/check-release.py" candidate
  printf 'release_quality=pass\n'
}

clean_checkout() {
  ensure_normal_user
  require_assurance_tools
  require_command git jq mkdir mktemp
  require_clean_candidate
  mkdir -p "$report_root"
  local workspace checkout commit branch
  workspace=$(mktemp -d "$report_root/clean-checkout.XXXXXX")
  checkout="$workspace/cloud-native-5g-core-platform"
  commit=$(current_commit)
  branch=$(git -C "$project_root" branch --show-current)
  git clone --quiet --local --no-hardlinks --no-checkout "$project_root" "$checkout"
  git -C "$checkout" checkout --quiet --detach "$commit"
  PATH="$assurance_bin:$PATH" "$checkout/scripts/supply-chain-assurance.sh" quality
  PATH="$assurance_bin:$PATH" "$checkout/scripts/supply-chain-assurance.sh" manifests
  "$checkout/scripts/check-release.py" candidate
  jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg commit "$commit" --arg branch "$branch" --arg checkout "$checkout" \
    '{schema_version:1,status:"pass",generated_at:$generated_at,git_commit:$commit,source_branch:$branch,checkout:$checkout,quality:"pass",manifests:"pass",boundary:"clean-local-clone"}' \
    >"$clean_evidence"
  chmod 0600 "$clean_evidence"
  printf 'release_clean_checkout=pass commit=%s evidence=%s\n' \
    "$commit" "$clean_evidence"
}

require_sudo_operator() {
  if (( EUID != 0 )) || [[ -z ${SUDO_UID:-} || -z ${SUDO_GID:-} ]]; then
    printf 'error: run this action through sudo from the normal account\n' >&2
    return 1
  fi
}

clean_runtime_preflight() {
  require_sudo_operator
  require_command docker git helm jq kind kubectl mkdir stat
  [[ -r $kubeconfig && ! -L $kubeconfig ]] || {
    printf 'error: project kubeconfig is absent or unsafe\n' >&2
    return 1
  }
  kind get clusters | grep -Fxq "$KIND_CLUSTER_NAME" || {
    printf 'error: expected project kind cluster is absent: %s\n' \
      "$KIND_CLUSTER_NAME" >&2
    return 1
  }
  local source_node_id core_revision observability_revision pvc_count commit
  source_node_id=$(docker inspect --format '{{.Id}}' "$node_container")
  core_revision=$(helm --kubeconfig "$kubeconfig" --namespace cn5g \
    status cn5g --output json | jq -r '.version')
  observability_revision=$(helm --kubeconfig "$kubeconfig" \
    --namespace cn5g-observability status cn5g-observability --output json | \
    jq -r '.version')
  pvc_count=$(kubectl --kubeconfig "$kubeconfig" get pvc --all-namespaces \
    --output json | jq '[.items[]] | length')
  commit=$(current_commit)
  mkdir -p "$report_root"
  jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg commit "$commit" --arg cluster "$KIND_CLUSTER_NAME" \
    --arg node_container "$node_container" --arg source_node_id "$source_node_id" \
    --argjson core_revision "$core_revision" \
    --argjson observability_revision "$observability_revision" \
    --argjson pvc_count "$pvc_count" \
    '{schema_version:1,status:"targets-reviewed",generated_at:$generated_at,git_commit:$commit,cluster:$cluster,node_container:$node_container,source_node_id:$source_node_id,core_revision:$core_revision,observability_revision:$observability_revision,pvc_count:$pvc_count,data_loss_boundary:"deleting the kind node removes project-owned local-path PVC data"}' \
    >"$clean_runtime_state"
  chown "$SUDO_UID:$SUDO_GID" "$clean_runtime_state"
  chmod 0600 "$clean_runtime_state"
  printf 'release_clean_runtime_targets=reviewed cluster=%s node=%s pvcs=%s\n' \
    "$KIND_CLUSTER_NAME" "$source_node_id" "$pvc_count"
  printf 'warning=confirmed_kind_deletion_will_remove_project_owned_local_path_data\n'
}

rebind_clean_runtime() {
  require_sudo_operator
  require_command docker git jq
  require_clean_candidate
  [[ -f $clean_runtime_state && ! -L $clean_runtime_state ]] || {
    printf 'error: clean-runtime target review evidence is absent\n' >&2
    return 1
  }
  local previous_commit commit source_node_id recreated_node_id
  previous_commit=$(jq -r '.git_commit // ""' "$clean_runtime_state")
  commit=$(current_commit)
  source_node_id=$(jq -r '.source_node_id // ""' "$clean_runtime_state")
  [[ -n $previous_commit && -n $source_node_id ]] || {
    printf 'error: clean-runtime target review identity is incomplete\n' >&2
    return 1
  }
  git -C "$project_root" merge-base --is-ancestor "$previous_commit" "$commit" || {
    printf 'error: clean-runtime rebind requires a descendant commit\n' >&2
    return 1
  }
  ! docker container inspect "$source_node_id" >/dev/null 2>&1 || {
    printf 'error: reviewed source kind node still exists\n' >&2
    return 1
  }
  recreated_node_id=$(docker inspect --format '{{.Id}}' "$node_container")
  [[ $recreated_node_id != "$source_node_id" ]] || {
    printf 'error: replacement kind node identity did not change\n' >&2
    return 1
  }
  jq --arg previous_commit "$previous_commit" --arg commit "$commit" \
    --arg rebound_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.target_review_commit=(.target_review_commit // $previous_commit) | .git_commit=$commit | .rebound_at=$rebound_at | .rebind_reason="repository correction after fail-closed clean deployment stop"' \
    "$clean_runtime_state" >"${clean_runtime_state}.tmp"
  mv -- "${clean_runtime_state}.tmp" "$clean_runtime_state"
  chown "$SUDO_UID:$SUDO_GID" "$clean_runtime_state"
  chmod 0600 "$clean_runtime_state"
  printf 'release_clean_runtime_rebind=pass from=%s to=%s source_node=preserved\n' \
    "$previous_commit" "$commit"
}

verify_clean_deployment() {
  require_sudo_operator
  require_command docker git helm jq kind kubectl
  [[ -f $clean_runtime_state && ! -L $clean_runtime_state ]] || {
    printf 'error: clean-runtime target review evidence is absent\n' >&2
    return 1
  }
  local commit source_node_id recreated_node_id core_revision
  local observability_revision mongodb_pvc_uid prometheus_pvc_uid loki_pvc_uid
  commit=$(current_commit)
  jq -e --arg commit "$commit" \
    '.status == "targets-reviewed" and .git_commit == $commit' \
    "$clean_runtime_state" >/dev/null || {
      printf 'error: clean-runtime target review is stale or invalid\n' >&2
      return 1
    }
  source_node_id=$(jq -r '.source_node_id' "$clean_runtime_state")
  recreated_node_id=$(docker inspect --format '{{.Id}}' "$node_container")
  [[ $recreated_node_id != "$source_node_id" ]] || {
    printf 'error: kind node was not recreated; container identity is unchanged\n' >&2
    return 1
  }
  privileged_gate
  core_revision=$(helm --kubeconfig "$kubeconfig" --namespace cn5g \
    status cn5g --output json | jq -r '.version')
  observability_revision=$(helm --kubeconfig "$kubeconfig" \
    --namespace cn5g-observability status cn5g-observability --output json | \
    jq -r '.version')
  mongodb_pvc_uid=$(kubectl --kubeconfig "$kubeconfig" --namespace cn5g \
    get pvc mongodb-data-cn5g-mongodb-0 --output jsonpath='{.metadata.uid}')
  prometheus_pvc_uid=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace cn5g-observability get pvc \
    data-cn5g-observability-prometheus-0 \
    --output jsonpath='{.metadata.uid}')
  loki_pvc_uid=$(kubectl --kubeconfig "$kubeconfig" \
    --namespace cn5g-observability get pvc \
    data-cn5g-observability-loki-0 --output jsonpath='{.metadata.uid}')
  jq --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg recreated_node_id "$recreated_node_id" \
    --arg mongodb_pvc_uid "$mongodb_pvc_uid" \
    --arg prometheus_pvc_uid "$prometheus_pvc_uid" \
    --arg loki_pvc_uid "$loki_pvc_uid" \
    --argjson core_revision "$core_revision" \
    --argjson observability_revision "$observability_revision" \
    '.status="deployment-pass" | .deployment_verified_at=$generated_at | .recreated_node_id=$recreated_node_id | .clean_core_revision=$core_revision | .clean_observability_revision=$observability_revision | .mongodb_pvc_uid=$mongodb_pvc_uid | .prometheus_pvc_uid=$prometheus_pvc_uid | .loki_pvc_uid=$loki_pvc_uid | .release_privileged_gate="pass"' \
    "$clean_runtime_state" >"${clean_runtime_state}.tmp"
  mv -- "${clean_runtime_state}.tmp" "$clean_runtime_state"
  chown "$SUDO_UID:$SUDO_GID" "$clean_runtime_state"
  chmod 0600 "$clean_runtime_state"
  printf 'release_clean_deployment=pass commit=%s old_node=%s new_node=%s\n' \
    "$commit" "$source_node_id" "$recreated_node_id"
}

verify_clean_teardown() {
  require_sudo_operator
  require_command docker git jq kind mkdir systemctl
  [[ -f $clean_runtime_state && ! -L $clean_runtime_state ]] || {
    printf 'error: clean deployment evidence is absent\n' >&2
    return 1
  }
  local commit
  commit=$(current_commit)
  jq -e --arg commit "$commit" \
    '.status == "deployment-pass" and .git_commit == $commit and .release_privileged_gate == "pass"' \
    "$clean_runtime_state" >/dev/null || {
      printf 'error: clean deployment evidence is stale or invalid\n' >&2
      return 1
    }
  ! kind get clusters 2>/dev/null | grep -Fxq "$KIND_CLUSTER_NAME" || {
    printf 'error: project kind cluster still exists: %s\n' "$KIND_CLUSTER_NAME" >&2
    return 1
  }
  ! docker container inspect "$node_container" >/dev/null 2>&1 || {
    printf 'error: project kind node container still exists: %s\n' \
      "$node_container" >&2
    return 1
  }
  [[ ! -e $kubeconfig && ! -L $kubeconfig ]] || {
    printf 'error: project kubeconfig still exists\n' >&2
    return 1
  }
  ! docker network inspect "$KIND_DOCKER_NETWORK_NAME" >/dev/null 2>&1 || {
    printf 'error: kind Docker network still exists\n' >&2
    return 1
  }
  [[ $(systemctl is-active open5gs-amfd.service) == active && \
     $(systemctl is-active mongod.service) == active ]] || {
    printf 'error: protected host lab services are not active after teardown\n' >&2
    return 1
  }
  mkdir -p "$report_root"
  jq --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.status="pass" | .completed_at=$completed_at | .clean_deployment="pass" | .scoped_teardown="pass" | .protected_host_services="active"' \
    "$clean_runtime_state" >"$clean_runtime_evidence"
  chown "$SUDO_UID:$SUDO_GID" "$clean_runtime_evidence"
  chmod 0600 "$clean_runtime_evidence"
  printf 'release_clean_runtime=pass deployment=pass teardown=pass commit=%s\n' \
    "$commit"
}

verify_visuals() {
  ensure_normal_user
  "$script_dir/check-release.py" visuals
}

privileged_gate() {
  if (( EUID != 0 )) || [[ -z ${SUDO_UID:-} || -z ${SUDO_GID:-} ]]; then
    printf 'error: run privileged-gate through sudo from the normal account\n' >&2
    return 1
  fi
  require_command git jq mkdir
  "$script_dir/supply-chain-assurance.sh" privileged-gate
  local commit assurance_report
  commit=$(current_commit)
  assurance_report="$project_root/artifacts/supply-chain/local-privileged-gate.json"
  jq -e --arg commit "$commit" \
    '.status == "pass" and .git_commit == $commit and .platform == "pass" and .observability == "pass"' \
    "$assurance_report" >/dev/null || {
      printf 'error: supply-chain assurance privileged evidence does not match this commit\n' >&2
      return 1
    }
  mkdir -p "$report_root"
  jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg commit "$commit" \
    '{schema_version:1,status:"pass",generated_at:$generated_at,git_commit:$commit,platform:"pass",observability:"pass",assurance_privileged_gate:"pass",boundary:"local-privileged"}' \
    >"$privileged_evidence"
  chown "$SUDO_UID:$SUDO_GID" "$privileged_evidence"
  chmod 0600 "$privileged_evidence"
  printf 'release_privileged_gate=pass commit=%s evidence=%s\n' \
    "$commit" "$privileged_evidence"
}

hosted_gate() {
  ensure_normal_user
  "$script_dir/supply-chain-assurance.sh" safe-gate
  "$script_dir/check-release.py" public-release
  printf 'release_hosted_gate=pass privileged_validation=not-run\n'
}

verify_local_evidence() {
  require_command jq
  local commit
  commit=$(current_commit)
  for path in "$clean_evidence" "$privileged_evidence" "$clean_runtime_evidence"; do
    [[ -f $path && ! -L $path ]] || {
      printf 'error: local release qualification evidence is absent or unsafe: %s\n' "$path" >&2
      return 1
    }
    [[ $(stat -c '%a' "$path") == 600 ]] || {
      printf 'error: local release qualification evidence must use mode 600: %s\n' "$path" >&2
      return 1
    }
    jq -e --arg commit "$commit" \
      '.schema_version == 1 and .status == "pass" and .git_commit == $commit' \
      "$path" >/dev/null || {
        printf 'error: local release qualification evidence is stale or invalid: %s\n' "$path" >&2
        return 1
      }
  done
  printf 'release_local_evidence=pass commit=%s clean_clone=pass privileged=pass clean_runtime=pass\n' \
    "$commit"
}

release_audit() {
  ensure_normal_user
  require_clean_candidate
  "$script_dir/check-release.py" public-release
  verify_local_evidence
  printf 'release_audit=pass decision=ready\n'
}

status() {
  local contract_status visual_status clean_status privileged_status runtime_status
  contract_status=$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["status"])' \
    "$project_root/release/release-evidence.json")
  visual_status=absent
  [[ -s $project_root/release/dashboard-evidence.json ]] && visual_status=present
  clean_status=absent
  [[ -s $clean_evidence ]] && clean_status=present
  privileged_status=absent
  [[ -s $privileged_evidence ]] && privileged_status=present
  runtime_status=absent
  [[ -s $clean_runtime_evidence ]] && runtime_status=present
  printf 'branch=%s\n' "$(git -C "$project_root" branch --show-current)"
  printf 'commit=%s\n' "$(current_commit)"
  printf 'release_contract=%s\n' "$contract_status"
  printf 'release_visual_evidence=%s\n' "$visual_status"
  printf 'release_clean_checkout_evidence=%s\n' "$clean_status"
  printf 'release_privileged_evidence=%s\n' "$privileged_status"
  printf 'release_clean_runtime_evidence=%s\n' "$runtime_status"
}

case "$action" in
  preflight) preflight ;;
  quality) quality ;;
  clean-checkout) clean_checkout ;;
  clean-runtime-preflight) clean_runtime_preflight ;;
  rebind-clean-runtime) rebind_clean_runtime ;;
  verify-clean-deployment) verify_clean_deployment ;;
  verify-clean-teardown) verify_clean_teardown ;;
  verify-visuals) verify_visuals ;;
  privileged-gate) privileged_gate ;;
  hosted-gate) hosted_gate ;;
  release-audit) release_audit ;;
  status) status ;;
esac
