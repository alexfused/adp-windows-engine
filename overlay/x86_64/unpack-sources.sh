#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Prepare downloads/ from the source files of the GitHub release, then run fetch.sh, which finds every file
# already there with the SHA-256 it pins (sources.tsv, patches.sha256), downloads nothing more except
# llvm-mingw, and unpacks and patches the trees in work/src exactly as in the build.
#   downloads/<id>/<file>   <- the release file with the SHA-256 sources.tsv pins for <id> (found by hash, so a
#                              release name that differs from the build's, like the GnuTLS fix, still matches)
#   downloads/hadron-<ref>/ <- hadron/patches/wine/ in this folder (the Hadron patches as applied)
#   downloads/llvm-mingw/   <- LLVM_MINGW_TARBALL=path if given; otherwise fetch.sh downloads it (a build tool,
#                              not part of the engine's source)
# Then: build-deps.sh, build-wine.sh, package.sh, archive.sh (or build-all.sh without --clean).
# Idempotent: files already in place with the right hash are kept.
# Usage: unpack-sources.sh SOURCES [--dry-run]

source "$(dirname "$0")/env.sh"
SRCDIR="${1:-}"; DRY=; [[ "${2:-}" == --dry-run ]] && DRY=1
[[ -d "$SRCDIR" ]] || die "usage: $0 SOURCES_FOLDER [--dry-run]"
SRCDIR="$(cd "$SRCDIR" && pwd)"
run() { if [[ -n $DRY ]]; then echo "would run: $*"; else "$@"; fi; }

# SHA-256 of every file in the release folder, once ("<sha256>  <path>" lines; macOS bash 3.2 has no maps).
hashes=$(find "$SRCDIR" -maxdepth 1 -type f -exec shasum -a 256 {} +)

while IFS=$'\t' read -r id file want _src _urls; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    dest="$DOWNLOADS/$id/$file"
    if [[ -f "$dest" && "$(sha256 "$dest")" == "$want" ]]; then log "$id: ready"; continue; fi
    from=$(awk -v h="$want" '$1 == h { sub(/^[0-9a-f]+  /, ""); print; exit }' <<< "$hashes")
    if [[ -z "$from" && $id == llvm-mingw && -n "${LLVM_MINGW_TARBALL:-}" ]]; then
        [[ "$(sha256 "$LLVM_MINGW_TARBALL")" == "$want" ]] || die "LLVM_MINGW_TARBALL is not the pinned llvm-mingw"
        from="$LLVM_MINGW_TARBALL"
    fi
    if [[ -z "$from" ]]; then
        [[ $id == llvm-mingw ]] && { log "llvm-mingw: fetch.sh will download it"; continue; }
        die "no file with the SHA-256 of $file ($want) in $SRCDIR"
    fi
    run mkdir -p "$DOWNLOADS/$id"
    run cp "$from" "$dest"
    log "$id: $(basename "$from") from the release"
done < "$SPIKE/sources.tsv"

hadron_dir="$DOWNLOADS/hadron-$HADRON_REF"
run mkdir -p "$hadron_dir"
while read -r want file; do
    [[ "$(sha256 "$SPIKE/hadron/patches/wine/$file")" == "$want" ]] || die "hadron/patches/wine/$file is not the pinned file"
    run cp "$SPIKE/hadron/patches/wine/$file" "$hadron_dir/$file"
done < "$SPIKE/patches.sha256"
log "Hadron: $(wc -l < "$SPIKE/patches.sha256" | tr -d ' ') files staged"

if [[ -n $DRY ]]; then "$SPIKE/fetch.sh" --dry-run; else "$SPIKE/fetch.sh"; fi
log "done: now build-deps.sh, build-wine.sh, package.sh, archive.sh"
