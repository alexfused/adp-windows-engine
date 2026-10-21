#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Which of WineHost.app's entitlements are actually needed? For each variant: an APFS clone of
# the staged engine in dist/matrix/<variant>, WineHost.app re-signed with only that variant's
# entitlements (no timestamp: these copies are never shipped), then smoke.sh --fresh-prefix
# (prefix creation, native arm64 code, x86_64 and i386 code through FEX, crypto). Headless.
# Variants, relative to the shipped set (profile ids + cross-architecture + unsigned executable
# memory + disable library validation):
#   shipped, plus-jit (adds allow-jit; also quarantine-test.sh's not-notarised control),
#   no-dlv, no-unsigned-mem, profile-only, no-profile
# Usage: entitlement-matrix.sh [variant...]   (default: all)

source "$(dirname "$0")/env.sh"
source "$SPIKE/engine-env.sh"
set +e
STAGE="$DIST/stage/$STAGE_NAME"
[[ -d "$STAGE" ]] || die "run package.sh first"
JIT=com.apple.security.cs.allow-jit
UEM=com.apple.security.cs.allow-unsigned-executable-memory
DLV=com.apple.security.cs.disable-library-validation
variants=("${@:-shipped plus-jit no-dlv no-unsigned-mem profile-only no-profile}")
read -r -a variants <<< "${variants[*]}"

for v in "${variants[@]}"; do
    case $v in
        shipped)          keys="$UEM $DLV";      profile=1 ;;
        plus-jit)         keys="$JIT $UEM $DLV"; profile=1 ;;
        no-dlv)           keys="$UEM";           profile=1 ;;
        no-unsigned-mem)  keys="$DLV";           profile=1 ;;
        profile-only)     keys="";               profile=1 ;;
        no-profile)       keys="$UEM $DLV";      profile=0 ;;
        *) die "unknown variant $v" ;;
    esac
    root="$DIST/matrix/$v"; app="$root/lib/wine/aarch64-unix/WineHost.app"
    rm -rf "$root"; mkdir -p "$DIST/matrix"; cp -Rc "$STAGE" "$root"
    ent="$WORK/matrix-$v.plist"
    python3 -I - "$PROFILE" "$ent" "$profile" $keys <<'EOF'
import plistlib, subprocess, sys
ents = {}
if sys.argv[3] == "1":
    granted = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", sys.argv[1]], capture_output=True, check=True).stdout)["Entitlements"]
    for k in ("com.apple.application-identifier", "com.apple.developer.team-identifier", "com.apple.developer.cross-architecture-support"):
        ents[k] = granted[k]
for k in sys.argv[4:]:
    ents[k] = True
plistlib.dump(ents, open(sys.argv[2], "wb"))
EOF
    [[ $profile == 1 ]] || rm -f "$app/Contents/embedded.provisionprofile"
    codesign --force --sign "$IDENTITY" --timestamp=none --options runtime --entitlements "$ent" "$app" 2>/dev/null
    echo "## $v: $(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o - - | python3 -I -c 'import json,sys; print(" ".join(sorted(k.split(".")[-1] for k in json.load(sys.stdin))) or "(none)")') profile=$profile"
    ENGINE_ROOT="$root" "$SPIKE/smoke.sh" --fresh-prefix --label "ent-$v" 2>&1 | grep -v -E '^\s*$'
    # What killed it, if anything: the last lines of the log, and amfid's verdict.
    grep -m3 -E 'Killed|failed to|err:virtual|c0000|noexec|cannot|signal' "$TESTLOGS/ent-$v.log" | cut -c1-200 | sed 's/^/    log: /'
    ENGINE_ROOT="$root" "$WINESERVER" -k 2>/dev/null
done
