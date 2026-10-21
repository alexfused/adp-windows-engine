#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Make the golden prefix every program's prefix is cloned from (cp -c), once per engine:
# wineboot -u with the Mac driver off (no window, no Dock icon), then the user-folder links
# Wine makes to the Mac's Desktop/Documents/Downloads/Music/Pictures/Videos become real folders
# inside the prefix, so a Windows program sees none of the Mac user's files by default.
# Usage: golden.sh [--force]   (ENGINE_ROOT picks the engine tree)

source "$(dirname "$0")/env.sh"
source "$SPIKE/engine-env.sh"
if [[ -f "$GOLDEN/system.reg" && "${1:-}" != --force ]]; then log "golden prefix exists: $GOLDEN"; exit 0; fi
rm -rf "$GOLDEN"
export WINEPREFIX="$GOLDEN"
log "creating $GOLDEN"
t0=$(now)
WINEDLLOVERRIDES="$WINEDLLOVERRIDES;winemac.drv=d" "$WINE" wineboot -u > "$TESTLOGS/golden.log" 2>&1 || die "wineboot failed (work/logs/golden.log)"
"$WINESERVER" -w
log "wineboot -u took $(echo "$(now) - $t0" | bc) s"
users="$GOLDEN/drive_c/users/$USER"
for d in Desktop Documents Downloads Music Pictures Videos; do
    if [[ -L "$users/$d" ]]; then rm "$users/$d"; mkdir "$users/$d"; fi
done
log "user folders: $(cd "$users" && for d in *; do [[ -L "$d" ]] && printf '%s->%s ' "$d" "$(readlink "$d")" || printf '%s(dir) ' "$d"; done)"
log "golden prefix $(du -sh "$GOLDEN" | cut -f1)"
