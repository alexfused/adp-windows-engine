#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fetch, verify and unpack everything the Intel engine is built from.
#   - every file in sources.tsv into downloads/<id>/, used only if its SHA-256 equals the pin
#     (cloned from an earlier verified download on this Mac when one matches, else downloaded)
#   - the Hadron Wine patches patches.conf marks "apply", each pinned in patches.sha256
#   - llvm-mingw into work/toolchains/llvm-mingw (its macOS binaries are universal: they run as arm64)
#   - each source tarball into its own folder under work/src/; Wine patched with the chosen Hadron
#     patches and then ours (patches/*.patch),
#     GnuTLS with upstream commit 29c2027c
# Idempotent: a finished step is skipped; a tree whose inputs changed is unpacked again.
# Usage: fetch.sh [--dry-run]

source "$(dirname "$0")/env.sh"
DRY=; [[ "${1:-}" == --dry-run ]] && DRY=1
mkdir -p "$DOWNLOADS" "$SRC" "$WORK/toolchains"

fetch_file() {   # id file sha256 url...
    local id="$1" file="$2" want="$3"; shift 3
    local dir="$DOWNLOADS/$id" dest="$DOWNLOADS/$id/$file" seed cand url
    if [[ -f "$dest" && "$(sha256 "$dest")" == "$want" ]]; then return; fi
    [[ -n $DRY ]] && { echo "would fetch $file"; return; }
    mkdir -p "$dir"; rm -f "$dest" "$dest.partial"
    for seed in "${SEED_DIRS[@]}"; do
        [[ -d "$seed" ]] || continue
        while IFS= read -r cand; do
            if [[ "$(sha256 "$cand")" == "$want" ]]; then
                cp -c "$cand" "$dest" 2>/dev/null || cp "$cand" "$dest"
                log "$file: hash ok (copy of $cand)"; return
            fi
        done < <(find "$seed" -maxdepth 3 -type f -name "$file" 2>/dev/null)
    done
    for url in "$@"; do
        log "downloading $url"
        if curl -fsSL --retry 3 --connect-timeout 30 -o "$dest.partial" "$url"; then
            if [[ "$(sha256 "$dest.partial")" == "$want" ]]; then mv "$dest.partial" "$dest"; log "$file: hash ok"; return; fi
            echo "  SHA-256 $(sha256 "$dest.partial") is not the pin $want; trying the next address" >&2
        fi
        rm -f "$dest.partial"
    done
    die "no verified copy of $file"
}

while IFS=$'\t' read -r id file want _src urls; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    # shellcheck disable=SC2086
    fetch_file "$id" "$file" "$want" $urls
done < "$SPIKE/sources.tsv"

# Hadron's Wine patches (and their licence), each file pinned.
hadron_dir="$DOWNLOADS/hadron-$HADRON_REF"; mkdir -p "$hadron_dir"
while read -r want file; do
    dest="$hadron_dir/$file"
    [[ -f "$dest" && "$(sha256 "$dest")" == "$want" ]] && continue
    [[ -n $DRY ]] && { echo "would fetch hadron $file"; continue; }
    if [[ -f "$HADRON_SEED/patches/wine/$file" && "$(sha256 "$HADRON_SEED/patches/wine/$file")" == "$want" ]]; then
        cp "$HADRON_SEED/patches/wine/$file" "$dest"
    else
        curl -fsSL --retry 3 -o "$dest.partial" "https://raw.githubusercontent.com/Broyojo/hadron/$HADRON_REF/patches/wine/$file"
        mv "$dest.partial" "$dest"
    fi
    [[ "$(sha256 "$dest")" == "$want" ]] || { rm -f "$dest"; die "Hadron $file does not match patches.sha256"; }
done < "$SPIKE/patches.sha256"
[[ -n $DRY ]] || log "Hadron patches: $(grep -c '\.patch$' "$SPIKE/patches.sha256") files verified"
[[ -n $DRY ]] && exit 0

# The applied list must be exactly the "apply" rows of patches.conf, each pinned.
apply=$(awk '$2 == "apply" { printf "%s ", $1 }' "$SPIKE/patches.conf")
for n in $apply; do grep -q "  $n-" "$SPIKE/patches.sha256" || die "patch $n is marked apply but has no pin in patches.sha256"; done
pinned=$(sed -n 's/^[0-9a-f]*  \([0-9]\{4\}\)-.*/\1/p' "$SPIKE/patches.sha256" | tr '\n' ' ')
[[ "$pinned" == "$apply" ]] || die "patches.sha256 ($pinned) and patches.conf apply rows ($apply) differ"

# llvm-mingw.
if [[ "$(cat "$WORK/toolchains/llvm-mingw/.adp-source" 2>/dev/null)" != "$LLVM_MINGW_NAME" ]]; then
    log "unpacking $LLVM_MINGW_NAME"
    rm -rf "$WORK/toolchains/llvm-mingw" "$WORK/toolchains/unpack"; mkdir -p "$WORK/toolchains/unpack"
    tar -xJf "$DOWNLOADS/llvm-mingw/$LLVM_MINGW_NAME.tar.xz" -C "$WORK/toolchains/unpack"
    mv "$WORK/toolchains/unpack/$LLVM_MINGW_NAME" "$WORK/toolchains/llvm-mingw"; rmdir "$WORK/toolchains/unpack"
    echo "$LLVM_MINGW_NAME" > "$WORK/toolchains/llvm-mingw/.adp-source"
fi
lipo -archs "$MINGW/clang" | grep -qw arm64 || die "llvm-mingw's clang has no arm64 slice (it would need Rosetta)"
log "llvm-mingw: $("$MINGW/clang" --version | head -1)"

unpack() {   # id tarball-file dest-dir stamp [patch...]
    local id="$1" file="$2" dest="$3" stamp="$4" tmp top p; shift 4
    [[ -f "$dest/.adp-source" && "$(cat "$dest/.adp-source")" == "$stamp" ]] && { log "$(basename "$dest") ready"; return; }
    log "unpacking $file"
    rm -rf "$dest" "$dest.unpack"; tmp="$dest.unpack"; mkdir -p "$tmp"
    tar -xf "$DOWNLOADS/$id/$file" -C "$tmp"
    top=$(find "$tmp" -mindepth 1 -maxdepth 1)
    [[ $(printf '%s\n' "$top" | wc -l) -eq 1 && -d "$top" ]] || die "$file does not unpack to one folder"
    mv "$top" "$dest"; rmdir "$tmp"
    for p in "$@"; do
        patch -d "$dest" -p1 -F0 -N -s --no-backup-if-mismatch -i "$p" || die "$(basename "$p") does not apply to $(basename "$dest")"
    done
    echo "$stamp" > "$dest/.adp-source"
}

src_of() { awk -F'\t' -v i="$1" '$1 == i { print $2 }' "$SPIKE/sources.tsv"; }
for id in gmp nettle libtasn1 freetype; do
    f=$(src_of "$id"); unpack "$id" "$f" "$SRC/${f%.tar.*}" "$(sha256 "$DOWNLOADS/$id/$f")"
done
f=$(src_of gnutls); fix="$DOWNLOADS/gnutls-fix/$(src_of gnutls-fix)"
unpack gnutls "$f" "$SRC/${f%.tar.*}" "$(sha256 "$DOWNLOADS/gnutls/$f")+$(sha256 "$fix")" "$fix"

patches=()
for n in $apply; do patches+=("$hadron_dir/$(sed -n "s/^[0-9a-f]*  \($n-.*\)/\1/p" "$SPIKE/patches.sha256")"); done
# Then our own patches (patches/*.patch, in this repository, LGPL-2.1-or-later like Wine).
own=("$SPIKE"/patches/*.patch)
own_stamp=$(for f in "${own[@]}"; do sha256 "$f"; done | tr '\n' ' ')
unpack wine "$(src_of wine)" "$SRC/wine" "$WINE_COMMIT+${apply% }+${own_stamp% }" "${patches[@]}" "${own[@]}"
log "wine $(sed -n 's/^Wine version //p' "$SRC/wine/VERSION") at $WINE_COMMIT with Hadron patches ${apply% } and ${#own[@]} of ours"
log "done"
