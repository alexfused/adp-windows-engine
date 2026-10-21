#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Turn the installed build (dist/engine-root) into the engine we ship: dist/stage/<ENGINE_NAME>/
#
#   bin/wine        -> ../lib/wine/aarch64-unix/WineHost.app/Contents/MacOS/wine
#   bin/wineserver     (plain executable: never runs Windows code, needs no entitlement)
#   lib/ext/           FreeType, GnuTLS and the libraries they link, from build-ext.sh, relinked
#   lib/wine/aarch64-unix/WineHost.app   the Wine loader as the MAIN executable of a helper app with
#                      its own App ID (BUNDLE_ID, com.alexparkin.adpmonitor.winehost) and that App
#                      ID's Developer ID provisioning profile
#   lib/wine/aarch64-unix/wine -> WineHost.app/Contents/MacOS/wine   (ntdll execs this for children)
#   lib/wine/{aarch64,i386}-windows/   Wine's PE DLLs and FEX (xtajit.dll, xtajit64.dll)
#   share/wine/        fonts, NLS, wine.inf
#   licenses/          every licence and notice the components ask for, and SOURCES.md: where each
#                      component came from and exactly how this engine changed it
#
# Signing. WineHost.app: Developer ID, hardened runtime, secure timestamp, identifier BUNDLE_ID, the
# profile's application-identifier, team-identifier and cross-architecture-support plus the
# hardened-runtime exceptions in $ENTITLEMENTS (default entitlements/winehost.plist), and nothing
# else: package.sh stops if the signed set differs from that list. Every other Mach-O: Developer ID,
# hardened runtime, secure timestamp, identifier "<BUNDLE_ID>.<file name>", no entitlements.
# Neither may ever carry ADP Monitor's own identifier (helper-check.sh proves the root helper
# refuses all of them).
#
# Gates (the script stops): a load command pointing outside the engine and the OS, a Mach-O that
# is not arm64-only, an absolute path into a user-writable or package-manager folder in any Mach-O
# or PE file that tools/path-scan.allow does not explain (tools/path-scan.py; the report goes to
# evidence/<engine>/path-scan.txt), a licence text missing from its source tree, third-party code
# in FEX's tree without its notice in licenses/ (tools/fex-notices.py and tools/fex-notices.tsv; the
# report goes to evidence/<engine>/fex-notices.txt).
#
# Usage: package.sh [--entitlements FILE] [--out DIR] [--no-timestamp]
#        package.sh --licences-only [--out DIR]
# Rerunnable: the stage is rebuilt from dist/engine-root each time (APFS clone, so cheap).
# --licences-only rewrites only licenses/ of the stage that is already there (same sources, same
# SOURCES.md build lines) and leaves every other file alone: nothing is copied, stripped or signed, so
# the signatures and WineHost.app's stapled ticket stay valid. For adding a notice to an engine that is
# already notarised; archive.sh then repacks it and checks every signature and the ticket again.

source "$(dirname "$0")/env.sh"
ENTITLEMENTS="$SPIKE/entitlements/winehost.plist"
OUT=""; TS=(--timestamp); LICENCES_ONLY=
while (($#)); do
    case $1 in
        --entitlements) ENTITLEMENTS="$2"; shift ;;
        --out) OUT="$2"; shift ;;
        --no-timestamp) TS=(--timestamp=none) ;;
        --licences-only) LICENCES_ONLY=1 ;;
        *) die "unknown option $1" ;;
    esac; shift
done

[[ -x "$ENGINE/bin/wineserver" ]] || die "no build in $ENGINE: run build-wine.sh and build-fex.sh"
[[ -f "$ENGINE/lib/wine/aarch64-windows/libarm64ecfex.dll" ]] || die "FEX not installed in $ENGINE: run build-fex.sh"
[[ -f "$EXT_ROOT/BUILD-RECORD.tsv" ]] || die "no lib/ext build: run build-ext.sh"
[[ -n "$LICENCES_ONLY" || -f "$PROFILE" ]] || die "missing provisioning profile $PROFILE"
[[ -n "$LICENCES_ONLY" || -f "$ENTITLEMENTS" ]] || die "missing $ENTITLEMENTS"

WINE_VERSION=$(sed -n 's/^Wine version //p' "$WINE_SRC/VERSION")
ENGINE_NAME="engine-arm64-$WINE_VERSION-$ENGINE_REV"
OUT="${OUT:-$DIST/stage/$ENGINE_NAME}"
EVIDENCE="$SPIKE/evidence/$ENGINE_NAME"
UNIX="$OUT/lib/wine/aarch64-unix"
APP="$UNIX/WineHost.app"
OUTEXT="$OUT/lib/ext"
LIC="$OUT/licenses"
mkdir -p "$EVIDENCE" "$WORK/logs"
# Only a build needs these (removed below, and listed in SOURCES.md): headers, import libraries, man
# pages, Wine's build tools, FEX's offline compilers and Steam/Linux-thunk configuration.
removed=(include share/man share/applications share/fex-emu share/FEX)
build_tools=(function_grep.pl widl winebuild winecpp winedump winegcc wineg++ winemaker wmc wrc FEXOfflineCompiler32.exe FEXOfflineCompiler64.exe)
BUILD_LINES="Built from source on $(date -u +%Y-%m-%d) on macOS $(sw_vers -productVersion) (arm64, no Rosetta) by
\`spikes/windows-engine-arm64\` in ADP Monitor: \`fetch.sh\`, \`build-ext.sh\`, \`build-wine.sh\`, \`build-fex.sh\`, \`package.sh\`.
Compilers: $(/usr/bin/clang --version | head -1) (macOS code), $("$BREW/opt/llvm/bin/clang" --version | head -1) (Wine's PE code),
llvm-mingw $LLVM_MINGW_VERSION (FEX's PE code). Every compiler ran natively on arm64."

# ---------------------------------------------------------------- licences
# write_licences: fills $LIC from the source trees: every licence and notice text, SOURCES.md (from
# $BUILD_LINES, bundled, removed and build_tools) and README.md. Then tools/fex-notices.py checks that every
# third-party file the FEX builds compiled has its notice there. Changes nothing outside $LIC.
write_licences() {
log "collecting licences"
mkdir -p "$LIC"
lic_index=()
put() {   # dest(relative to licenses/) source [header|block]
    # header: only the file's leading comment; block: only its first comment block (up to the first
    # blank line), for a file whose licence comment is followed by other comments
    local dest="$1" src="$2" mode="${3:-}"
    [[ -f "$src" ]] || die "licence text missing: $src"
    mkdir -p "$(dirname "$LIC/$dest")"
    if [[ $mode == header || $mode == block ]]; then
        python3 -I - "$src" "$LIC/$dest" "$mode" <<'PY'
import sys
import re
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().replace("\r\n", "\n").split("\n")
out, block = [], False
for l in lines:
    s = l.strip()
    if re.match(r'# [0-9]+ "', s):   # a preprocessor line marker: the comment is over
        break
    if s == "" and sys.argv[3] == "block" and out and not block:   # the first comment block is over
        break
    if block:
        out.append(l); block = "*/" not in s; continue
    if s.startswith("/*"):
        out.append(l); block = "*/" not in s[2:]; continue
    if s == "" or (s.startswith(("#", "//", ";", "@")) and not s.startswith(("#include", "#if", "#define", "#pragma", "#undef", "#else", "#endif"))):
        out.append(l); continue
    break
text = "\n".join(out).strip("\n") + "\n"
if "opyright" not in text and "icense" not in text:
    sys.exit("no licence header in " + sys.argv[1])
open(sys.argv[2], "w").write(text)
PY
    else
        cp "$src" "$LIC/$dest"
    fi
    lic_index+=("$dest	${src#"$WORK"/}${mode:+ (leading comment)}")
}
put wine/LICENSE "$WINE_SRC/LICENSE"; put wine/COPYING.LIB "$WINE_SRC/COPYING.LIB"
put wine/AUTHORS "$WINE_SRC/AUTHORS"; put wine/NOTICES.md "$WINE_SRC/NOTICES.md"
put wine/libs-gsm-COPYRIGHT "$WINE_SRC/libs/gsm/COPYRIGHT"; put wine/libs-faudio-LICENSE "$WINE_SRC/libs/faudio/LICENSE"
put hadron/LICENSE "$HADRON/LICENSE"; put hadron/LICENSE.hadron "$HADRON/LICENSE.hadron"
put hadron/patches-wine-LICENSE "$HADRON/patches/wine/LICENSE"
put hadron/patches-wine-COPYING.LIB "$HADRON/patches/wine/COPYING.LIB"
put hadron/patches-fex-LICENSE "$HADRON/patches/fex/LICENSE"
put fex/LICENSE "$FEX_SRC/LICENSE"
put fex/SoftFloat-3e-NOTICE "$FEX_SRC/External/SoftFloat-3e/src/extF80_add.c" header
for sub in External/cephes:LICENSE External/fmt:LICENSE External/xxhash:LICENSE External/tiny-json:LICENSE \
           External/unordered_dense:LICENSE External/rpmalloc:LICENSE External/range-v3:LICENSE.txt \
           Source/Common/cpp-optparse:LICENSE; do
    d=${sub%%:*}; f=${sub#*:}
    put "fex/$(basename "$d")-$f" "$FEX_SRC/$d/$f"
done
# Third-party code in FEX's own tree (tools/fex-notices.tsv): VIXL's functions in the code emitter (the
# licence is the file's first comment block), and musl's routines in FEX's Windows runtime, whose files
# carry only SPDX lines: musl's own COPYRIGHT file is the text, from Wine's copy of musl.
put fex/VIXL-NOTICE "$FEX_SRC/CodeEmitter/CodeEmitter/VixlUtils.inl" block
put fex/Musl-COPYRIGHT "$WINE_SRC/libs/musl/COPYRIGHT"
put llvm-mingw/LICENSE.TXT "$WORK/toolchains/llvm-mingw/LICENSE.TXT"
src_of() { echo "$EXT_SRC/$1-$(awk -F'\t' -v n="$1" '$1 == n {print $2}' "$SPIKE/ext.conf")"; }
FT=$(src_of freetype)
for f in LICENSE.TXT docs/FTL.TXT docs/GPLv2.TXT src/bdf/README src/pcf/README; do put "freetype/${f//\//-}" "$FT/$f"; done
put freetype/src-gzip-zlib.h-NOTICE "$FT/src/gzip/zlib.h" header
put freetype/src-autofit-ft-hb-ft.c-NOTICE "$FT/src/autofit/ft-hb-ft.c" header
put libpng/LICENSE "$(src_of libpng)/LICENSE"
GT=$(src_of gnutls)
put gnutls/COPYING.LESSERv2 "$GT/COPYING.LESSERv2"; put gnutls/README.md "$GT/README.md"
put gnutls/lib-inih-LICENSE.txt "$GT/lib/inih/LICENSE.txt"
put gnutls/lib-accelerated-aarch64-CRYPTOGAMS-NOTICE "$GT/lib/accelerated/aarch64/macosx/ghash-aarch64.s" header
put gnutls/lib-accelerated-x86-license.txt "$GT/lib/accelerated/x86/license.txt"
for f in COPYING.LESSERv3 COPYINGv3 COPYINGv2; do put "nettle/$f" "$(src_of nettle)/$f"; put "gmp/$f" "$(src_of gmp)/$f"; done
put libtasn1/COPYING.LESSERv2 "$(src_of libtasn1)/COPYING.LESSERv2"
for f in COPYING.LESSERv3 COPYING COPYINGv2 COPYING.unicode; do put "libidn2/$f" "$(src_of libidn2)/$f"; done
for f in COPYING.LIB COPYING; do put "libunistring/$f" "$(src_of libunistring)/$f"; done

# ---------------------------------------------------------------- SOURCES.md
wine_ref=$(cut -d@ -f2 "$WINE_SRC/.adp-patches"); wine_patches=$(cut -d@ -f1 "$WINE_SRC/.adp-patches" | xargs)
fex_ref=$(cut -d@ -f2 "$FEX_SRC/.adp-patches"); fex_patches=$(cut -d@ -f1 "$FEX_SRC/.adp-patches" | xargs)
wine_head=$(git -C "$WINE_SRC" rev-parse HEAD); fex_head=$(git -C "$FEX_SRC" rev-parse HEAD)
wine_describe=$(git -C "$WINE_SRC" describe --tags 2>/dev/null || echo "$wine_head")
sonames=$(for f in "$WINE_BUILD"/.soname-*; do l=${f##*.soname-}; printf '`SONAME_LIB%s` %s -> `%s`; ' "$l" "$(sed "s|$WORK|<work>|" "$f")" "$(sed -n "s/^#define SONAME_LIB$l \"\(.*\)\"/\1/p" "$WINE_BUILD/include/config.h")"; done | sed 's/; $//')
ext_licence() {
    case $1 in
        gmp) echo "LGPL-3.0-or-later (chosen) OR GPL-2.0-or-later: gmp/COPYING.LESSERv3 with gmp/COPYINGv3, gmp/COPYINGv2" ;;
        nettle) echo "LGPL-3.0-or-later (chosen) OR GPL-2.0-or-later: nettle/COPYING.LESSERv3 with nettle/COPYINGv3, nettle/COPYINGv2" ;;
        libtasn1) echo "LGPL-2.1-or-later: libtasn1/COPYING.LESSERv2" ;;
        libunistring) echo "LGPL-3.0-or-later (chosen) OR GPL-2.0: libunistring/COPYING.LIB with libunistring/COPYING" ;;
        libidn2) echo "LGPL-3.0-or-later (chosen) OR GPL-2.0-or-later, Unicode data under the Unicode licence: libidn2/COPYING.LESSERv3 with libidn2/COPYING, libidn2/COPYINGv2, libidn2/COPYING.unicode" ;;
        gnutls) echo "LGPL-2.1-or-later (gnutls/COPYING.LESSERv2); bundled inih BSD-3-Clause (gnutls/lib-inih-LICENSE.txt); Arm assembly under the CRYPTOGAMS licence (gnutls/lib-accelerated-*)" ;;
        libpng) echo "libpng-2.0: libpng/LICENSE" ;;
        freetype) echo "FTL (chosen; also offered under GPL-2.0-or-later): freetype/LICENSE.TXT, freetype/docs-FTL.TXT, the notices in freetype/" ;;
    esac
}
ext_file_of() {   # name -> the lib/ext files that come from it
    case $1 in
        nettle) printf '%s\n' "${bundled[@]}" | grep -E '^lib(nettle|hogweed)\.' | tr '\n' ' ' ;;
        *) printf '%s\n' "${bundled[@]}" | grep -E "^lib${1#lib}[0-9.]*\.dylib$" | tr '\n' ' ' ;;
    esac
}
{
    echo "# Sources of $ENGINE_NAME"
    echo
    echo "$BUILD_LINES"
    echo "Install prefix compiled in: \`$NEUTRAL_PREFIX\` (does not exist and cannot be created without root; the engine"
    echo "finds its files relative to its own binaries). Build paths were mapped with \`$(sed "s|$WORK|<work>|" <<< "$PREFIX_MAP")\`."
    echo
    echo "## Wine, FEX and Hadron's patches"
    echo
    echo "| Component | Licence | Source | How this engine changes it |"
    echo "|---|---|---|---|"
    echo "| Wine $WINE_VERSION (\`$wine_describe\`) | LGPL-2.1-or-later (wine/COPYING.LIB, wine/LICENSE; bundled libraries: wine/NOTICES.md, wine/libs-*) | https://gitlab.winehq.org/wine/wine.git at \`$wine_ref\` | Hadron's Wine patches $wine_patches applied with \`git am\` (patched HEAD \`$wine_head\`). Configured \`$(sed -e "s|$WORK|<work>|g" -e "s|$BREW|\$BREW|g" "$WINE_BUILD/.adp-configure")\`. After configure, \`include/config.h\` library names: $sonames. Installed with DESTDIR; removed: ${removed[*]}, the build tools ${build_tools[*]}, static libraries. PE files: \`llvm-strip --strip-debug\`. Mach-O files: \`strip -S -x\`, signed (below). The loader \`lib/wine/aarch64-unix/wine\` moved to \`WineHost.app/Contents/MacOS/wine\`, with symlinks at its old place and at \`bin/wine\`. |"
    echo "| FEX | MIT (fex/LICENSE); third-party code compiled in: fex/SoftFloat-3e-NOTICE, fex/cephes-LICENSE, fex/fmt-LICENSE, fex/xxhash-LICENSE, fex/tiny-json-LICENSE, fex/unordered_dense-LICENSE, fex/rpmalloc-LICENSE, fex/range-v3-LICENSE.txt, fex/cpp-optparse-LICENSE, fex/VIXL-NOTICE (functions from VIXL in FEX's code emitter, \`CodeEmitter/CodeEmitter/VixlUtils.inl\`, BSD-3-Clause; the VIXL library itself is not compiled), fex/Musl-COPYRIGHT (musl routines in FEX's Windows runtime, \`Source/Windows/Common/CRT/Musl\`, MIT; those files carry only SPDX lines, so the text is musl's own COPYRIGHT file, taken from Wine's copy of musl); four Wine headers it compiles are LGPL-2.1-or-later (wine/COPYING.LIB); public domain, no notice needed: the SplitMix64 fallback in \`JIT.cpp\` and \`LoadConfig.S\`. \`package.sh\` checks every file of FEX's tree the build read against \`tools/fex-notices.tsv\` | https://github.com/FEX-Emu/FEX.git at \`$fex_ref\` with its submodules | Hadron's FEX patches $fex_patches applied with \`git am\` (patched HEAD \`$fex_head\`). Built with CMake (Release, no LTO, no assertions, \`CMAKE_INSTALL_PREFIX=$NEUTRAL_PREFIX\`, the prefix map above); the two PE DLLs with llvm-mingw, the macOS helpers with Apple clang. \`libwow64fex.dll\` and \`libarm64ecfex.dll\` are also installed as \`xtajit.dll\` and \`xtajit64.dll\` (copies). Debug info stripped and Mach-O files signed as for Wine. |"
    echo "| Hadron's patch queues | Wine patches LGPL-2.1-or-later (hadron/patches-wine-*), FEX patches MIT (hadron/patches-fex-LICENSE); Hadron itself BSD-3-Clause (hadron/LICENSE*) | $HADRON_URL at \`$HADRON_REF\`, \`patches/wine\`, \`patches/fex\` | Only the patches listed above; none of Hadron's code or binaries ship. |"
    echo "| llvm-mingw runtime (libc++, libc++abi, libunwind, compiler-rt builtins), statically linked into the two FEX DLLs | Apache-2.0 WITH LLVM-exception (llvm-mingw/LICENSE.TXT) | $LLVM_MINGW_URL, SHA-256 \`$LLVM_MINGW_SHA256\` | Not modified. |"
    echo
    echo "## Libraries in lib/ext"
    echo
    echo "Built by \`build-ext.sh\` from the official source tarballs, natively for arm64 (macOS 27.0 minimum), with"
    echo "\`CFLAGS=-O2 -g\` and the prefix map above, installed with DESTDIR under \`$NEUTRAL_PREFIX\`. Homebrew built none"
    echo "of them. Each was then changed the same way by \`package.sh\`: its install name and its references to the"
    echo "other lib/ext libraries rewritten to \`@loader_path/<file>\` (\`install_name_tool -id\` and \`-change\`), local"
    echo "symbols and debug information removed (\`strip -S -x\`), and signed with the Developer ID (identifier"
    echo "\`$BUNDLE_ID.<file>\`, hardened runtime). No other change unless the row says so."
    echo
    echo "| Library | lib/ext file | Licence | Source tarball and SHA-256 | Configure | Patches |"
    echo "|---|---|---|---|---|---|"
    tail -n +2 "$EXT_ROOT/BUILD-RECORD.tsv" | while IFS=$'\t' read -r name version file sha url args; do
        [[ $name == gnutls-patch ]] && continue
        patch="none"
        [[ $name == gnutls ]] && patch="upstream GnuTLS commit 29c2027c (\`lib/crau/crau.h\`, a build fix for \`[[__maybe_unused__]]\`; Homebrew applies the same), $(awk -F'\t' '$1 == "gnutls-patch" {print $5 ", SHA-256 `" $4 "`"}' "$EXT_ROOT/BUILD-RECORD.tsv")"
        [[ $name == libunistring ]] && patch="none; configure given \`am_cv_func_iconv_works=yes\` (macOS's iconv fails gnulib's conformance probe since macOS 14; Homebrew does the same)"
        echo "| $name $version | $(ext_file_of "$name") | $(ext_licence "$name") | $url, SHA-256 \`$sha\` | \`$(sed -e "s|$WORK|<work>|g" -e "s/ ''//" -e 's/ *$//' <<< "$args")\` | $patch |"
    done
    echo
    echo "Tests run during the build: GMP \`make check\`, Nettle's library test suite (\`testsuite/\`), libpng \`make test\`."
    echo
    echo "Not in this engine any more (engine-arm64-11.18-1 had them as Homebrew bottles): p11-kit (GnuTLS is built without"
    echo "PKCS#11, so it loads no PKCS#11 modules) and GNU gettext's libintl (GnuTLS and libidn2 are built without NLS)."
    echo "Linked from macOS itself, not shipped: zlib, bzip2, iconv, Security, CoreFoundation, CoreServices."
    echo
    echo "## Signing"
    echo
    echo "- \`lib/wine/aarch64-unix/WineHost.app\`: bundle id and signing identifier \`$BUNDLE_ID\`, Developer ID team $TEAM_ID,"
    echo "  hardened runtime, provisioning profile \`embedded.provisionprofile\` (Apple's, for that App ID; not open-source code)."
    echo "- Every other Mach-O file: Developer ID, hardened runtime, identifier \`$BUNDLE_ID.<file name>\`, no entitlements."
    echo "- The engine's own packaging (\`WineHost.app/Contents/Info.plist\`, \`ENGINE-NAME\`, this folder) and the scripts"
    echo "  that built it are MIT-licensed (ADP Monitor)."
} > "$LIC/SOURCES.md"
{
    echo "# Licence texts in this folder"
    echo
    echo "SOURCES.md lists every component, its licence, its source and how this engine changed it."
    echo
    echo "| File | Taken from |"
    echo "|---|---|"
    printf '%s\n' "${lic_index[@]}" | sort | awk -F'\t' '{printf "| %s | %s |\n", $1, $2}'
} > "$LIC/README.md"
log "licences: ${#lic_index[@]} texts in licenses/"
python3 -I "$SPIKE/tools/fex-notices.py" --src "$FEX_SRC" --licenses "$LIC" --table "$SPIKE/tools/fex-notices.tsv" \
    "$FEX_BUILD/fex-arm64ec" "$FEX_BUILD/fex-wow64" "$FEX_BUILD/fex-unixlib" > "$EVIDENCE/fex-notices.txt" \
    || { cat "$EVIDENCE/fex-notices.txt"; die "FEX notices: third-party code without its notice in licenses/"; }
tail -1 "$EVIDENCE/fex-notices.txt"
}

if [[ -n "$LICENCES_ONLY" ]]; then
    [[ "$(cat "$OUT/ENGINE-NAME" 2>/dev/null)" == "$ENGINE_NAME" && -f "$LIC/SOURCES.md" ]] \
        || die "--licences-only: no staged $ENGINE_NAME with a licenses/SOURCES.md at $OUT"
    # The stage's own build lines (when, on which macOS, with which compilers), not today's.
    BUILD_LINES=$(sed -n '/^Built from source on /,/Every compiler ran natively on arm64\.$/p' "$LIC/SOURCES.md")
    [[ $(wc -l <<< "$BUILD_LINES" | tr -d " ") == 4 ]] || die "--licences-only: cannot read the build lines of $LIC/SOURCES.md"
    # lib/ext's files in the order bundle() added them: FreeType's and GnuTLS's dependency trees.
    bundled=()
    walk_ext() {
        local name="$1" dep
        [[ " ${bundled[*]:-} " == *" $name "* ]] && return
        [[ -f "$OUTEXT/$name" ]] || die "--licences-only: lib/ext/$name is not in the stage"
        bundled+=("$name")
        for dep in $(otool -L "$OUTEXT/$name" | tail -n +3 | awk '{print $1}'); do
            case "$dep" in @loader_path/*) walk_ext "${dep#@loader_path/}" ;; esac
        done
    }
    for lib in FREETYPE GNUTLS; do walk_ext "$(basename "$(cat "$WINE_BUILD/.soname-$lib")")"; done
    [[ ${#bundled[@]} == $(ls "$OUTEXT" | wc -l | tr -d ' ') ]] || die "--licences-only: lib/ext holds files the walk did not find"
    staged="$LIC"; LIC="$WORK/licences-only/licenses"
    rm -rf "$LIC"; mkdir -p "$LIC"
    write_licences
    log "changes to $staged:"
    diff -rq "$staged" "$LIC" | sed -e "s|$staged/||g" -e "s|$LIC/||g" -e 's/^/    /' || true
    rm -rf "$staged"; cp -R "$LIC" "$staged"; rm -rf "$WORK/licences-only"
    log "done: licenses/ rewritten in $OUT; nothing else touched. Next: archive.sh"
    exit 0
fi

log "staging $OUT"
rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
cp -Rc "$ENGINE" "$OUT"
rm -rf "$OUT/include" "$OUT/share/man" "$OUT/share/applications" "$OUT/share/fex-emu" "$OUT/share/FEX"
find "$OUT/lib" -name '*.a' -delete
for t in "${build_tools[@]}"; do rm -f "$OUT/bin/$t"; done

# Debug info: PE files with llvm-strip --strip-debug, Mach-O with strip -S -x (below).
log "stripping debug information"
find "$OUT/lib/wine" -type f -path '*-windows/*' -print0 | xargs -0 -P "$JOBS" -n 64 "$BREW/opt/llvm/bin/llvm-strip" --strip-debug 2>/dev/null || true

is_macho() { [[ "$(head -c 4 "$1" | xxd -p)" =~ ^(cffaedfe|cafebabe|feedfacf)$ ]]; }
machos() { find "$OUT" -type f ! -path '*/WineHost.app/*' ! -path '*-windows/*' -print0 | while IFS= read -r -d '' f; do if is_macho "$f"; then echo "$f"; fi; done; }

# lib/ext: the libraries Wine opens by name (build-wine.sh pointed SONAME_LIBFREETYPE and
# SONAME_LIBGNUTLS at lib/ext) and everything they link, each relinked to find the others beside it.
mkdir -p "$OUTEXT"
bundled=()
bundle() {   # soname (leaf) in $EXT/lib
    local name="$1" dep
    [[ -e "$OUTEXT/$name" ]] && return
    [[ -e "$EXT/lib/$name" ]] || die "lib/ext: $name is not in $EXT/lib"
    cp "$(/bin/realpath "$EXT/lib/$name")" "$OUTEXT/$name"; chmod u+w "$OUTEXT/$name"
    bundled+=("$name")
    install_name_tool -id "@loader_path/$name" "$OUTEXT/$name" 2>/dev/null
    for dep in $(otool -L "$OUTEXT/$name" | tail -n +3 | awk '{print $1}'); do
        case "$dep" in
            "$EXT"/lib/*|"$NEUTRAL_PREFIX"/lib/*)
                install_name_tool -change "$dep" "@loader_path/${dep##*/}" "$OUTEXT/$name" 2>/dev/null
                bundle "${dep##*/}" ;;
        esac
    done
}
for lib in FREETYPE GNUTLS; do
    leaf=$(basename "$(cat "$WINE_BUILD/.soname-$lib")")
    grep -q "^#define SONAME_LIB$lib \"@loader_path/../../ext/$leaf\"" "$WINE_BUILD/include/config.h" \
        || die "Wine was not built to open lib/ext/$leaf (rerun build-wine.sh)"
    bundle "$leaf"
done
log "bundled ${#bundled[@]} libraries: ${bundled[*]}"

# The loader becomes WineHost.app's main executable.
log "making WineHost.app ($BUNDLE_ID)"
loader="$UNIX/wine"
[[ -f "$loader" && ! -L "$loader" ]] || die "no Wine loader at $loader"
mkdir -p "$APP/Contents/MacOS"
mv "$loader" "$APP/Contents/MacOS/wine"
ln -s WineHost.app/Contents/MacOS/wine "$UNIX/wine"
rm -f "$OUT/bin/wine"; ln -s ../lib/wine/aarch64-unix/WineHost.app/Contents/MacOS/wine "$OUT/bin/wine"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>wine</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>WineHost</string>
    <key>CFBundleDisplayName</key>
    <string>Windows program</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$WINE_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$WINE_VERSION.$ENGINE_REV</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>NSPrincipalClass</key>
    <string>WineApplication</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Wine (LGPL 2.1+) and FEX (MIT), built for ADP Monitor; sources in licenses/SOURCES.md</string>
</dict>
</plist>
EOF

write_licences

# ---------------------------------------------------------------- gates before signing
left=$(machos | while read -r f; do otool -L "$f" | tail -n +2 | awk -v f="${f#"$OUT"/}" '{print f ": " $1}'; done | grep -v -E ': (@loader_path/|@rpath/|/usr/lib/|/System/Library/)' || true)
left+=$(otool -L "$APP/Contents/MacOS/wine" | tail -n +2 | awk '{print "WineHost: " $1}' | grep -v -E ': (@loader_path/|@rpath/|/usr/lib/|/System/Library/)' || true)
[[ -z "$left" ]] || die "libraries linked from outside the engine and the OS:
$left"
rpaths=$( (machos; echo "$APP/Contents/MacOS/wine") | while read -r f; do otool -l "$f" | awk -v f="${f#"$OUT"/}" '/cmd LC_RPATH/ {r = 1} r && /path / {print f ": " $2; r = 0}'; done | grep -v -E ': @(loader|executable)_path' || true)
[[ -z "$rpaths" ]] || die "LC_RPATH outside the engine:
$rpaths"
nonarm=$( (machos; echo "$APP/Contents/MacOS/wine") | while read -r f; do a=$(lipo -archs "$f" 2>/dev/null); if [[ "$a" != arm64 ]]; then echo "$f: $a"; fi; done)
[[ -z "$nonarm" ]] || die "Mach-O that is not arm64-only (no x86_64 code may ship):
$nonarm"

# ---------------------------------------------------------------- signing
n=$(machos | wc -l | tr -d ' ')
log "signing $n Mach-O files with \"$IDENTITY\" (identifier $BUNDLE_ID.<file>)"
machos | while read -r f; do
    strip -S -x "$f" 2>/dev/null || true
    id="$BUNDLE_ID.$(basename "$f")"
    codesign --force --sign "$IDENTITY" "${TS[@]}" --options runtime --identifier "$id" "$f" >/dev/null 2>&1 \
        || codesign --force --sign "$IDENTITY" "${TS[@]}" --options runtime --identifier "$id" "$f"
done

# WineHost.app: the profile's three entitlements plus the hardened-runtime exceptions, exactly.
python3 -I - "$PROFILE" "$ENTITLEMENTS" "$WORK/winehost-entitlements.plist" "$BUNDLE_ID" "$TEAM_ID" <<'EOF'
import plistlib, subprocess, sys
profile = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", sys.argv[1]], capture_output=True, check=True).stdout)
granted = profile["Entitlements"]
bundle, team = sys.argv[4], sys.argv[5]
if granted.get("com.apple.application-identifier") != f"{team}.{bundle}":
    sys.exit("the profile is for %s, the bundle id is %s" % (granted.get("com.apple.application-identifier"), bundle))
if granted.get("com.apple.developer.cross-architecture-support") is not True:
    sys.exit("the profile does not grant cross-architecture support")
ents = {k: granted[k] for k in ("com.apple.application-identifier", "com.apple.developer.team-identifier",
                                "com.apple.developer.cross-architecture-support")}
extra = plistlib.load(open(sys.argv[2], "rb"))
for k in extra:
    if not k.startswith("com.apple.security.cs."):
        sys.exit(f"{sys.argv[2]}: {k} is not a hardened-runtime exception")
ents.update(extra)
plistlib.dump(ents, open(sys.argv[3], "wb"))
print("WineHost.app entitlements:", ", ".join(sorted(ents)))
EOF
strip -S -x "$APP/Contents/MacOS/wine" 2>/dev/null || true
codesign --force --sign "$IDENTITY" "${TS[@]}" --options runtime --identifier "$BUNDLE_ID" \
    --entitlements "$WORK/winehost-entitlements.plist" "$APP"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -1

# ---------------------------------------------------------------- checks after signing
python3 -I - "$APP" "$WORK/winehost-entitlements.plist" "$BUNDLE_ID" "$PROFILE" <<'EOF'
import plistlib, subprocess, sys
app, want_file, bundle, profile = sys.argv[1:]
got = plistlib.loads(subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", app], capture_output=True, check=True).stdout)
want = plistlib.load(open(want_file, "rb"))
if got != want:
    sys.exit(f"WineHost.app entitlements differ: signed {sorted(got)}, wanted {sorted(want)}")
if "keychain-access-groups" in got:
    sys.exit("WineHost.app must not claim keychain-access-groups")
info = subprocess.run(["codesign", "-dvv", app], capture_output=True, text=True).stderr
ident = [l.split("=", 1)[1] for l in info.splitlines() if l.startswith("Identifier=")][0]
if ident != bundle:
    sys.exit(f"WineHost.app signing identifier {ident}, wanted {bundle}")
plist = plistlib.load(open(app + "/Contents/Info.plist", "rb"))
if plist["CFBundleIdentifier"] != bundle:
    sys.exit("Info.plist CFBundleIdentifier differs")
if open(app + "/Contents/embedded.provisionprofile", "rb").read() != open(profile, "rb").read():
    sys.exit("embedded.provisionprofile is not the engine's profile")
print(f"WineHost.app: identifier {ident}, CFBundleIdentifier {plist['CFBundleIdentifier']}, profile embedded, entitlements exactly {', '.join(sorted(got))}")
EOF
machos | while read -r f; do
    codesign --verify --strict "$f" || die "bad signature: $f"
    info=$(codesign -dvv "$f" 2>&1)
    [[ "$(sed -n 's/^Identifier=//p' <<< "$info")" == "$BUNDLE_ID.$(basename "$f")" ]] || die "wrong identifier: $f"
    grep -q 'flags=0x10000(runtime)' <<< "$info" || die "no hardened runtime: $f"
    grep -q "^TeamIdentifier=$TEAM_ID" <<< "$info" || die "not team $TEAM_ID: $f"
    [[ -z "$(codesign -d --entitlements - --xml "$f" 2>/dev/null)" ]] || die "entitlements on $f"
done
log "every Mach-O: Developer ID ($TEAM_ID), hardened runtime, identifier $BUNDLE_ID.<file>, no entitlements"

echo "$ENGINE_NAME" > "$OUT/ENGINE-NAME"
log "scanning every Mach-O and PE file for paths into user-writable or package-manager folders"
python3 -I "$SPIKE/tools/path-scan.py" "$OUT" --allow "$SPIKE/tools/path-scan.allow" --tsv "$EVIDENCE/path-scan.tsv" \
    > "$EVIDENCE/path-scan.txt" || { cat "$EVIDENCE/path-scan.txt"; die "path scan: hits not explained by tools/path-scan.allow"; }
sed -i '' "s|$OUT|<stage>/$ENGINE_NAME|" "$EVIDENCE/path-scan.txt"
head -3 "$EVIDENCE/path-scan.txt"
log "done: $OUT ($(du -sh "$OUT" | cut -f1))"
