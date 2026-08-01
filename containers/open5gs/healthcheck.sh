#!/bin/sh
set -eu

component="${1:-}"

case "$component" in
    nrf|scp|amf|ausf|udm|udr|pcf|nssf|smf)
        address="${2:?healthcheck requires the service address}"
        curl --silent --show-error --output /dev/null \
            --http2-prior-knowledge --connect-timeout 2 --max-time 3 \
            "http://${address}:7777/"
        ;;
    upf)
        ip link show ogstun >/dev/null
        ip -4 address show dev ogstun | grep -q '10\.60\.0\.1/24'
        ss -H -u -l -n | grep -q ':8805 '
        ss -H -u -l -n | grep -q ':2152 '
        ;;
    *)
        echo "open5gs-healthcheck: unsupported component '$component'" >&2
        exit 24
        ;;
esac
