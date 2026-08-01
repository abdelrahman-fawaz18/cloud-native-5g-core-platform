#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
project=cn5g-compose

cd "$repository_root"

compose() {
    docker compose --project-name "$project" --file "$repository_root/compose.yaml" "$@"
}

if ! docker info >/dev/null 2>&1; then
    echo "validate-compose: Docker daemon access is required; use sudo for this host" >&2
    exit 60
fi

subscriber_count=$(compose exec -T mongodb mongosh --quiet open5gs --eval \
    "db.subscribers.countDocuments({imsi:'999700000000001'})")
if [ "$subscriber_count" != "1" ]; then
    echo "validate-compose: expected one synthetic subscriber, found '$subscriber_count'" >&2
    exit 61
fi
echo "subscriber_record=pass"

compose exec -T gnb grep -R -q 'NG Setup procedure is successful' /opt/ueransim/logs
echo "ng_setup=pass"

compose exec -T ue grep -R -q 'Initial Registration is successful' /opt/ueransim/logs
echo "registration=pass"

compose exec -T ue grep -R -q 'PDU Session establishment is successful' /opt/ueransim/logs
ue_address=$(compose exec -T ue sh -c \
    "ip -o -4 address show dev uesimtun0 | awk '{print \$4}'")
case "$ue_address" in
    10.60.0.*\/24)
        ;;
    *)
        echo "validate-compose: unexpected UE tunnel address '$ue_address'" >&2
        exit 62
        ;;
esac
echo "pdu_session=pass"
echo "ue_tunnel_address=$ue_address"

http_result=$(compose exec -T ue curl --fail --silent --show-error \
    --interface uesimtun0 --max-time 10 http://10.62.0.10:8080/healthz)
if [ "$http_result" != "cn5g-data-network-ok" ]; then
    echo "validate-compose: controlled endpoint returned '$http_result'" >&2
    exit 63
fi
echo "http_user_plane=pass"

compose exec -T ue ping -I uesimtun0 -c 3 -W 2 10.62.0.10 >/dev/null
echo "icmp_user_plane=pass"

ue_ip=${ue_address%/*}
return_route=$(compose exec -T data-network ip route get "$ue_ip")
echo "$return_route" | grep -q 'via 10.62.0.2'
echo "n6_return_route=pass"

compose exec -T upf ip -4 address show dev ogstun | grep -q '10\.60\.0\.1/24'
echo "upf_tunnel=pass"

echo "compose_validation=pass"

