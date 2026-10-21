#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fetch everything the engine is built from, pinned, and apply the chosen patch queue.
#   - llvm-mingw (PE toolchain for FEX's DLLs), SHA-256 checked, into work/toolchains/
#   - Hadron at HADRON_REF (patch queues and the upstream pins in its sources.conf)
#   - Wine and FEX at Hadron's pins, with the patches patches.conf marks "apply"
#   - the source tarballs of the lib/ext libraries listed in ext.conf, SHA-256 checked, into
#     downloads/ext/<name>/. A file with the same SHA-256 already on this Mac (ADP_EXT_SEED, default:
#     the licence review's downloads, which came from the same URLs) is cloned instead of downloaded.
# Idempotent: a finished step is skipped; a checkout whose patch list changed is reset and re-patched.
# Usage: fetch.sh [--dry-run]

source "$(dirname "$0")/env.sh"
DRY=; [[ "${1:-}" == --dry-run ]] && DRY=1
run() { if [[ -n $DRY ]]; then echo "would run: $*"; else "$@"; fi; }

mkdir -p "$WORK/src" "$WORK/toolchains" "$DOWNLOADS"

# llvm-mingw: own folder under downloads/, hash checked before it is unpacked.
if [[ ! -x "$MINGW/arm64ec-w64-mingw32-clang" ]]; then
    dl="$DOWNLOADS/llvm-mingw"; tarball="$dl/$LLVM_MINGW_NAME.tar.xz"
    mkdir -p "$dl"
    if [[ ! -f "$tarball" ]]; then
        log "downloading $LLVM_MINGW_NAME"
        run curl -fL --retry 3 -o "$tarball.partial" "$LLVM_MINGW_URL"
        [[ -n $DRY ]] || mv "$tarball.partial" "$tarball"
    fi
    if [[ -z $DRY ]]; then
        got=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
        [[ "$got" == "$LLVM_MINGW_SHA256" ]] || die "llvm-mingw SHA-256 $got, expected $LLVM_MINGW_SHA256"
        log "llvm-mingw hash ok"
        rm -rf "$WORK/toolchains/$LLVM_MINGW_NAME" "$WORK/toolchains/llvm-mingw"
        tar -xJf "$tarball" -C "$WORK/toolchains"
        mv "$WORK/toolchains/$LLVM_MINGW_NAME" "$WORK/toolchains/llvm-mingw"
    fi
fi
[[ -n $DRY ]] || log "llvm-mingw: $("$MINGW/arm64ec-w64-mingw32-clang" --version | head -1)"

# Hadron, pinned.
if [[ ! -d "$HADRON/.git" ]]; then run git clone -q "$HADRON_URL" "$HADRON"; fi
run git -C "$HADRON" checkout -q --detach "$HADRON_REF"

pin() { awk -v n="$1" '$1 == n { print $2, $3 }' "$HADRON/sources.conf"; }

checkout() {   # name dir
    local name="$1" dir="$2" url ref want have
    read -r url ref < <(pin "$name")
    [[ -n "$ref" ]] || die "no pin for $name in Hadron's sources.conf"
    want=$(awk -v n="$name" '$1 == n && $3 == "apply" { printf "%s ", $2 }' "$SPIKE/patches.conf")
    have=$(cat "$dir/.adp-patches" 2>/dev/null || true)
    if [[ -d "$dir/.git" && "$have" == "$want@$ref" ]]; then
        log "$name at $ref already patched ($want)"; return
    fi
    if [[ ! -d "$dir/.git" ]]; then
        log "cloning $name"
        run git clone -q --filter=blob:none --no-checkout "$url" "$dir"
    fi
    [[ -n $DRY ]] && { echo "would check out $name $ref and apply: $want"; return; }
    git -C "$dir" am --abort >/dev/null 2>&1 || true
    git -C "$dir" checkout -q -f --detach "$ref"
    git -C "$dir" clean -qfdx
    git -C "$dir" submodule update --init --recursive --filter=blob:none -q
    local patches=() n f
    for n in $want; do
        f=$(ls "$HADRON/patches/$name/$n"-*.patch 2>/dev/null | head -1)
        [[ -n "$f" ]] || die "no patch $name/$n in Hadron"
        patches+=("$f")
    done
    log "applying ${#patches[@]} patches to $name"
    git -C "$dir" -c user.name=adp-engine -c user.email=engine@adp.invalid am -q --3way "${patches[@]}" \
        || die "a $name patch did not apply (see git -C $dir am --show-current-patch)"
    echo "$want@$ref" > "$dir/.adp-patches"
    log "$name at $(git -C "$dir" rev-parse --short HEAD) on $ref"
}

checkout wine "$WINE_SRC"
checkout fex "$FEX_SRC"

# lib/ext sources: one folder each, hash checked every run (also when already present).
seed="${ADP_EXT_SEED:-$SPIKE/../windows-engine-release/downloads/fetch}"
seeds=""
if [[ -d "$seed" ]]; then
    seeds=$(find "$seed" -mindepth 2 -maxdepth 2 -type f -size -100M -exec shasum -a 256 {} + 2>/dev/null)
fi
while IFS=$'\t' read -r name version file sha hashsrc urls; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    dir="$DOWNLOADS/ext/$name"; f="$dir/$file"
    mkdir -p "$dir"
    if [[ ! -f "$f" ]]; then
        from=$(awk -v h="$sha" '$1 == h { $1 = ""; sub(/^ +/, ""); print; exit }' <<< "$seeds")
        if [[ -n "$from" ]]; then
            run cp -c "$from" "$f"; log "$file: cloned from $from"
            # The URL that copy was downloaded from, as its fetch recorded it.
            [[ -f "$(dirname "$from")/SOURCE-URL" ]] && run cp "$(dirname "$from")/SOURCE-URL" "$dir/SOURCE-URL"
        else
            for url in $urls; do
                log "downloading $url"
                if [[ -n $DRY ]]; then echo "would run: curl -fL $url"; break; fi
                curl -fL --retry 3 -o "$f.partial" "$url" && { mv "$f.partial" "$f"; echo "$url" > "$dir/SOURCE-URL"; break; }
            done
        fi
    fi
    [[ -n $DRY && ! -f "$f" ]] && continue
    [[ -f "$f" ]] || die "could not get $file"
    [[ -f "$dir/SOURCE-URL" ]] || echo "${urls%% *}" > "$dir/SOURCE-URL"
    got=$(shasum -a 256 "$f" | cut -d' ' -f1)
    [[ "$got" == "$sha" ]] || die "$file: SHA-256 $got, expected $sha ($hashsrc)"
    echo "ok  ext/$name/$file ($hashsrc)"
done < "$SPIKE/ext.conf"
log "done"
