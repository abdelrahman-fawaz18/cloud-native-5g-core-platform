#!/bin/sh
set -eu

component="${1:-}"

case "$component" in
    gnb)
        grep -R -q 'NG Setup procedure is successful' /opt/ueransim/logs
        ;;
    ue)
        grep -R -q 'Initial Registration is successful' /opt/ueransim/logs
        grep -R -q 'PDU Session establishment is successful' /opt/ueransim/logs
        ip -4 address show dev uesimtun0 | grep -q '10\.60\.0\.'
        ;;
    *)
        echo "ueransim-healthcheck: unsupported component '$component'" >&2
        exit 34
        ;;
esac

