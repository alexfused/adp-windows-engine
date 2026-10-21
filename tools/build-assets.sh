#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build everything the GitHub release needs, from the verified downloads (tools/fetch.sh) and the two engines:
#   0. inputs: both engine archives at the SHA-256 release.conf pins; the FEX source tarball (FEX_SRC_SHA256),
#      taken from a verified copy on this Mac or made by tools/make-fex-src.sh when FEX_GIT is set
#   1. arm64/ and x86_64/ from the commits that built the engines (tools/import-build-scripts.py), then our
#      reproducible tarballs of them in downloads/own/ (tools/dettar.py):
#        adp-engine-arm64-<ver>-build.tar.xz    scripts, Hadron patches as applied, unpack-sources.sh
#        adp-engine-x86_64-<ver>-build.tar.xz   scripts, our and Hadron's patches as applied, unpack-sources.sh
#   2. downloads/release-sources/: every source file of the release + SHA256SUMS
#   3. licenses/ (tools/collect-licences.py)
#   4. THIRD-PARTY-LICENSES.md, downloads/own/<engine>.THIRD-PARTY-LICENSES.md and manifests/ (tools/notices.py)
#   5. downloads/release/: the complete upload set as APFS clones + SHA256SUMS, then RELEASE-NOTES.md
# Uploads nothing. Rerunnable: the same inputs give the same bytes, so hashes do not move between runs.
# Usage: tools/build-assets.sh [--help]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '3,15p' "$0"; exit 0; }
source "$ROOT/release.conf"
OWN="$ROOT/downloads/own"; SRCS="$ROOT/downloads/release-sources"; REL="$ROOT/downloads/release"
SCRATCH="$ROOT/downloads/work"
log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
dettar() { python3 -I "$HERE/dettar.py" "$@"; }
mkdir -p "$OWN" "$SRCS" "$REL" "$SCRATCH"

# 0. Inputs
"$HERE/fetch.sh" > /dev/null || die "tools/fetch.sh failed: run it on its own to see why"
for e in ARM64 X86_64; do
    a="${e}_ARCHIVE"; s="${e}_ARCHIVE_SHA256"; m="${e}_MANIFEST_IN"
    [[ -f "${!a}" && -f "${!m}" ]] || die "no $e archive and manifest at ${!a} (set ${e}_SPIKE)"
    [[ "$(sha "${!a}")" == "${!s}" ]] || die "$(basename "${!a}"): SHA-256 differs from release.conf"
done
fex_out="$OWN/fex-$FEX_COMMIT-src.tar.xz"
if [[ ! -f "$fex_out" || "$(sha "$fex_out")" != "$FEX_SRC_SHA256" ]]; then
    rm -f "$fex_out"
    IFS=: read -r -a seeds <<< "${ADP_SEED_DIRS:-$ARM64_SPIKE/downloads:$X86_64_SPIKE/downloads}"
    for s in "${seeds[@]}"; do
        [[ -d "$s" ]] || continue
        while IFS= read -r c; do
            if [[ "$(sha "$c")" == "$FEX_SRC_SHA256" ]]; then cp -c "$c" "$fex_out"; log "FEX source tarball: verified copy"; break 2; fi
        done < <(find "$s" -maxdepth 3 -type f -name "$(basename "$fex_out")" 2>/dev/null)
    done
    [[ -f "$fex_out" ]] || { [[ -n "${FEX_GIT:-}" ]] || die "no FEX source tarball: set FEX_GIT (tools/make-fex-src.sh) or ADP_SEED_DIRS"; "$HERE/make-fex-src.sh"; }
fi
log "inputs ok"

# 1. Build folders from the commits that built the engines, and their tarballs.
python3 -I "$HERE/import-build-scripts.py"
builds=()
for e in arm64 x86_64; do
    eng=$( [[ $e == arm64 ]] && echo "$ARM64_ENGINE" || echo "$X86_64_ENGINE" )
    name="adp-$eng-build"
    dettar "$OWN/$name.tar.xz" --dir "$ROOT/$e" "$name" --mtime "$SOURCE_DATE_EPOCH" > /dev/null
    builds+=("$OWN/$name.tar.xz")
done

# 2. Source files of the release.
want=()
while IFS=$'\t' read -r id engine ship file rest; do
    [[ -z "$id" || "$id" == \#* || "$ship" != source ]] && continue
    want+=("$file")
    [[ -f "$SRCS/$file" && "$(sha "$SRCS/$file")" == "$(sha "$ROOT/downloads/fetch/$id/$file")" ]] \
        || { rm -f "$SRCS/$file"; cp -c "$ROOT/downloads/fetch/$id/$file" "$SRCS/$file"; }
done < "$HERE/sources.tsv"
for f in "$fex_out" "${builds[@]}"; do
    want+=("$(basename "$f")"); rm -f "$SRCS/$(basename "$f")"; cp -c "$f" "$SRCS/"
done
for f in "$SRCS"/*; do
    n=$(basename "$f"); [[ "$n" == SHA256SUMS ]] && continue
    [[ " ${want[*]} " == *" $n "* ]] || { log "removing stale $n"; rm -f "$f"; }
done
(cd "$SRCS" && printf '%s\n' "${want[@]}" | sort | while read -r n; do shasum -a 256 "$n"; done) > "$SRCS/SHA256SUMS"
log "release-sources: ${#want[@]} files, $(du -sh "$SRCS" | cut -f1)"

# 3-4. Licences, notices, manifests.
python3 -I "$HERE/collect-licences.py"
python3 -I "$HERE/notices.py" notices
python3 -I "$HERE/notices.py" manifests

# 5. The upload set.
assets=("$ARM64_ARCHIVE" "$X86_64_ARCHIVE"
        "$ROOT/manifests/$ARM64_ENGINE.manifest.json" "$ROOT/manifests/$X86_64_ENGINE.manifest.json"
        "$OWN/$ARM64_ENGINE.THIRD-PARTY-LICENSES.md" "$OWN/$X86_64_ENGINE.THIRD-PARTY-LICENSES.md")
for n in "${want[@]}"; do assets+=("$SRCS/$n"); done
names=()
for a in "${assets[@]}"; do
    n=$(basename "$a"); names+=("$n")
    [[ -f "$REL/$n" && "$(sha "$REL/$n")" == "$(sha "$a")" ]] || { rm -f "$REL/$n"; cp -c "$a" "$REL/$n"; }
done
for f in "$REL"/*; do
    n=$(basename "$f"); [[ "$n" == SHA256SUMS ]] && continue
    [[ " ${names[*]} " == *" $n "* ]] || { log "removing stale $n"; rm -f "$f"; }
done
(cd "$REL" && printf '%s\n' "${names[@]}" | sort | while read -r n; do shasum -a 256 "$n"; done) > "$REL/SHA256SUMS"
python3 -I "$HERE/notices.py" notes
log "release: $(( ${#names[@]} + 1 )) files, $(du -shL "$REL" | cut -f1) in downloads/release/"
