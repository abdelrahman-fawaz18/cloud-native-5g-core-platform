#!/bin/sh
set -eu

component="${1:-}"

case "$component" in
    nrf|scp|amf|ausf|udm|udr|pcf|nssf|smf)
        ;;
    upf)
        if [ "$(id -u)" -ne 0 ]; then
            echo "open5gs-entrypoint: UPF requires UID 0 with NET_ADMIN to create ogstun" >&2
            exit 20
        fi

        if ! ip link show ogstun >/dev/null 2>&1; then
            ip tuntap add name ogstun mode tun
        fi
        ip address replace 10.60.0.1/24 dev ogstun
        ip link set ogstun up
        ;;
    *)
        echo "open5gs-entrypoint: unsupported component '$component'" >&2
        exit 21
        ;;
esac

config="/etc/open5gs/${component}.yaml"
binary="/opt/open5gs/bin/open5gs-${component}d"

if [ ! -r "$config" ]; then
    echo "open5gs-entrypoint: required configuration is unreadable: $config" >&2
    exit 22
fi

if [ ! -x "$binary" ]; then
    echo "open5gs-entrypoint: required binary is unavailable: $binary" >&2
    exit 23
fi

exec "$binary" -c "$config"

