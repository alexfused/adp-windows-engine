#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the macOS libraries Wine opens (FreeType for fonts, GnuTLS for schannel/bcrypt) and their
# dependencies from the source tarballs in ext.conf, natively for arm64, into work/ext-root.
#
#   gmp, nettle (+ hogweed), libtasn1, libunistring, libidn2, gnutls, libpng, freetype
#
# Settings chosen for the engine, not for a general-purpose install:
#   - prefix NEUTRAL_PREFIX (/nonexistent/adp-winehost) and make install DESTDIR=work/ext-root, so
#     every path a library compiles in (sysconfdir, the GnuTLS system priority file) names a folder
#     no user can create; the build copies' install names point into work/ext-root (so configure
#     tests can run them), and package.sh rewrites them all to @loader_path
#   - GnuTLS without p11-kit (no PKCS#11 module loading), without NLS (no gettext/libintl, no locale
#     paths), with no trust-store file (GnuTLS then uses the macOS keychain; Wine's crypt32 reads the
#     keychain itself anyway), without zlib/brotli/zstd certificate compression and TPM (each of those
#     is dlopen()ed by bare name), without tools, docs, tests, DANE and heartbeat
#   - FreeType with libpng (colour bitmap glyphs), the system's zlib and bzip2, no HarfBuzz/Brotli
#   - -ffile-prefix-map so no /Users build path ends up in __FILE__ strings or debug info
#   - only this folder's pkg-config files are visible (PKG_CONFIG_LIBDIR), and PATH has no Homebrew
#     bin folder, so configure cannot pick up a Homebrew library or *-config script
#   - GMP and Nettle (its library tests) run their own test suites; libpng runs "make test"
# Each library is rebuilt when its recipe (the configure line) changes, and so is every library
# after it. Records versions, hashes and configure lines in work/ext-root/BUILD-RECORD.tsv for
# package.sh's SOURCES.md.
# Usage: build-ext.sh [--force]

source "$(dirname "$0")/env.sh"
force=; [[ "${1:-}" == --force ]] && force=1
NP="$NEUTRAL_PREFIX"
export MACOSX_DEPLOYMENT_TARGET=27.0          # same as Wine's binaries (minos 27.0)
export CC=/usr/bin/clang CXX=/usr/bin/clang++
export CFLAGS="-O2 -g $PREFIX_MAP" CXXFLAGS="-O2 -g $PREFIX_MAP"
export CPPFLAGS="-I$EXT/include" LDFLAGS="-L$EXT/lib -Wl,-headerpad_max_install_names"
export PKG_CONFIG="$BREW/bin/pkg-config" PKG_CONFIG_LIBDIR="$EXT_PKG_CONFIG_LIBDIR" PKG_CONFIG_SYSROOT_DIR="$EXT_ROOT"
unset PKG_CONFIG_PATH
# macOS's zlib and bzip2 (libpng's and FreeType's .pc files require them) have no .pc file of
# their own outside Homebrew; these name the SDK's versions and link the system libraries.
SDK=$(xcrun --show-sdk-path)
mkdir -p "$WORK/ext-sys-pkgconfig"
printf 'Name: zlib\nDescription: macOS zlib\nVersion: %s\nLibs: -lz\nCflags:\n' \
    "$(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$SDK/usr/include/zlib.h")" > "$WORK/ext-sys-pkgconfig/zlib.pc"
printf 'Name: bzip2\nDescription: macOS libbz2\nVersion: 1.0.8\nLibs: -lbz2\nCflags:\n' > "$WORK/ext-sys-pkgconfig/bzip2.pc"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
BUILD=aarch64-apple-darwin$(uname -r | cut -d. -f1)
mkdir -p "$EXT_SRC" "$EXT/lib/pkgconfig"

conf() { awk -F'\t' -v n="$1" '$1 == n { print $'"$2"' }' "$SPIKE/ext.conf"; }

# The libraries' install names are under the neutral prefix, which does not exist, so configure's
# test programs (and the next library's) could not run against them. Point the build copies in
# work/ext-root at where they really are; package.sh rewrites every one of these names to
# @loader_path when it copies the libraries into the engine.
relink_build_copies() {
    local f dep id
    for f in "$EXT"/lib/*.dylib; do
        [[ -L "$f" ]] && continue
        id=$(otool -D "$f" | tail -1)   # keeps the library's own soname (libnettle.9.dylib, not .9.0)
        case "$id" in "$NP"/lib/*) install_name_tool -id "$EXT/lib/${id##*/}" "$f" 2>/dev/null ;; esac
        for dep in $(otool -L "$f" | tail -n +2 | awk '{print $1}'); do
            case "$dep" in "$NP"/lib/*) install_name_tool -change "$dep" "$EXT/lib/${dep##*/}" "$f" 2>/dev/null ;; esac
        done
        codesign --force --sign - "$f" 2>/dev/null   # install_name_tool voids the linker's ad hoc signature
    done
}

dirty=$force
record="$EXT_ROOT/BUILD-RECORD.tsv"
build() {   # name configure-args...
    local name="$1" version file tarball dir stamp want; shift
    version=$(conf "$name" 2); file=$(conf "$name" 3)
    tarball="$DOWNLOADS/ext/$name/$file"
    [[ -f "$tarball" ]] || die "missing $tarball: run fetch.sh"
    [[ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" == "$(conf "$name" 4)" ]] || die "$file: SHA-256 differs from ext.conf"
    dir="$EXT_SRC/$name-$version"; stamp="$dir/.adp-built"
    want="$(printf '%q ' "$@") CFLAGS=$CFLAGS MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
    if [[ -z $dirty && -f "$stamp" && "$(cat "$stamp")" == "$want" ]]; then
        log "$name $version already built"; return
    fi
    dirty=1
    log "building $name $version"
    rm -rf "$dir"; tar -xf "$tarball" -C "$EXT_SRC"
    [[ -d "$dir" ]] || die "$file did not unpack to $dir"
    if [[ $name == gnutls ]]; then
        # Upstream GnuTLS commit 29c2027c (Homebrew applies it to 3.8.13 too): a header fix for
        # compilers that know __has_c_attribute but not [[__maybe_unused__]] in C.
        patch -d "$dir" -p1 -s < "$DOWNLOADS/ext/gnutls-patch/$(conf gnutls-patch 3)" || die "the GnuTLS patch did not apply"
    fi
    local t0; t0=$(date +%s)
    ( cd "$dir" && ./configure --prefix="$NP" --build="$BUILD" --host="$BUILD" --disable-static --enable-shared "$@" ) \
        > "$dir/adp-configure.log" 2>&1 || { tail -30 "$dir/adp-configure.log"; die "$name: configure failed"; }
    make -C "$dir" -j"$JOBS" > "$dir/adp-make.log" 2>&1 || { grep -E 'error' "$dir/adp-make.log" | tail -20; die "$name: make failed"; }
    case $name in
        gmp)        make -C "$dir" -j"$JOBS" check > "$dir/adp-check.log" 2>&1 || { tail -30 "$dir/adp-check.log"; die "gmp: make check failed"; }
                    log "gmp: make check passed ($(grep -c -E '^PASS' "$dir/adp-check.log" || true) PASS lines)" ;;
        nettle)     # The library's test suite; the tests of Nettle's command-line tools (not shipped)
                    # cannot run, as those binaries look for libnettle at the neutral install name.
                    make -C "$dir/testsuite" check > "$dir/adp-check.log" 2>&1 || { tail -30 "$dir/adp-check.log"; die "nettle: make check failed"; }
                    log "nettle: $(grep -E '^All [0-9]+ tests passed' "$dir/adp-check.log")" ;;
        libpng)     make -C "$dir" test > "$dir/adp-check.log" 2>&1 || { tail -30 "$dir/adp-check.log"; die "libpng: make test failed"; }
                    log "libpng: make test passed" ;;
    esac
    make -C "$dir" install DESTDIR="$EXT_ROOT" > "$dir/adp-install.log" 2>&1 || { tail -20 "$dir/adp-install.log"; die "$name: make install failed"; }
    # libtool archives name the neutral prefix; the next library would look for them there.
    find "$EXT/lib" -name '*.la' -delete
    relink_build_copies
    log "$name built in $(( $(date +%s) - t0 )) s"
    echo "$want" > "$stamp"
}

relink_build_copies   # copies left by an earlier run
build gmp --with-pic --disable-cxx
build nettle --disable-documentation --disable-openssl --enable-fat
build libtasn1 --disable-doc --disable-valgrind-tests
# macOS's iconv fails gnulib's conformance probe since macOS 14; Homebrew sets the same answer.
export am_cv_func_iconv_works=yes
build libunistring
unset am_cv_func_iconv_works
build libidn2 --disable-nls --disable-doc --without-libintl-prefix --with-libunistring-prefix="$EXT"
build gnutls --disable-nls --without-p11-kit --with-default-trust-store-file= \
    --without-zlib --without-brotli --without-zstd --without-tpm --without-tpm2 \
    --disable-tools --disable-doc --disable-manpages --disable-tests --disable-libdane \
    --disable-heartbeat-support
build libpng --disable-tools
build freetype --without-harfbuzz --without-brotli --with-png=yes --with-zlib=yes --with-bzip2=yes \
    --enable-freetype-config=no

# What came out: every dylib arm64 only, two-level namespace, linking only each other and the OS.
log "checking $EXT/lib"
bad=0
for f in "$EXT"/lib/*.dylib; do
    [[ -L "$f" ]] && continue
    [[ "$(lipo -archs "$f")" == arm64 ]] || { echo "not arm64-only: $f"; bad=1; }
    otool -hv "$f" | grep -q TWOLEVEL || { echo "flat namespace: $f"; bad=1; }
    otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        case "$dep" in
            "$EXT"/lib/*|/usr/lib/*|/System/Library/*) ;;
            *) echo "$(basename "$f"): unexpected dependency $dep"; exit 1 ;;
        esac
    done || bad=1
done
[[ $bad == 0 ]] || die "lib/ext check failed"
{
    printf 'name\tversion\tfile\tsha256\turl\tconfigure\n'
    for name in gmp nettle libtasn1 libunistring libidn2 gnutls gnutls-patch libpng freetype; do
        v=$(conf "$name" 2); d="$EXT_SRC/$name-$v"
        args=$([[ -f "$d/.adp-built" ]] && sed 's/ CFLAGS=.*//' "$d/.adp-built" || echo "(patch, applied to gnutls)")
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$v" "$(conf "$name" 3)" "$(conf "$name" 4)" \
            "$(cat "$DOWNLOADS/ext/$name/SOURCE-URL")" "--prefix=$NP --build=$BUILD --host=$BUILD --disable-static --enable-shared $args"
    done
} > "$record"
for f in "$EXT"/lib/*.dylib; do [[ -L "$f" ]] || printf '  %-28s %s\n' "$(basename "$f")" "$(otool -L "$f" | tail -n +3 | awk '{print $1}' | xargs -n1 basename | tr '\n' ' ')"; done
log "done: $(ls "$EXT"/lib/*.dylib | wc -l | tr -d ' ') dylib names in $EXT/lib"
