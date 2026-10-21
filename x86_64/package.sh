#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Turn the x86_64 build into the engine we ship: dist/stage/engine-x86_64-11.18-1/
#
#   bin/wine        -> ../lib/wine/x86_64-unix/wine   (the loader; it finds ntdll.so beside itself)
#   bin/wineserver     (never runs Windows code; no entitlements)
#   lib/ext/           FreeType, GnuTLS, Nettle, Hogweed, GMP, libtasn1 from build-deps.sh;
#                      install names rewritten to @loader_path/<file>
#   lib/wine/x86_64-unix/   the loader (wine) and Wine's unix modules (*.so)
#   lib/wine/x86_64-windows/, lib/wine/i386-windows/   Wine's PE DLLs and programs (WoW64)
#   share/wine/        fonts, NLS, wine.inf
#   licenses/          every licence and notice, SOURCES.md, the Wine patches applied
#
# Every Mach-O is signed with the Developer ID, the hardened runtime and a secure timestamp, with
# identifier com.alexparkin.adpmonitor.winehost (the loader) or com.alexparkin.adpmonitor.winehost.<file>
# (everything else): never ADP Monitor's com.alexparkin.adpmonitor. Only the loader has
# entitlements (entitlements/loader.plist). No provisioning profile and no keychain access group.
# Runs under env.sh's exec barrier: nothing in dist/ or the install trees can be started.
# Rerunnable: the stage is rebuilt from the install trees each time (APFS clones, so cheap).
# Usage: package.sh [--no-timestamp] [--entitlements FILE] [--out DIR]

source "$(dirname "$0")/env.sh"
if [[ -z "${ADP_IN_BARRIER:-}" ]]; then
    export ADP_IN_BARRIER=1
    exec /usr/bin/sandbox-exec -p "$SANDBOX_PROFILE" /bin/bash "$0" "$@"
fi
ENTITLEMENTS="$SPIKE/entitlements/loader.plist"
OUT="$STAGE"; TS=(--timestamp)
while (($#)); do
    case $1 in
        --no-timestamp) TS=(--timestamp=none) ;;
        --entitlements) ENTITLEMENTS="$2"; shift ;;
        --out) OUT="$2"; shift ;;
        *) die "unknown option $1" ;;
    esac; shift
done
W="$BUILD/wine"
UNIX_REL=lib/wine/x86_64-unix
[[ -f "$WINE_INSTALL/$UNIX_REL/ntdll.so" ]] || die "no Wine install in $WINE_INSTALL: run build-wine.sh"
[[ -f "$ENTITLEMENTS" ]] || die "missing $ENTITLEMENTS"
security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" || die "signing identity not found: $IDENTITY"
rosetta_guard_start package

log "staging $OUT"
rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
cp -Rc "$WINE_INSTALL" "$OUT"
# Only a build needs these: headers, import libraries, man pages, desktop files, Wine's build tools.
rm -rf "$OUT/include" "$OUT/share/man" "$OUT/share/applications"
find "$OUT/lib" -name '*.a' -delete
for t in function_grep.pl widl winebuild winecpp winedump winegcc wineg++ winemaker wmc wrc; do rm -f "$OUT/bin/$t"; done

# One loader: bin/wine is a link to the loader beside ntdll.so (as in the arm64 engine), so there is
# one entitled binary and child processes (started from lib/wine/x86_64-unix/wine) match it.
[[ -f "$OUT/$UNIX_REL/wine" && ! -L "$OUT/$UNIX_REL/wine" ]] || die "no loader at $UNIX_REL/wine"
rm -f "$OUT/bin/wine"; ln -s "../$UNIX_REL/wine" "$OUT/bin/wine"

is_macho() { [[ "$(head -c 4 "$1" | xxd -p)" =~ ^(cffaedfe|cafebabe|feedfacf|cefaedfe)$ ]]; }
machos() { find "$OUT" -type f ! -path '*-windows/*' -print0 | while IFS= read -r -d '' f; do if is_macho "$f"; then echo "$f"; fi; done; }

# lib/ext: the libraries Wine opens by name (build-wine.sh pointed those names here) and everything
# they link from our prefix, each relinked to find the others beside it.
EXT="$OUT/lib/ext"; mkdir -p "$EXT"
bundle() {   # leaf name of a library in $DEPS/lib
    local leaf="$1" dep d
    [[ -e "$EXT/$leaf" ]] && return
    [[ -f "$DEPS/lib/$leaf" ]] || die "missing $DEPS/lib/$leaf"
    cp "$(/bin/realpath "$DEPS/lib/$leaf")" "$EXT/$leaf"; chmod 644 "$EXT/$leaf"
    install_name_tool -id "@loader_path/$leaf" "$EXT/$leaf" 2>/dev/null
    for dep in $(otool -L "$EXT/$leaf" | tail -n +2 | awk '{print $1}'); do
        case "$dep" in
            "$PREFIX"/lib/*) d=$(basename "$dep")
                install_name_tool -change "$dep" "@loader_path/$d" "$EXT/$leaf" 2>/dev/null
                bundle "$d" ;;
        esac
    done
}
for lib in FREETYPE GNUTLS; do bundle "$(cat "$W/.soname-$lib")"; done
log "lib/ext: $(ls "$EXT" | tr '\n' ' ')"

log "stripping local and debug symbols from $(machos | wc -l | tr -d ' ') Mach-O files"
machos | while read -r f; do strip -S -x "$f" 2>/dev/null || true; done
# PE files: built without -g; drop any debug section a library brought in.
find "$OUT/lib/wine" -type f -path '*-windows/*' -print0 | xargs -0 -P "$JOBS" -n 64 "$MINGW/llvm-strip" --strip-debug 2>/dev/null || true

# ---- licences and sources ---------------------------------------------------------------------
L="$OUT/licenses"; mkdir -p "$L"
lic() { local dest="$L/$1"; shift; mkdir -p "$dest"; local f; for f in "$@"; do [[ -f "$f" ]] || die "licence file missing: $f"; cp "$f" "$dest/"; done; }
lic wine "$SRC/wine/COPYING.LIB" "$SRC/wine/LICENSE" "$SRC/wine/AUTHORS" "$SRC/wine/NOTICES.md"
# Every licence, copyright and authors file of the third-party code Wine builds in (libs/*), under its
# own name (listed, not globbed: APFS ignores case, so a glob can match one file under two names).
# libs/sqlite3 has none: SQLite is in the public domain.
for d in "$SRC"/wine/libs/*/; do
    n=$(basename "$d")
    files=(); while IFS= read -r f; do files+=("$d$f"); done < <(ls "$d" | grep -E -i '^(licen[cs]e|copying|copyright|authors|notice)')
    (( ${#files[@]} )) && lic "wine/libs/$n" "${files[@]}"
done
mkdir -p "$L/wine-patches/hadron" "$L/wine-patches/adp"
apply=$(awk '$2 == "apply" { print $1 }' "$SPIKE/patches.conf")
for n in $apply; do cp "$DOWNLOADS/hadron-$HADRON_REF/$(sed -n "s/^[0-9a-f]*  \($n-.*\)/\1/p" "$SPIKE/patches.sha256")" "$L/wine-patches/hadron/"; done
cp "$DOWNLOADS/hadron-$HADRON_REF/LICENSE" "$L/wine-patches/hadron/LICENSE"
cp "$DOWNLOADS/hadron-$HADRON_REF/COPYING.LIB" "$L/wine-patches/hadron/COPYING.LIB"
cp "$SPIKE"/patches/*.patch "$L/wine-patches/adp/"
G="$SRC/gnutls-3.8.13"
lic gnutls "$G/COPYING" "$G/COPYING.LESSERv2" "$G/AUTHORS" "$G/README.md"
# The libunistring and gnulib files built into libgnutls are "LGPLv3+ or GPLv2+"; we use them under
# LGPL-3.0, whose text (GPL-3.0 in COPYING plus these additional permissions) GnuTLS's tarball lacks.
# Nettle's tarball has the FSF text (the current one, with https links).
cp "$SRC/nettle-4.0/COPYING.LESSERv3" "$L/gnutls/COPYING.LESSERv3"
cp "$G/lib/accelerated/x86/license.txt" "$L/gnutls/CRYPTOGAMS-license.txt"
cp "$G/lib/inih/LICENSE.txt" "$L/gnutls/inih-LICENSE.txt"
cp "$G/lib/crau/LICENSE" "$L/gnutls/crau-LICENSE"
lic nettle "$SRC/nettle-4.0/COPYING.LESSERv3" "$SRC/nettle-4.0/COPYINGv2" "$SRC/nettle-4.0/COPYINGv3" "$SRC/nettle-4.0/AUTHORS"
lic gmp "$SRC/gmp-6.3.0/COPYING.LESSERv3" "$SRC/gmp-6.3.0/COPYINGv2" "$SRC/gmp-6.3.0/COPYINGv3" "$SRC/gmp-6.3.0/AUTHORS"
lic libtasn1 "$SRC/libtasn1-4.21.0/COPYING" "$SRC/libtasn1-4.21.0/COPYING.LESSERv2" "$SRC/libtasn1-4.21.0/AUTHORS"
F="$SRC/freetype-2.15.0"
lic freetype "$F/LICENSE.TXT" "$F/docs/FTL.TXT" "$F/docs/GPLv2.TXT"
cp "$F/src/bdf/README" "$L/freetype/bdf-README"; cp "$F/src/pcf/README" "$L/freetype/pcf-README"
cp "$SPIKE/LICENSE" "$L/build-scripts-LICENSE"

opts() {   # the configure options (and autoconf answers given) a build used, without paths
    tr ' ' '\n' | grep -E '^(--|ac_cv_)' | grep -v -E '^--(prefix|build|host|with-wine-tools)=' | tr '\n' ' '
}
sha() { awk -F'\t' -v i="$1" '$1 == i { print $3 }' "$SPIKE/sources.tsv"; }
url() { awk -F'\t' -v i="$1" '$1 == i { split($5, u, " "); print u[1] }' "$SPIKE/sources.tsv"; }
{
    echo "# Sources of $ENGINE_NAME"
    echo
    echo "Built from source on $(date -u +%Y-%m-%d) by the scripts in ADP Monitor's spikes/windows-engine-intel"
    echo "(MIT licence, build-scripts-LICENSE), cross-compiled on an Apple silicon Mac for x86_64 macOS $MACOS_MIN"
    echo "or later. Nothing below is an unmodified binary from a package manager: every library was compiled"
    echo "from the upstream tarball listed, with the changes listed. Install prefix compiled in: $PREFIX"
    echo "(it cannot exist on macOS; the engine finds its files relative to itself)."
    echo
    echo "| Component | Version | Licence | Source (SHA-256) | Changes |"
    echo "|---|---|---|---|---|"
    echo "| Wine | $WINE_VERSION (commit $WINE_COMMIT) | LGPL-2.1-or-later (wine/) | $(url wine) ($(sha wine)) | Hadron patches $(echo $apply | tr '\n' ' ') (wine-patches/hadron/, from $HADRON_URL at $HADRON_REF) and ours (wine-patches/adp/) |"
    echo "| GnuTLS | 3.8.13 | LGPL-2.1-or-later; included parts of libunistring and gnulib: LGPL-3.0-or-later or GPL-2.0-or-later; CRYPTOGAMS assembly: BSD-3-Clause; inih: BSD-3-Clause; crau: MIT (gnutls/) | $(url gnutls) ($(sha gnutls)) | upstream commit 29c2027c (a clang build fix, $(url gnutls-fix), $(sha gnutls-fix)) |"
    echo "| Nettle (with Hogweed) | 4.0 | LGPL-3.0-or-later or GPL-2.0-or-later (nettle/) | $(url nettle) ($(sha nettle)) | none |"
    echo "| GMP | 6.3.0 | LGPL-3.0-or-later or GPL-2.0-or-later (gmp/) | $(url gmp) ($(sha gmp)) | none |"
    echo "| libtasn1 | 4.21.0 | LGPL-2.1-or-later (libtasn1/) | $(url libtasn1) ($(sha libtasn1)) | none |"
    echo "| FreeType | 2.15.0 | FreeType License (FTL), chosen of FTL or GPL-2.0; BDF/PCF drivers: X11-style (freetype/) | $(url freetype) ($(sha freetype)) | none (the experimental HVF driver is left out: ac_cv_header_hvf_Scaler_h=no) |"
    echo
    echo "Portions of this software are copyright © 2026 The FreeType Project (https://freetype.org). All rights reserved."
    echo
    echo "## How each part was built"
    echo
    echo "Unix side: Xcode clang $("$CLANG" --version | head -1 | sed 's/.*version \([^ ]*\).*/\1/'), macOS SDK $(xcrun --sdk macosx --show-sdk-version), -arch x86_64 -mmacosx-version-min=$MACOS_MIN -O2."
    echo "Windows side (PE, i386 and x86_64): llvm-mingw $LLVM_MINGW_VERSION -O2. Every compile maps the build folder to adp-build/."
    echo
    for n in gmp nettle libtasn1 gnutls freetype; do
        echo "- $n: configure $(sed 's/^[^ ]* //' "$BUILD/deps-$n/.adp-built" | opts)"
    done
    echo "- wine: configure $(sed -n 's/^  \$ .*configure //p' "$W/config.log" | head -1 | opts)"
    echo
    echo "After the build: Wine's build tools, headers and import libraries removed; bin/wine made a link to"
    echo "lib/wine/x86_64-unix/wine; lib/ext's install names and references rewritten to @loader_path with"
    echo "install_name_tool; local and debug symbols stripped (strip -S -x; PE files llvm-strip --strip-debug);"
    echo "every Mach-O signed (Developer ID, hardened runtime). Wine opens FreeType and GnuTLS as"
    echo "@loader_path/../../ext/<file> (build-wine.sh sets this in Wine's config.h)."
    echo
    echo "To replace a library: build your own with the same configure options and install name"
    echo "(@loader_path/<file>), put it in lib/ext and sign it (an ad-hoc signature is enough: the loader"
    echo "is signed with com.apple.security.cs.disable-library-validation)."
} > "$L/SOURCES.md"
{
    echo "# Licences of $ENGINE_NAME"
    echo
    echo "Wine runs Windows programs on macOS. This engine is Wine $WINE_VERSION built from source for Intel Macs."
    echo "SOURCES.md lists every component, its version, source and changes; each folder here holds that"
    echo "component's licence texts and notices."
    echo
    echo "| Folder | Component | Licence |"
    echo "|---|---|---|"
    echo "| wine/ | Wine (and the third-party code in wine/NOTICES.md and wine/libs/) | LGPL-2.1-or-later |"
    echo "| wine-patches/ | The changes to Wine: Hadron's patches (hadron/LICENSE) and ours (adp/) | LGPL-2.1-or-later |"
    echo "| gnutls/ | GnuTLS 3.8.13 | LGPL-2.1-or-later (COPYING.LESSERv2); its libunistring and gnulib parts LGPL-3.0-or-later (COPYING.LESSERv3 with the GPL-3.0 text in COPYING); CRYPTOGAMS, inih, crau notices |"
    echo "| nettle/ | Nettle 4.0 | LGPL-3.0-or-later or GPL-2.0-or-later |"
    echo "| gmp/ | GMP 6.3.0 | LGPL-3.0-or-later or GPL-2.0-or-later |"
    echo "| libtasn1/ | libtasn1 4.21.0 | LGPL-2.1-or-later |"
    echo "| freetype/ | FreeType 2.15.0 | FreeType License (FTL.TXT) |"
    echo "| build-scripts-LICENSE | The build scripts | MIT |"
    echo
    echo "Portions of this software are copyright © 2026 The FreeType Project (https://freetype.org). All rights reserved."
    echo
    echo "The engine is signed by Alex Parkin (Developer ID, Team $TEAM_ID) for ADP Monitor. It is not affiliated"
    echo "with or endorsed by WineHQ, CodeWeavers, Hadron, the GNU project or the FreeType project."
} > "$L/README.md"

# ---- signing ----------------------------------------------------------------------------------
ident_for() {   # path relative to the engine root
    local b; b=$(basename "$1"); b="${b%.so}"; b="${b%.dylib}"
    if [[ "$1" == "$UNIX_REL/wine" ]]; then echo "$ID_PREFIX"; else echo "$ID_PREFIX.$b"; fi
}
nonx86=$(machos | while read -r f; do a=$(lipo -archs "$f" 2>/dev/null); [[ "$a" == x86_64 ]] || echo "${f#"$OUT"/}: $a"; done)
[[ -z "$nonx86" ]] || die "Mach-O that is not x86_64-only:
$nonx86"
outside=$(machos | while read -r f; do otool -L "$f" | tail -n +2 | awk -v f="${f#"$OUT"/}" '{print f ": " $1}'; done \
    | grep -v -E ': (/usr/lib/|/System/Library/|@loader_path/|@rpath/)' || true)
[[ -z "$outside" ]] || die "libraries linked from outside macOS and the engine:
$outside"

log "signing $(machos | wc -l | tr -d ' ') Mach-O files with \"$IDENTITY\""
machos | grep -v -x -F "$OUT/$UNIX_REL/wine" | while read -r f; do
    rel="${f#"$OUT"/}"
    codesign --force --sign "$IDENTITY" "${TS[@]}" --options runtime --identifier "$(ident_for "$rel")" "$f" >/dev/null 2>&1 \
        || codesign --force --sign "$IDENTITY" "${TS[@]}" --options runtime --identifier "$(ident_for "$rel")" "$f" \
        || die "codesign failed: $rel"
done
codesign --force --sign "$IDENTITY" "${TS[@]}" --options runtime --identifier "$ID_PREFIX" \
    --entitlements "$ENTITLEMENTS" "$OUT/$UNIX_REL/wine" || die "codesign failed: the loader"
machos | while read -r f; do codesign --verify --strict "$f" || die "bad signature: ${f#"$OUT"/}"; done
echo "$ENGINE_NAME" > "$OUT/ENGINE-NAME"
log "done: $OUT ($(du -sh "$OUT" | cut -f1), $(find "$OUT" -type f | wc -l | tr -d ' ') files)"
