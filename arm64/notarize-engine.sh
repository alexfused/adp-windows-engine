#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Notarise the staged engine with Apple (notarytool, keychain profile "ADPMonitor") and staple
# WineHost.app. This uploads the files to Apple.
#   --winehost   WineHost.app alone (the profile-carrying helper app)
#   --engine     the whole engine folder (every Mach-O: loader, wineserver, unix libraries,
#                lib/ext), so a quarantined copy passes Gatekeeper's online ticket check
# Apple's JSON answer and its log go to evidence/<engine>/notary-<what>.json and -log.json.
# Rerunnable: an already stapled WineHost.app is left alone.
# Usage: notarize-engine.sh --winehost|--engine [--dry-run]

source "$(dirname "$0")/env.sh"
source "$SPIKE/engine-env.sh"
what="${1:-}"; dry="${2:-}"
[[ "$what" == --winehost || "$what" == --engine ]] || die "usage: $0 --winehost|--engine [--dry-run]"
STAGE="$DIST/stage/$STAGE_NAME"; APP="$STAGE/lib/wine/aarch64-unix/WineHost.app"
[[ -d "$APP" ]] || die "run package.sh first"
mkdir -p "$DIST/notary" "$EVIDENCE"
name=${what#--}
zip="$DIST/notary/$STAGE_NAME-$name.zip"
rm -f "$zip"
if [[ $name == winehost ]]; then ditto -c -k --keepParent "$APP" "$zip"; else ditto -c -k --keepParent "$STAGE" "$zip"; fi
log "$(basename "$zip"): $(du -h "$zip" | cut -f1), sha256 $(shasum -a 256 "$zip" | cut -c1-16)..."
if [[ "$dry" == --dry-run ]]; then echo "would run: xcrun notarytool submit $zip --keychain-profile ADPMonitor --wait"; exit 0; fi

t0=$(date +%s)
xcrun notarytool submit "$zip" --keychain-profile ADPMonitor --wait --output-format json > "$EVIDENCE/notary-$name.json" 2> "$WORK/logs/notary-$name.err"
rc=$?
log "notarytool exit $rc after $(( $(date +%s) - t0 )) s: $(cat "$EVIDENCE/notary-$name.json")"
id=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$EVIDENCE/notary-$name.json" 2>/dev/null)
[[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile ADPMonitor "$EVIDENCE/notary-$name-log.json" > /dev/null 2>&1
[[ -f "$EVIDENCE/notary-$name-log.json" ]] && python3 -I - "$EVIDENCE/notary-$name-log.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
print("status:", d.get("status"), "|", d.get("statusSummary"))
issues = d.get("issues") or []
print("issues:", len(issues))
for i in issues[:20]:
    print("  ", i.get("severity"), i.get("path"), "-", i.get("message"))
print("ticketContents entries:", len(d.get("ticketContents") or []))
EOF
grep -q '"status":"Accepted"' "$EVIDENCE/notary-$name.json" || die "not accepted"

if xcrun stapler validate "$APP" > /dev/null 2>&1; then
    log "WineHost.app already stapled"
else
    xcrun stapler staple "$APP" | tail -1
fi
xcrun stapler validate "$APP" | tail -1
spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/spctl: /'
codesign --verify --strict "$APP" && log "WineHost.app signature still valid after stapling"
