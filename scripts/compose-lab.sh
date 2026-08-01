#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
project=cn5g-compose

cd "$repository_root"

if ! docker info >/dev/null 2>&1; then
    echo "compose-lab: Docker daemon access is required; use sudo for this host" >&2
    exit 50
fi

compose() {
    docker compose --project-name "$project" --file "$repository_root/compose.yaml" "$@"
}

build_preflight() {
    required_units='mongod.service
open5gs-amfd.service
open5gs-ausfd.service
open5gs-nrfd.service
open5gs-nssfd.service
open5gs-pcfd.service
open5gs-scpd.service
open5gs-smfd.service
open5gs-udmd.service
open5gs-udrd.service
open5gs-upfd.service'

    inactive_units=$(
        echo "$required_units" | while IFS= read -r unit; do
            if ! systemctl is-active --quiet "$unit"; then
                echo "$unit"
            fi
        done
    )
    if [ -n "$inactive_units" ]; then
        echo "compose-lab: existing host lab service is not active:" >&2
        echo "$inactive_units" >&2
        return 55
    fi
    echo "host_lab_services=active"

    for process in nr-gnb nr-ue ns3 waf; do
        if pgrep -x "$process" >/dev/null 2>&1; then
            echo "compose-lab: host process '$process' is already running" >&2
            return 56
        fi
    done
    echo "host_ran_or_simulation_processes=none"

    available_kib=$(df -Pk /var/lib/docker | awk 'NR == 2 {print $4}')
    minimum_kib=$((12 * 1024 * 1024))
    if [ "$available_kib" -lt "$minimum_kib" ]; then
        echo "compose-lab: at least 12 GiB free is required for the first build" >&2
        return 57
    fi
    available_gib=$((available_kib / 1024 / 1024))
    echo "docker_filesystem_available_gib=$available_gib"

    expected_owner='https://github.com/abdelrahman-fawaz18/cloud-native-5g-core-platform'
    for image in \
        cn5g/open5gs:2.7.7 \
        cn5g/ueransim:3.2.8 \
        cn5g/data-network:0.1.0
    do
        if docker image inspect "$image" >/dev/null 2>&1; then
            owner_url=$(docker image inspect --format \
                '{{index .Config.Labels "org.opencontainers.image.url"}}' "$image")
            owner_source=$(docker image inspect --format \
                '{{index .Config.Labels "org.opencontainers.image.source"}}' "$image")
            if [ "$owner_url" != "$expected_owner" ] \
                && [ "$owner_source" != "$expected_owner" ]; then
                echo "compose-lab: refusing to replace image tag not owned by this project: $image" >&2
                return 58
            fi
        fi
    done
    echo "project_image_tag_conflicts=none"
    echo "host_software_reuse=disabled_for_isolation"
    echo "build_outputs=three_project_images_and_docker_build_cache"
    echo "build_preflight=pass"
}

usage() {
    cat <<'EOF'
usage: scripts/compose-lab.sh ACTION [--confirm]

Actions:
  preflight-build verify host lab health, idle simulators, disk, and image ownership
  config         validate and render the Compose model without creating resources
  build          build the three project-owned images
  up             check subnet safety, create the lab, and wait for health
  status         show project container state
  validate       prove subscriber, registration, PDU session, and user traffic
  logs           show the last 200 log lines per project service
  down           remove project containers and networks; preserve database volumes
  destroy        remove project containers, networks, and volumes (requires --confirm)
  remove-images  remove the three exact project image tags (requires --confirm)
EOF
}

action="${1:-}"
confirmation="${2:-}"

case "$action" in
    preflight-build)
        build_preflight
        ;;
    config)
        compose config --quiet
        compose config --images
        ;;
    build)
        build_preflight
        compose config --quiet
        compose build
        ;;
    up)
        "$repository_root/tools/check_compose_subnets.py"
        compose config --quiet
        compose up --detach --wait --wait-timeout 240
        ;;
    status)
        compose ps --all
        ;;
    validate)
        "$repository_root/scripts/validate-compose.sh"
        ;;
    logs)
        compose logs --no-color --tail 200
        ;;
    down)
        compose down --remove-orphans
        ;;
    destroy)
        if [ "$confirmation" != "--confirm" ]; then
            echo "compose-lab: destroy requires the literal second argument --confirm" >&2
            exit 51
        fi
        compose down --volumes --remove-orphans
        ;;
    remove-images)
        if [ "$confirmation" != "--confirm" ]; then
            echo "compose-lab: remove-images requires the literal second argument --confirm" >&2
            exit 52
        fi
        if [ -n "$(compose ps --quiet --all)" ]; then
            echo "compose-lab: remove project containers before removing images" >&2
            exit 53
        fi
        for image in \
            cn5g/open5gs:2.7.7 \
            cn5g/ueransim:3.2.8 \
            cn5g/data-network:0.1.0
        do
            if docker image inspect "$image" >/dev/null 2>&1; then
                docker image rm "$image"
            fi
        done
        ;;
    *)
        usage >&2
        exit 54
        ;;
esac
