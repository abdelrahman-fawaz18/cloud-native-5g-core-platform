#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/generate-subscriber-secret.sh --check|--generate

  --check     Validate existing ignored subscriber material without printing
              subscriber identifiers or authentication values.
  --generate  Create new random synthetic authentication values and render
              ignored files with directory mode 0700 and file mode 0600.

Generation refuses to replace an existing output directory. This helper does
not contact Kubernetes, create a Secret, or pass authentication values through
command-line arguments.
EOF
}

action=${1:-}
if [[ $action == "-h" || $action == "--help" ]]; then
  usage
  exit 0
fi
if [[ $action != "--check" && $action != "--generate" ]]; then
  printf 'error: choose exactly one of --check or --generate\n' >&2
  usage >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_root=$(cd -- "$script_dir/.." && pwd -P)
template_dir="$project_root/configs/kubernetes/single-ue/secret-templates"
output_dir="$project_root/artifacts/secrets/single-ue"
ue_template="$template_dir/ue.yaml.tmpl"
subscriber_template="$template_dir/subscriber-init.js.tmpl"
ue_output="$output_dir/ue.yaml"
subscriber_output="$output_dir/subscriber-init.js"
imsi_output="$output_dir/imsi"
synthetic_imsi=999700000000001

for template in "$ue_template" "$subscriber_template"; do
  if [[ ! -f $template || -L $template || ! -r $template ]]; then
    printf 'error: template is missing, unreadable, or a symbolic link: %s\n' \
      "$template" >&2
    exit 3
  fi
done

validate_material() {
  local path mode ue_key ue_opc js_key js_opc stored_imsi

  if [[ ! -d $output_dir || -L $output_dir ]]; then
    printf 'error: subscriber material directory is missing or unsafe\n' >&2
    return 1
  fi
  mode=$(stat -c '%a' "$output_dir")
  if [[ $mode != "700" ]]; then
    printf 'error: subscriber material directory mode must be 700\n' >&2
    return 1
  fi

  for path in "$ue_output" "$subscriber_output" "$imsi_output"; do
    if [[ ! -f $path || -L $path ]]; then
      printf 'error: subscriber material file is missing or unsafe\n' >&2
      return 1
    fi
    mode=$(stat -c '%a' "$path")
    if [[ $mode != "600" ]]; then
      printf 'error: subscriber material file mode must be 600\n' >&2
      return 1
    fi
  done

  if grep -Eq '__SUBSCRIBER_(KEY|OPC)__' "$ue_output" "$subscriber_output"; then
    printf 'error: unresolved authentication placeholder detected\n' >&2
    return 1
  fi
  if ! grep -Fq '__GNB_IP__' "$ue_output"; then
    printf 'error: UE runtime-address placeholder is absent\n' >&2
    return 1
  fi

  ue_key=$(sed -n "s/^key: '\([0-9A-F]\{32\}\)'$/\1/p" "$ue_output")
  ue_opc=$(sed -n "s/^op: '\([0-9A-F]\{32\}\)'$/\1/p" "$ue_output")
  js_key=$(sed -n "s/^    k: '\([0-9A-F]\{32\}\)',$/\1/p" "$subscriber_output")
  js_opc=$(sed -n "s/^    opc: '\([0-9A-F]\{32\}\)',$/\1/p" "$subscriber_output")
  stored_imsi=$(tr -d '\n' < "$imsi_output")
  if [[ -z $ue_key || -z $ue_opc || $ue_key != "$js_key" || \
        $ue_opc != "$js_opc" || $stored_imsi != "$synthetic_imsi" ]]; then
    printf 'error: subscriber material consistency validation failed\n' >&2
    return 1
  fi

  printf 'subscriber_material_state=present-valid-and-permission-restricted\n'
  printf 'subscriber_material_validation=pass\n'
}

if [[ $action == "--check" ]]; then
  if [[ ! -e $output_dir ]]; then
    printf 'subscriber_material_state=absent\n'
    printf 'check_result=pass\n'
    exit 0
  fi
  validate_material
  printf 'check_result=pass\n'
  exit 0
fi

if [[ -e $output_dir ]]; then
  printf 'error: refusing to replace existing subscriber material directory\n' \
    >&2
  printf 'existing_directory=%s\n' "$output_dir" >&2
  exit 4
fi
if ! command -v openssl >/dev/null 2>&1; then
  printf 'error: required command is absent: openssl\n' >&2
  exit 5
fi

umask 077
install -d -m 0700 "$output_dir"
subscriber_key=$(openssl rand -hex 16)
subscriber_opc=$(openssl rand -hex 16)
subscriber_key=${subscriber_key^^}
subscriber_opc=${subscriber_opc^^}

render_template() {
  local template=$1 output=$2 line rendered
  install -m 0600 /dev/null "$output"
  while IFS= read -r line || [[ -n $line ]]; do
    rendered=${line//__SUBSCRIBER_KEY__/$subscriber_key}
    rendered=${rendered//__SUBSCRIBER_OPC__/$subscriber_opc}
    printf '%s\n' "$rendered"
  done < "$template" > "$output"
}

render_template "$ue_template" "$ue_output"
render_template "$subscriber_template" "$subscriber_output"
printf '%s\n' "$synthetic_imsi" > "$imsi_output"
chmod 0600 "$ue_output" "$subscriber_output" "$imsi_output"
unset subscriber_key subscriber_opc

validate_material
printf 'subscriber_material_generation=pass\n'
printf 'next_step=create the namespace-scoped Kubernetes Secret from these files\n'
