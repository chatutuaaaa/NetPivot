#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" != 3 ] && [ "$#" != 4 ]; then
    echo "Usage: bash apple/scripts/bootstrap.sh TEAM_ID BUNDLE_ID HOST [APP_ID_PREFIX]" >&2
    exit 1
fi
team=$1
bundle=$2
host=$3
prefix=${4:-$team}
if [[ ! "$team" =~ ^[A-Z0-9]{10}$ || ! "$prefix" =~ ^[A-Z0-9]{10}$ ||
      ! "$bundle" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$ ||
      ! "$host" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    echo "Invalid Apple identifier or public hostname." >&2
    exit 1
fi
command -v xcodegen >/dev/null
command -v go >/dev/null
go install golang.org/dl/go1.19.13@v0.0.0-20261110170429-b9769cbc5f78
gobin=$(go env GOBIN)
gobin=${gobin:-$(go env GOPATH)/bin}
"$gobin/go1.19.13" download
wg_goroot=$("$gobin/go1.19.13" env GOROOT)
mkdir -p Dependencies
repo=Dependencies/wireguard-apple
commit=2fec12a6e1f6e3460b6ee483aa00ad29cddadab1
if [ ! -d "$repo/.git" ]; then
    git clone https://git.zx2c4.com/wireguard-apple "$repo"
fi
if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    echo "WireGuard dependency has local changes; review them before updating." >&2
    exit 1
fi
git -C "$repo" checkout --detach "$commit"
cat > Config/Local.xcconfig <<EOF
DEVELOPMENT_TEAM = $team
NETPIVOT_APP_BUNDLE_ID = $bundle
NETPIVOT_HOST = $host
NETPIVOT_APP_IDENTIFIER_PREFIX = $prefix
NETPIVOT_WG_GOROOT = $wg_goroot
EOF
xcodegen generate --spec project.yml
echo "Open apple/NetPivot.xcodeproj and choose a signed iPhone or iPad."
