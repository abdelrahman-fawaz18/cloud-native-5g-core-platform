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

    project_pid_namespaces=$(
        docker ps --quiet \
            --filter label=com.docker.compose.project="$project" \
        | while IFS= read -r container_id; do
            [ -n "$container_id" ] || continue
            container_pid=$(docker inspect --format '{{.State.Pid}}' "$container_id")
            if [ "$container_pid" -gt 0 ]; then
                readlink "/proc/$container_pid/ns/pid" 2>/dev/null || true
            fi
        done
    )

    for process in nr-gnb nr-ue ns3 waf; do
        process_pids=$(pgrep -x "$process" || true)
        for process_pid in $process_pids; do
            process_namespace=$(readlink "/proc/$process_pid/ns/pid" 2>/dev/null || true)
            [ -n "$process_namespace" ] || continue
            if printf '%s\n' "$project_pid_namespaces" \
                | grep -Fqx "$process_namespace"; then
                continue
            fi
            echo "compose-lab: host process '$process' is already running" >&2
            return 56
        done
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

verify_images() {
    expected_owner='https://github.com/abdelrahman-fawaz18/cloud-native-5g-core-platform'
    for image in \
        cn5g/open5gs:2.7.7 \
        cn5g/ueransim:3.2.8 \
        cn5g/data-network:0.1.0
    do
        if ! docker image inspect "$image" >/dev/null 2>&1; then
            echo "compose-lab: required image is unavailable: $image" >&2
            return 59
        fi

        owner_url=$(docker image inspect --format \
            '{{index .Config.Labels "org.opencontainers.image.url"}}' "$image")
        if [ "$owner_url" != "$expected_owner" ]; then
            echo "compose-lab: image ownership URL is invalid: $image" >&2
            return 60
        fi

        image_id=$(docker image inspect --format '{{.Id}}' "$image")
        image_size=$(docker image inspect --format '{{.Size}}' "$image")
        image_os=$(docker image inspect --format '{{.Os}}' "$image")
        image_arch=$(docker image inspect --format '{{.Architecture}}' "$image")
        image_user=$(docker image inspect --format '{{.Config.User}}' "$image")

        if [ "$image_os" != linux ] || [ "$image_arch" != amd64 ]; then
            echo "compose-lab: unexpected image platform for $image: $image_os/$image_arch" >&2
            return 61
        fi

        echo "image=$image"
        echo "image_id=$image_id"
        echo "image_size_bytes=$image_size"
        echo "image_platform=$image_os/$image_arch"
        echo "image_default_user=$image_user"
    done

    if [ -n "$(docker ps --all --quiet --filter label=com.docker.compose.project="$project")" ]; then
        echo "compose-lab: unexpected project container exists before deployment" >&2
        return 62
    fi
    if [ -n "$(docker network ls --quiet --filter label=com.docker.compose.project="$project")" ]; then
        echo "compose-lab: unexpected project network exists before deployment" >&2
        return 63
    fi
    if [ -n "$(docker volume ls --quiet --filter label=com.docker.compose.project="$project")" ]; then
        echo "compose-lab: unexpected project volume exists before deployment" >&2
        return 64
    fi

    echo "project_containers=none"
    echo "project_networks=none"
    echo "project_volumes=none"
    docker system df
    echo "image_verification=pass"
}

verify_down() {
    if [ -n "$(docker ps --all --quiet --filter label=com.docker.compose.project="$project")" ]; then
        echo "compose-lab: project container remains after down" >&2
        return 65
    fi
    if [ -n "$(docker network ls --quiet --filter label=com.docker.compose.project="$project")" ]; then
        echo "compose-lab: project network remains after down" >&2
        return 66
    fi

    expected_volumes='cn5g-compose_mongodb-config
cn5g-compose_mongodb-data'
    actual_volumes=$(docker volume ls \
        --filter label=com.docker.compose.project="$project" \
        --format '{{.Name}}' | sort)
    if [ "$actual_volumes" != "$expected_volumes" ]; then
        echo "compose-lab: expected only the two persistent MongoDB volumes after down" >&2
        printf 'found:\n%s\n' "$actual_volumes" >&2
        return 67
    fi

    echo "project_containers=none"
    echo "project_networks=none"
    printf 'preserved_volume=%s\n' $actual_volumes
    echo "scoped_down_verification=pass"
}

prepare_persistence_test() {
    compose exec -T mongodb mongosh --quiet open5gs --eval "
const marker = {
  _id: 'phase02-compose-recreation',
  value: 'synthetic-persistence-evidence'
};
db.cn5g_phase_evidence.replaceOne(
  { _id: marker._id }, marker, { upsert: true }
);
if (!db.cn5g_phase_evidence.findOne(marker)) {
  quit(68);
}
print('persistence_marker=prepared');
"
}

verify_persistence_test() {
    compose exec -T mongodb mongosh --quiet open5gs --eval "
const marker = {
  _id: 'phase02-compose-recreation',
  value: 'synthetic-persistence-evidence'
};
if (!db.cn5g_phase_evidence.findOne(marker)) {
  quit(69);
}
if (!db.cn5g_phase_evidence.drop()) {
  quit(70);
}
print('persistence_marker=survived_recreation');
print('persistence_evidence_collection=removed');
print('persistence_verification=pass');
"
}

usage() {
    cat <<'EOF'
usage: scripts/compose-lab.sh ACTION [--confirm]

Actions:
  preflight-build verify host lab health, idle simulators, disk, and image ownership
  verify-images   inspect built images and confirm no deployment resources exist
  verify-down     confirm containers/networks are gone and database volumes remain
  prepare-persistence create one synthetic marker before a recreation test
  verify-persistence prove the marker survived, then remove its evidence collection
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
    verify-images)
        verify_images
        ;;
    verify-down)
        verify_down
        ;;
    prepare-persistence)
        prepare_persistence_test
        ;;
    verify-persistence)
        verify_persistence_test
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
