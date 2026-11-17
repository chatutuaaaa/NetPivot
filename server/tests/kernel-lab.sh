#!/usr/bin/env bash
# Run only in a disposable privileged Linux container. This creates tunnel and
# network interfaces in the container and starts a dedicated in-memory API.
set -euo pipefail
project=${1:-/project}
if [ ! -f /run/.containerenv ] && [ ! -f /.dockerenv ]; then
    echo 'Run the lab in a disposable container.' >&2
    exit 1
fi
trap 'jobs -pr | xargs -r kill' EXIT
umask 077
wg genkey > /tmp/netpivot-lab.key
export NETPIVOT_GATEWAY_KEY=$(wg pubkey < /tmp/netpivot-lab.key)
export NETPIVOT_GATEWAY_KEY_FILE=/tmp/netpivot-lab.key
export NETPIVOT_GATEWAY_ENDPOINT=172.30.77.1:51820
export NETPIVOT_AGENT_API=http://127.0.0.1:8080
export NETPIVOT_ORIGIN=https://netpivot.example.com
export NETPIVOT_AGENT_TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
export NETPIVOT_INVITE_SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
export NETPIVOT_DEV_MEMORY=1
nft -f "$project/deploy/netpivot.nft"
sysctl -w net.ipv4.ip_forward=1
ip addr add 172.30.77.1/32 dev lo
ip link add netpivot0 type wireguard
ip addr add 10.203.0.1/16 dev netpivot0
ip link set netpivot0 mtu 1280 up
wg set netpivot0 private-key /tmp/netpivot-lab.key listen-port 51820
"$project/server/.build/api" &
"$project/server/.build/gateway-agent" &
python3 "$project/server/tests/kernel_lab.py"
