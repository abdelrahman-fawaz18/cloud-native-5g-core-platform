#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/phase10-lab.sh ACTION
       sudo ./scripts/phase10-lab.sh privileged-gate

Actions:
  preflight       Check the Phase 10 candidate structure, claim links,
                  publication boundary, and existing Phase 9 policies.
  quality         Run the complete Phase 9 quality gate plus Phase 10 checks.
  clean-checkout  Clone the exact committed candidate into ignored evidence
                  storage and rerun quality and manifest gates there.
  verify-visuals  Verify accepted dashboard PNGs, metadata absence, source
                  UIDs, capture records, dimensions, and SHA-256 checksums.
  privileged-gate Run the accepted local Phase 9 privileged gate and bind its
                  Phase 5/6 result to the current Git commit.
  hosted-gate     Run all non-privileged gates required by the final hosted
                  release workflow, including accepted public evidence.
  release-audit   Require matching clean-clone, privileged, claim, privacy,
                  visual, and public readiness evidence for the current commit.
  status          Report Phase 10 candidate and local-evidence state.

This helper does not delete a cluster, namespace, volume, image, route, or
file. It does not create a tag, GitHub release, or public container image.
EOF
}

action=${1:-}
case "$action" in
  preflight|quality|clean-checkout|verify-visuals|privileged-gate|hosted-gate|release-audit|status)
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

report_root="$project_root/artifacts/phase-10"
clean_evidence="$report_root/clean-checkout.json"
privileged_evidence="$report_root/local-privileged-gate.json"
phase09_bin="$project_root/artifacts/tools/phase-09/bin"
export PATH="$phase09_bin:$PATH"

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

require_phase09_tools() {
  local command_name
  for command_name in actionlint conftest gitleaks hadolint kubeconform lychee \
    rumdl shellcheck syft trivy yq; do
    command -v "$command_name" >/dev/null 2>&1 || {
      printf 'error: Phase 9 tool is absent: %s; run phase09 bootstrap-tools\n' \
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
  "$script_dir/check-phase09-policies.py" all
  "$script_dir/check-phase10-release.py" candidate
  git -C "$project_root" diff --check
  printf 'phase10_preflight=pass\n'
  printf 'next_step=./scripts/phase10-lab.sh quality\n'
}

quality() {
  ensure_normal_user
  require_phase09_tools
  "$script_dir/phase09-lab.sh" quality
  "$script_dir/check-phase10-release.py" candidate
  printf 'phase10_quality=pass\n'
}

clean_checkout() {
  ensure_normal_user
  require_phase09_tools
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
  PATH="$phase09_bin:$PATH" "$checkout/scripts/phase09-lab.sh" quality
  PATH="$phase09_bin:$PATH" "$checkout/scripts/phase09-lab.sh" manifests
  "$checkout/scripts/check-phase10-release.py" candidate
  jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg commit "$commit" --arg branch "$branch" --arg checkout "$checkout" \
    '{schema_version:1,status:"pass",generated_at:$generated_at,git_commit:$commit,source_branch:$branch,checkout:$checkout,quality:"pass",manifests:"pass",boundary:"clean-local-clone"}' \
    >"$clean_evidence"
  chmod 0600 "$clean_evidence"
  printf 'phase10_clean_checkout=pass commit=%s evidence=%s\n' \
    "$commit" "$clean_evidence"
}

verify_visuals() {
  ensure_normal_user
  "$script_dir/check-phase10-release.py" visuals
}

privileged_gate() {
  if (( EUID != 0 )) || [[ -z ${SUDO_UID:-} || -z ${SUDO_GID:-} ]]; then
    printf 'error: run privileged-gate through sudo from the normal account\n' >&2
    return 1
  fi
  require_command git jq mkdir
  "$script_dir/phase09-lab.sh" privileged-gate
  local commit phase09_report
  commit=$(current_commit)
  phase09_report="$project_root/artifacts/phase-09/local-privileged-gate.json"
  jq -e --arg commit "$commit" \
    '.status == "pass" and .git_commit == $commit and .phase05 == "pass" and .phase06 == "pass"' \
    "$phase09_report" >/dev/null || {
      printf 'error: Phase 9 privileged evidence does not match this commit\n' >&2
      return 1
    }
  mkdir -p "$report_root"
  jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg commit "$commit" \
    '{schema_version:1,status:"pass",generated_at:$generated_at,git_commit:$commit,phase05:"pass",phase06:"pass",phase09_privileged_gate:"pass",boundary:"local-privileged"}' \
    >"$privileged_evidence"
  chown "$SUDO_UID:$SUDO_GID" "$privileged_evidence"
  chmod 0600 "$privileged_evidence"
  printf 'phase10_privileged_gate=pass commit=%s evidence=%s\n' \
    "$commit" "$privileged_evidence"
}

hosted_gate() {
  ensure_normal_user
  "$script_dir/phase09-lab.sh" safe-gate
  "$script_dir/check-phase10-release.py" public-release
  printf 'phase10_hosted_gate=pass privileged_validation=not-run\n'
}

verify_local_evidence() {
  require_command jq
  local commit
  commit=$(current_commit)
  for path in "$clean_evidence" "$privileged_evidence"; do
    [[ -f $path && ! -L $path ]] || {
      printf 'error: local Phase 10 evidence is absent or unsafe: %s\n' "$path" >&2
      return 1
    }
    [[ $(stat -c '%a' "$path") == 600 ]] || {
      printf 'error: local Phase 10 evidence must use mode 600: %s\n' "$path" >&2
      return 1
    }
    jq -e --arg commit "$commit" \
      '.schema_version == 1 and .status == "pass" and .git_commit == $commit' \
      "$path" >/dev/null || {
        printf 'error: local Phase 10 evidence is stale or invalid: %s\n' "$path" >&2
        return 1
      }
  done
  printf 'phase10_local_evidence=pass commit=%s clean_clone=pass privileged=pass\n' \
    "$commit"
}

release_audit() {
  ensure_normal_user
  require_clean_candidate
  "$script_dir/check-phase10-release.py" public-release
  verify_local_evidence
  printf 'phase10_release_audit=pass decision=ready\n'
}

status() {
  local contract_status visual_status clean_status privileged_status
  contract_status=$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["status"])' \
    "$project_root/release/phase-10-evidence.json")
  visual_status=absent
  [[ -s $project_root/release/dashboard-evidence.json ]] && visual_status=present
  clean_status=absent
  [[ -s $clean_evidence ]] && clean_status=present
  privileged_status=absent
  [[ -s $privileged_evidence ]] && privileged_status=present
  printf 'branch=%s\n' "$(git -C "$project_root" branch --show-current)"
  printf 'commit=%s\n' "$(current_commit)"
  printf 'phase10_contract=%s\n' "$contract_status"
  printf 'phase10_visual_evidence=%s\n' "$visual_status"
  printf 'phase10_clean_checkout_evidence=%s\n' "$clean_status"
  printf 'phase10_privileged_evidence=%s\n' "$privileged_status"
}

case "$action" in
  preflight) preflight ;;
  quality) quality ;;
  clean-checkout) clean_checkout ;;
  verify-visuals) verify_visuals ;;
  privileged-gate) privileged_gate ;;
  hosted-gate) hosted_gate ;;
  release-audit) release_audit ;;
  status) status ;;
esac
