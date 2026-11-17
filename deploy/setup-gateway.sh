#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")"

if [ "$(id -u)" != "0" ] || [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo "Usage: sudo bash deploy/setup-gateway.sh /absolute/path/to/netpivot-agent" >&2
    exit 1
fi
if [ -e /etc/wireguard/netpivot0.conf ] || nft list table inet netpivot >/dev/null 2>&1; then
    echo "NetPivot gateway already exists. Use the upgrade instructions." >&2
    exit 1
fi
nft -c -f netpivot.nft
install -d -m 700 /etc/netpivot /etc/wireguard
install -d /etc/systemd/system/wg-quick@netpivot0.service.d
if [ ! -s /etc/netpivot/gateway.key ]; then
    wg genkey > /etc/netpivot/gateway.key
fi
{
    printf '[Interface]\nAddress = 10.203.0.1/16\nListenPort = 51820\nMTU = 1280\nPrivateKey = '
    cat /etc/netpivot/gateway.key
} > /etc/wireguard/netpivot0.conf
if [ ! -s /etc/netpivot/agent.env ]; then
    {
        printf 'NETPIVOT_AGENT_API=http://127.0.0.1:8080\nNETPIVOT_AGENT_TOKEN='
        openssl rand -hex 32
    } > /etc/netpivot/agent.env
fi
install -m 755 "$1" /usr/local/sbin/netpivot-agent
install -m 644 netpivot.nft /etc/netpivot/netpivot.nft
install -m 644 netpivot-firewall.service netpivot-agent.service /etc/systemd/system/
install -m 644 wg-firewall.conf /etc/systemd/system/wg-quick@netpivot0.service.d/firewall.conf
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/70-netpivot.conf
sysctl -p /etc/sysctl.d/70-netpivot.conf
systemctl daemon-reload
systemctl enable --now wg-quick@netpivot0.service netpivot-agent.service
printf 'Gateway public key: '
wg pubkey < /etc/netpivot/gateway.key
