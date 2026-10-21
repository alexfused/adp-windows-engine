#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Prove that ADP Monitor's root helper would refuse every part of the engine as a caller.
# The helper accepts a connection only from code that satisfies
#   identifier "com.alexparkin.adpmonitor" and <HelperProtocol.trustedSignerClause>
# (Sources/ADPHelper/main.swift callerRequirement, Sources/SMCKit/HelperProtocol.swift). This runs
# exactly that requirement, read from those two files, against WineHost.app and every Mach-O file
# in the staged engine: each check must FAIL. Two controls must PASS, so a requirement that fails
# for everything cannot fake the proof: ADP Monitor.app itself (if installed; read-only check) and
# the 11.18-1 engine's WineHost.app (signed as com.alexparkin.adpmonitor), if that build is still
# on this Mac. Read-only: codesign --verify only. Output: evidence/<engine>/helper-check.txt.
# Usage: helper-check.sh [engine root]   (default: the staged engine)

source "$(dirname "$0")/env.sh"
set +e
REPO="$(cd "$SPIKE/../.." && pwd)"
STAGE_NAME=$(cat "$DIST/stage/"*/ENGINE-NAME 2>/dev/null | head -1)
ROOT="${1:-$DIST/stage/$STAGE_NAME}"
[[ -d "$ROOT/lib/wine/aarch64-unix/WineHost.app" ]] || die "no engine at $ROOT (run package.sh)"
NAME=$(cat "$ROOT/ENGINE-NAME")
OUTF="$SPIKE/evidence/$NAME/helper-check.txt"; mkdir -p "$(dirname "$OUTF")"

# The requirement, from the helper's source (not retyped).
ident=$(sed -n 's/.*static let callerRequirement = #"\(identifier "[^"]*"\) and "# + HelperProtocol.trustedSignerClause.*/\1/p' "$REPO/Sources/ADPHelper/main.swift")
clause=$(sed -n '/static let trustedSignerClause =/{n;s/^ *#"\(.*\)"#$/\1/p;}' "$REPO/Sources/SMCKit/HelperProtocol.swift")
[[ -n "$ident" && -n "$clause" ]] || die "could not read the caller requirement from the helper's source"
REQ="$ident and $clause"

check() {  # path -> prints "REFUSED"/"ACCEPTED" and codesign's own message
    local out rc
    out=$(codesign --verify -R="$REQ" "$1" 2>&1); rc=$?
    if [[ $rc == 0 ]]; then echo "ACCEPTED rc=0"; else echo "REFUSED rc=$rc: $(echo "$out" | tail -1 | sed "s|$ROOT|<engine>|")"; fi
}

{
    echo "# Root helper caller check against $NAME ($(date -u '+%Y-%m-%d %H:%M UTC'))"
    echo "requirement: $REQ"
    echo "command: codesign --verify -R='<requirement>' <file>   (must be REFUSED for every engine file)"
    echo
    accepted=0; n=0
    app="$ROOT/lib/wine/aarch64-unix/WineHost.app"
    r=$(check "$app"); n=$((n + 1)); [[ $r == ACCEPTED* ]] && accepted=$((accepted + 1))
    echo "WineHost.app (identifier $(codesign -dvv "$app" 2>&1 | sed -n 's/^Identifier=//p')): $r"
    while IFS= read -r -d '' f; do
        [[ "$(head -c 4 "$f" | xxd -p)" =~ ^(cffaedfe|cafebabe)$ ]] || continue
        r=$(check "$f"); n=$((n + 1)); [[ $r == ACCEPTED* ]] && accepted=$((accepted + 1))
        echo "${f#"$ROOT"/} (identifier $(codesign -dvv "$f" 2>&1 | sed -n 's/^Identifier=//p')): $r"
    done < <(find "$ROOT" -type f ! -path '*-windows/*' -print0 | sort -z)
    echo
    echo "engine files checked: $n, accepted by the requirement: $accepted"
    echo
    echo "## Controls (must be ACCEPTED, or the requirement proves nothing)"
    for c in "/Applications/ADP Monitor.app" \
             "${ADP_OLD_WINEHOST:-$DIST/stage/engine-arm64-11.18-1/lib/wine/aarch64-unix/WineHost.app}"; do
        if [[ -e "$c" ]]; then
            echo "${c/#$HOME/~} (identifier $(codesign -dvv "$c" 2>&1 | sed -n 's/^Identifier=//p')): $(check "$c")"
        else
            echo "${c/#$HOME/~}: not on this Mac, skipped"
        fi
    done
    [[ $accepted == 0 ]] && echo "RESULT: pass (the helper refuses all $n engine files)" || echo "RESULT: FAIL ($accepted engine files accepted)"
} > "$OUTF"
grep -E '^(requirement|engine files|RESULT)|Controls|Monitor.app|11.18-1' "$OUTF"
grep -q '^RESULT: pass' "$OUTF"
