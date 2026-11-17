#!/usr/bin/env bash
set -euo pipefail

sdk=$(xcrun --sdk iphoneos --show-sdk-path)
bridge="$SRCROOT/Dependencies/wireguard-apple/Sources/WireGuardKitGo"
unset GOROOT
PATH="$NETPIVOT_WG_GOROOT/bin:$PATH" make -C "$bridge" build PLATFORM_NAME=iphoneos SDKROOT="$sdk" \
    ARCHS=arm64 CONFIGURATION_BUILD_DIR="$CONFIGURATION_BUILD_DIR" \
    CONFIGURATION_TEMP_DIR="$CONFIGURATION_TEMP_DIR" \
    DEPLOYMENT_TARGET_CLANG_FLAG_NAME=miphoneos-version-min DEPLOYMENT_TARGET_CLANG_ENV_NAME=IPHONEOS_DEPLOYMENT_TARGET
