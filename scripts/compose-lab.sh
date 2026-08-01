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

usage() {
    cat <<'EOF'
usage: scripts/compose-lab.sh ACTION [--confirm]

Actions:
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
    config)
        compose config --quiet
        compose config --images
        ;;
    build)
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

