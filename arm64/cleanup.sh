#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Leave the Mac as the spike found it: stop every engine process this spike started, take every
# WineHost.app copy under dist/ and work/ out of Launch Services (each test copy registers itself
# as com.alexparkin.adpmonitor.winehost; 11.18-1 copies even as ADP Monitor's own id), and delete
# the test copies, prefixes and matrix trees. Keeps the sources, build trees, dist/engine-root,
# dist/stage and dist/archive. Idempotent.
# Usage: cleanup.sh [--all]   (--all also deletes dist/stage and dist/engine-root)

source "$(dirname "$0")/env.sh"
set +e
lsreg=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
procarch="$WORK/tools/procarch"

for p in "$WORK"/prefixes*/*/; do
    [[ -f "$p/system.reg" ]] || continue
    for root in "$DIST"/stage/* "$DIST"/matrix/* "$DIST"/quarantine-test/*/*; do
        [[ -x "$root/bin/wineserver" ]] && WINEPREFIX="${p%/}" "$root/bin/wineserver" -k 2>/dev/null
    done
done
sleep 1
left=$("$procarch" "$DIST/" 2>/dev/null | cut -f1)
[[ -z "$left" ]] || { echo "killing leftover engine processes: $left"; kill $left 2>/dev/null; sleep 1; kill -9 $left 2>/dev/null; }

# Launch Services: every WineHost.app it knows under this spike, present or already deleted.
"$lsreg" -dump 2>/dev/null | sed -n "s|^path: *\(${SPIKE}/.*\.app\) (0x[0-9a-f]*)$|\1|p" | sort -u | while IFS= read -r app; do
    "$lsreg" -u "$app" 2>/dev/null && echo "unregistered ${app#"$SPIKE"/}"
done

rm -rf "$DIST/matrix" "$DIST/quarantine-test" "$DIST/notary" "$WORK"/prefixes* "$WORK/archive-check" "$WORK/shim-test"
[[ "${1:-}" == --all ]] && rm -rf "$DIST/stage" "$DIST/engine-root"
"$lsreg" -dump 2>/dev/null | grep -c "^path: *$SPIKE/" | sed 's/^/Launch Services entries left under the spike: /'
"$procarch" "$DIST/" 2>&1 | tail -1
