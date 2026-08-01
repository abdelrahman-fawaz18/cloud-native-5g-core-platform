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

exec "$binary" -c "$config"

