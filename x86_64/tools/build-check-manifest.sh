#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build work/tools/check-manifest (native arm64) from tools/check-manifest/main.swift and ADP Monitor's
# own FleetCore sources: WindowsEngine.swift (WindowsEngineManifest, WindowsEngineCatalog, MachOArchs),
# FileTransferLogic.swift (isValidSHA256), and the WindowsEngineArch enum cut out of
# WindowsAppsWire.swift (the rest of that file needs half of FleetCore).
# Usage: tools/build-check-manifest.sh   (verify.sh runs it)

source "$(dirname "$0")/../env.sh"
REPO="$(cd "$SPIKE/../.." && pwd)"
out="$WORK/tools/check-manifest"; arch="$WORK/tools/check-manifest-arch.swift"
mkdir -p "$WORK/tools"
{ echo "import Foundation"; awk '/^public enum WindowsEngineArch/ {p=1} p {print} p && /^}/ {exit}' "$REPO/Sources/FleetCore/Features/WindowsAppsWire.swift"; } > "$arch"
grep -q 'case x86_64' "$arch" || die "could not find WindowsEngineArch in WindowsAppsWire.swift"
xcrun swiftc -O -o "$out" "$SPIKE/tools/check-manifest/main.swift" "$arch" \
    "$REPO/Sources/FleetCore/WindowsApps/WindowsEngine.swift" "$REPO/Sources/FleetCore/Remote/FileTransferLogic.swift" \
    2>&1 | grep -v -E 'warning:|^ *[0-9]* \||^ *\||^$' | grep . && die "check-manifest did not compile"
[[ "$(lipo -archs "$out")" == arm64 ]] || die "check-manifest is not native arm64"
echo "$out"
