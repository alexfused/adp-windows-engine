#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Prepare work/ and downloads/ from the source files of the GitHub release instead of from the network
# (fetch.sh clones upstream git repositories and downloads tarballs). Then run, in order: build-ext.sh,
# build-wine.sh, build-fex.sh, package.sh, archive.sh.
#   work/hadron        <- hadron/ in this folder (Hadron's sources.conf, licences, the patches as applied)
#   work/src/wine      <- wine-<commit>.tar.gz, then the Wine patches patches.conf marks "apply" (git am)
#   work/src/fex       <- fex-<commit>-src.tar.xz (FEX with the submodules the build compiles), then the FEX patches
#   downloads/ext/<name>/<file> <- each library tarball and patch in ext.conf, SHA-256 checked against ext.conf
#   work/toolchains/llvm-mingw  <- llvm-mingw, SHA-256 checked as in fetch.sh (LLVM_MINGW_TARBALL=path reuses a
#                                  copy; otherwise it is downloaded from its GitHub release; ADP_NO_TOOLCHAIN=1
#                                  skips it)
# SOURCES is the folder holding the release's source files (download them from the release page).
# Idempotent: a tree already unpacked and patched for the same pins is left alone.
# Usage: unpack-sources.sh SOURCES [--dry-run]

source "$(dirname "$0")/env.sh"
SRC="${1:-}"; DRY=; [[ "${2:-}" == --dry-run ]] && DRY=1
[[ -d "$SRC" ]] || die "usage: $0 SOURCES_FOLDER [--dry-run]"
SRC="$(cd "$SRC" && pwd)"
run() { if [[ -n $DRY ]]; then echo "would run: $*"; else "$@"; fi; }

pin() { awk -v n="$1" '$1 == n { print $3 }' "$SPIKE/hadron/sources.conf"; }
WINE_REF=$(pin wine); FEX_REF=$(pin fex)
[[ -n "$WINE_REF" && -n "$FEX_REF" ]] || die "no wine/fex pin in hadron/sources.conf"

mkdir -p "$WORK/src" "$WORK/toolchains" "$DOWNLOADS"
[[ ! -d "$HADRON/.git" ]] || die "$HADRON is a git checkout from fetch.sh: use fetch.sh or this script, not both"
run rm -rf "$HADRON"; run cp -R "$SPIKE/hadron" "$HADRON"

unpack() {   # name ref tarball
    local name="$1" ref="$2" tarball="$3" dir want have patches=() n f
    dir="$WORK/src/$name"
    want=$(awk -v n="$name" '$1 == n && $3 == "apply" { printf "%s ", $2 }' "$SPIKE/patches.conf")
    have=$(cat "$dir/.adp-patches" 2>/dev/null || true)
    if [[ "$have" == "$want@$ref" && -f "$dir/.adp-release" ]]; then log "$name at $ref already unpacked and patched"; return; fi
    [[ -f "$tarball" ]] || die "missing $tarball"
    [[ ! -d "$dir/.git" || -f "$dir/.adp-release" ]] || die "$dir is a checkout from fetch.sh: remove it first"
    if [[ -n $DRY ]]; then echo "would unpack $(basename "$tarball") and apply: $want"; return; fi
    rm -rf "$dir"; mkdir -p "$dir"
    tar -xf "$tarball" -C "$dir" --strip-components 1
    for n in $want; do
        f=$(ls "$HADRON/patches/$name/$n"-*.patch 2>/dev/null | head -1)
        [[ -n "$f" ]] || die "no patch $name/$n in hadron/patches"
        patches+=("$f")
    done
    # The same git am --3way as fetch.sh, on a one-commit repository holding the release tarball.
    git -C "$dir" init -q
    git -C "$dir" add -A -f
    git -C "$dir" -c user.name=adp-engine -c user.email=engine@adp.invalid commit -q -m "$name $ref (release tarball)"
    log "applying ${#patches[@]} patches to $name"
    git -C "$dir" -c user.name=adp-engine -c user.email=engine@adp.invalid am -q --3way "${patches[@]}" \
        || die "a $name patch did not apply"
    echo "$want@$ref" > "$dir/.adp-patches"; touch "$dir/.adp-release"
    log "$name: $(git -C "$dir" rev-parse HEAD^{tree}) is the patched tree"
}
unpack wine "$WINE_REF" "$SRC/wine-$WINE_REF.tar.gz"
unpack fex "$FEX_REF" "$SRC/fex-$FEX_REF-src.tar.xz"

# lib/ext: the release holds every tarball and patch ext.conf names, under the same file names.
while IFS=$'\t' read -r name version file sha hashsrc urls; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    dir="$DOWNLOADS/ext/$name"; f="$dir/$file"
    if [[ -f "$f" && "$(shasum -a 256 "$f" | cut -d' ' -f1)" == "$sha" ]]; then log "ext/$name/$file ready"; continue; fi
    [[ -f "$SRC/$file" ]] || die "missing $SRC/$file"
    [[ "$(shasum -a 256 "$SRC/$file" | cut -d' ' -f1)" == "$sha" ]] || die "$file: SHA-256 differs from ext.conf ($hashsrc)"
    run mkdir -p "$dir"
    run cp "$SRC/$file" "$f"
    [[ -n $DRY ]] || echo "${urls%% *}" > "$dir/SOURCE-URL"
    log "ext/$name/$file from the release"
done < "$SPIKE/ext.conf"

# llvm-mingw: the PE toolchain for FEX's DLLs (a build tool, not part of the engine's source).
# ADP_NO_TOOLCHAIN=1 skips it (the release's verify.sh only compares source trees).
if [[ -n "${ADP_NO_TOOLCHAIN:-}" ]]; then
    log "llvm-mingw skipped (ADP_NO_TOOLCHAIN)"
elif [[ ! -x "$MINGW/arm64ec-w64-mingw32-clang" ]]; then
    tarball="${LLVM_MINGW_TARBALL:-$DOWNLOADS/llvm-mingw/$LLVM_MINGW_NAME.tar.xz}"
    if [[ ! -f "$tarball" ]]; then
        mkdir -p "$(dirname "$tarball")"
        run curl -fL --retry 3 -o "$tarball.partial" "$LLVM_MINGW_URL"
        [[ -n $DRY ]] || mv "$tarball.partial" "$tarball"
    fi
    if [[ -z $DRY ]]; then
        got=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
        [[ "$got" == "$LLVM_MINGW_SHA256" ]] || die "llvm-mingw SHA-256 $got, expected $LLVM_MINGW_SHA256"
        rm -rf "$WORK/toolchains/$LLVM_MINGW_NAME" "$WORK/toolchains/llvm-mingw"
        tar -xJf "$tarball" -C "$WORK/toolchains"
        mv "$WORK/toolchains/$LLVM_MINGW_NAME" "$WORK/toolchains/llvm-mingw"
    fi
fi
log "done: now build-ext.sh, build-wine.sh, build-fex.sh, package.sh, archive.sh"
