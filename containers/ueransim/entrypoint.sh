#!/bin/sh
set -eu

component="${1:-}"

case "$component" in
    gnb)
        binary=/opt/ueransim/bin/nr-gnb
        config=/etc/ueransim/gnb.yaml
        ;;
    ue)
        if [ "$(id -u)" -ne 0 ]; then
            echo "ueransim-entrypoint: UE requires UID 0 with NET_ADMIN to create its TUN interface" >&2
            exit 30
        fi
        if [ ! -c /dev/net/tun ]; then
            echo "ueransim-entrypoint: /dev/net/tun is unavailable" >&2
            exit 31
        fi
        if [ ! -d /etc/iproute2 ] || [ ! -w /etc/iproute2 ]; then
            echo "ueransim-entrypoint: writable /etc/iproute2 tmpfs is unavailable" >&2
            exit 35
        fi
        cp /opt/ueransim/rt_tables /etc/iproute2/rt_tables
        chmod 0644 /etc/iproute2/rt_tables
        binary=/opt/ueransim/bin/nr-ue
        config=/etc/ueransim/ue.yaml
        ;;
    *)
        echo "ueransim-entrypoint: unsupported component '$component'" >&2
        exit 32
        ;;
esac

if [ ! -r "$config" ]; then
    echo "ueransim-entrypoint: required configuration is unreadable: $config" >&2
    exit 33
fi

log_file="/opt/ueransim/logs/$component.log"

# Preserve protocol-success evidence for the health check while continuing to
# emit the same output through Docker's normal container log stream. Bash
# process substitution lets the simulator remain the signal-receiving process.
exec /bin/bash -c \
    'exec "$1" -c "$2" > >(/usr/bin/tee "$3") 2>&1' \
    ueransim "$binary" "$config" "$log_file"
