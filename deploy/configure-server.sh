#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")"

if [ "$(id -u)" != 0 ] || [ "$#" -ne 2 ]; then
    echo "Usage: sudo bash deploy/configure-server.sh PUBLIC_HOST APP_IDENTIFIER" >&2
    exit 1
fi
if [[ ! "$1" =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ || ! "$2" =~ ^[A-Z0-9]{10}(\.[a-zA-Z0-9-]+){3,}$ ]]; then
    echo "Invalid public hostname or signed Apple app identifier." >&2
    exit 1
fi
if [ -e .env ]; then
    echo "deploy/.env already exists. Edit the existing file for upgrades." >&2
    exit 1
fi
gateway_public_key=$(wg pubkey < /etc/netpivot/gateway.key)
agent_token=$(sed -n 's/^NETPIVOT_AGENT_TOKEN=//p' /etc/netpivot/agent.env)
if [[ ! "$agent_token" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Gateway agent token is missing or invalid." >&2
    exit 1
fi
invite_secret=$(openssl rand -hex 32)
db_password=$(openssl rand -hex 32)
(
    set -o noclobber
    cat > .env <<EOF
NETPIVOT_DOMAIN=$1
NETPIVOT_GATEWAY_ENDPOINT=$1:51820
NETPIVOT_GATEWAY_KEY=$gateway_public_key
NETPIVOT_AGENT_TOKEN=$agent_token
NETPIVOT_INVITE_SECRET=$invite_secret
NETPIVOT_DB_PASSWORD=$db_password
NETPIVOT_APP_ID=$2
EOF
)
printf 'Wrote deploy/.env for %s\n' "$1"
