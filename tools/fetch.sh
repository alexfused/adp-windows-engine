#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Get every upstream file in tools/sources.tsv into downloads/fetch/<id>/<file>, one folder each, and check it
# against the SHA-256 pinned there. A file with that name and hash already on this Mac (in the engines' own
# download folders, or ADP_SEED_DIRS, colon-separated) is cloned instead of downloaded. Nothing downloaded is
# ever run.
# Idempotent: a file that is present and verifies is skipped; a failed download leaves nothing behind.
# Usage: tools/fetch.sh [--dry-run] [ID...]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
source "$ROOT/release.conf"
FETCH="$ROOT/downloads/fetch"
DRY=; ONLY=()
for a in "$@"; do
    case $a in
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '3,8p' "$0"; exit 0 ;;
        *) ONLY+=("$a") ;;
    esac
done
log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
IFS=: read -r -a SEEDS <<< "${ADP_SEED_DIRS:-$ARM64_SPIKE/downloads:$X86_64_SPIKE/downloads}"

seed_for() {   # file sha256 -> path of a verified copy on this Mac, or nothing
    local s c
    for s in "${SEEDS[@]}"; do
        [[ -d "$s" ]] || continue
        while IFS= read -r c; do
            [[ "$(sha "$c")" == "$2" ]] && { echo "$c"; return; }
        done < <(find "$s" -maxdepth 3 -type f -name "$1" 2>/dev/null)
    done
}

failed=()
while IFS=$'\t' read -r id engine ship file want hsrc urls; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    if ((${#ONLY[@]})) && [[ " ${ONLY[*]} " != *" $id "* ]]; then continue; fi
    dir="$FETCH/$id"; f="$dir/$file"
    if [[ -f "$f" && "$(sha "$f")" == "$want" ]]; then log "$id: ok"; continue; fi
    seed=$(seed_for "$file" "$want")
    if [[ -n $DRY ]]; then
        if [[ -n "$seed" ]]; then log "$id: would clone $seed"; else log "$id: would download $file from ${urls%% *}"; fi
        continue
    fi
    rm -rf "$dir"; mkdir -p "$dir"
    if [[ -n "$seed" ]]; then
        cp -c "$seed" "$f" 2>/dev/null || cp "$seed" "$f"
        echo "${urls%% *}" > "$dir/SOURCE-URL"
        log "$id: cloned a verified copy"; continue
    fi
    ok=
    for u in $urls; do
        log "$id: downloading $u"
        if curl -fL --retry 3 --connect-timeout 20 --max-time 3600 -sS -o "$f.partial" "$u"; then
            if [[ "$(sha "$f.partial")" == "$want" ]]; then mv "$f.partial" "$f"; echo "$u" > "$dir/SOURCE-URL"; ok=1; break; fi
            log "$id: hash mismatch from $u ($(sha "$f.partial"))"
        fi
        rm -f "$f.partial"
    done
    if [[ -n $ok ]]; then log "$id: ok ($(du -h "$f" | cut -f1))"; else rm -rf "$dir"; failed+=("$id"); fi
done < "$HERE/sources.tsv"

((${#failed[@]} == 0)) || die "not fetched: ${failed[*]}"
if [[ -n $DRY ]]; then log "dry run: nothing fetched"; else log "all fetched and verified"; fi
