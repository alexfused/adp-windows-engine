#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Distribution proof: copy the notarised engine to a new folder, give every file and folder the
# com.apple.quarantine attribute a browser download carries (Archive Utility passes it on to
# everything it unpacks), then run it: Gatekeeper's verdict, a new golden prefix, PuTTY 64 and
# PuTTY 32 as windows. Control: the same with a copy whose WineHost.app is Developer ID signed
# but was never notarised (dist/matrix/plus-jit: one more entitlement, so another cdhash; a copy
# that differs only in its timestamp has the same cdhash and so the same ticket), which
# Gatekeeper should refuse.
# Usage: quarantine-test.sh

source "$(dirname "$0")/env.sh"
source "$SPIKE/engine-env.sh"
set +e
STAGE="$DIST/stage/$STAGE_NAME"
xcrun stapler validate "$STAGE/lib/wine/aarch64-unix/WineHost.app" > /dev/null || die "WineHost.app is not stapled: run notarize-engine.sh"
qroot="$DIST/quarantine-test"; rm -rf "$qroot"; mkdir -p "$qroot/notarised" "$qroot/not-notarised"
qval="0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)"
quarantine() {  # copy src to dst and mark everything (not the symlinks themselves)
    ditto "$1" "$2"
    find "$2" ! -type l -print0 | xargs -0 xattr -w com.apple.quarantine "$qval"
    echo "  $(find "$2" ! -type l | wc -l | tr -d ' ') items quarantined; e.g. $(xattr -p com.apple.quarantine "$2/bin/wineserver")"
}
log "copying the notarised engine to $qroot/notarised"
quarantine "$STAGE" "$qroot/notarised/$STAGE_NAME"
log "control: a copy whose WineHost.app is Developer ID signed but not notarised"
[[ -d "$DIST/matrix/plus-jit" ]] || "$SPIKE/entitlement-matrix.sh" plus-jit > /dev/null
quarantine "$DIST/matrix/plus-jit" "$qroot/not-notarised/$STAGE_NAME"

for which in notarised not-notarised; do
    root="$qroot/$which/$STAGE_NAME"; app="$root/lib/wine/aarch64-unix/WineHost.app"
    echo "## $which"
    spctl --assess --type execute -vv "$app" 2>&1 | sed 's/^/  spctl WineHost.app: /'
    echo "  cdhash WineHost.app: $(codesign -dvvv "$app" 2>&1 | sed -n 's/^CDHash=//p')"
    out=$("$root/bin/wine" --version 2>&1); echo "  wine --version: rc=$? $out"
done

log "running PuTTY from the quarantined, notarised copy"
export ENGINE_ROOT="$qroot/notarised/$STAGE_NAME" PREFIXES="$WORK/prefixes-quarantine" TAG=-quarantine
"$SPIKE/golden.sh" --force 2>&1 | tail -3
ENGINE_ROOT="$ENGINE_ROOT" "$SPIKE/smoke.sh" --label smoke-quarantine | tail -3
"$SPIKE/test-programs.sh" putty64 putty32
# Gatekeeper's own record of the run.
/usr/bin/log show --last 10m --style compact --predicate 'process == "syspolicyd" AND eventMessage CONTAINS "WineHost"' 2>/dev/null | tail -5
