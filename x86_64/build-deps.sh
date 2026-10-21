#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Cross-compile the libraries Wine opens, from the official tarballs fetch.sh verified, for x86_64
# macOS 12.3:
#   GMP 6.3.0 -> Nettle 4.0 (with Hogweed) -> libtasn1 4.21.0 -> GnuTLS 3.8.13 (TLS for schannel, bcrypt)
#   FreeType 2.15.0 (fonts)
# They are installed with DESTDIR under work/destdir-deps at the neutral prefix in env.sh.
# Also builds FreeType natively for arm64 into work/native-deps, for Wine's build tool sfnt2fon
# (it turns fonts into .fon files at build time; that copy is never shipped).
#
# Every configure gets --build and --host, so autoconf runs no test program; the generators GMP,
# Nettle and FreeType run at build time are compiled with the native CC_FOR_BUILD/CC_BUILD.
# GnuTLS is built without p11-kit, libidn2, gettext (NLS), zlib/brotli/zstd, DANE, TPM and its
# command-line tools, and with no system priority file or trust store file compiled in (on macOS
# it reads the system trust from the Keychain; Wine verifies certificates in crypt32 anyway).
# Rerunnable: a library whose stamp (source + configure line) matches is skipped.
# Usage: build-deps.sh [--rebuild]

source "$(dirname "$0")/env.sh"
[[ "${1:-}" == --rebuild ]] && rm -rf "$BUILD"/deps-* "$DEPS_DESTDIR" "$NATIVE_DEPS"
[[ -f "$SRC/gnutls-3.8.13/.adp-source" ]] || die "run fetch.sh first"
mkdir -p "$BUILD" "$DEPS_DESTDIR" "$NATIVE_DEPS"
rosetta_guard_start build-deps

export PKG_CONFIG="$PKG_CONFIG_BIN" PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$DEPS_DESTDIR"
[[ -x "$PKG_CONFIG" ]] || die "no pkg-config (Homebrew pkgconf) found; set PKG_CONFIG_BIN"

CROSS=(--build="$BUILD_TRIPLE" --host="$HOST_TRIPLE" --prefix="$PREFIX" --disable-static --enable-shared
       CC="$X86_CC" CFLAGS="$X86_CFLAGS" CPPFLAGS="-I$DEPS/include" LDFLAGS="$X86_LDFLAGS -L$DEPS/lib")

build() {   # name srcdir destdir configure-args...
    local name="$1" src="$2" dest="$3"; shift 3
    local dir="$BUILD/deps-$name" stamp run=x86_sandboxed g
    [[ "$dest" == native ]] && run=
    stamp="$(cat "$src/.adp-source") $* $(xcrun --sdk macosx --show-sdk-version)"
    if [[ -f "$dir/.adp-built" && "$(cat "$dir/.adp-built")" == "$stamp" ]]; then log "$name: up to date"; return; fi
    log "$name: configuring${run:+ (exec barrier on)}"
    rm -rf "$dir"; mkdir -p "$dir"
    (cd "$dir" && $run "$src/configure" "$@" > configure.out 2>&1) || { tail -30 "$dir/configure.out"; die "$name: configure failed ($dir/config.log)"; }
    if [[ "$dest" != native ]]; then
        grep -q 'whether we are cross compiling\.\.\. yes' "$dir/configure.out" || die "$name: configure did not run as a cross build"
        # Probes that try to run ./conftest anyway (gnulib's locale checks) are refused by the barrier
        # and come out as "none"; keep their answers as evidence.
        grep -E '^checking (for a .*locale|whether a program can dlopen itself)' "$dir/configure.out" > "$dir/probes.txt" || true
    fi
    log "$name: building"
    $run make -C "$dir" -j"$JOBS" > "$dir/make.out" 2>&1 || { grep -E 'error' "$dir/make.out" | tail -20; die "$name: make failed ($dir/make.out)"; }
    if [[ "$dest" == native ]]; then
        make -C "$dir" install > "$dir/install.out" 2>&1 || die "$name: make install failed"
    else
        # Build-time generators that did run (allowed by the barrier) must be native arm64.
        for g in "$dir"/gen-* "$dir/eccdata" "$dir/apinames" "$dir/objs/apinames"; do
            [[ -f "$g" && -x "$g" && "$g" != *.* ]] || continue
            [[ "$(lipo -archs "$g")" == arm64 ]] || die "$name: generator $g is not arm64"
        done
        $run make -C "$dir" install DESTDIR="$dest" > "$dir/install.out" 2>&1 || die "$name: make install failed"
        # libtool archives hold build paths and are never needed again; pkg-config files stay (build only).
        find "$dest$PREFIX/lib" -name '*.la' -delete
    fi
    echo "$stamp" > "$dir/.adp-built"
}

# arm64 FreeType for Wine's tools (sfnt2fon). Native: prefix in work/, never shipped.
build freetype-native "$SRC/freetype-2.15.0" native \
    --prefix="$NATIVE_DEPS" --disable-static --enable-shared CC="$NATIVE_CC" CFLAGS="-O2" \
    --without-harfbuzz --without-png --without-bzip2 --without-brotli --without-zlib

build gmp "$SRC/gmp-6.3.0" "$DEPS_DESTDIR" "${CROSS[@]}" CC_FOR_BUILD="$NATIVE_CC" --disable-cxx

build nettle "$SRC/nettle-4.0" "$DEPS_DESTDIR" "${CROSS[@]}" CC_FOR_BUILD="$NATIVE_CC" \
    --enable-fat --disable-documentation --disable-openssl

build libtasn1 "$SRC/libtasn1-4.21.0" "$DEPS_DESTDIR" "${CROSS[@]}" --disable-doc --disable-valgrind-tests

build gnutls "$SRC/gnutls-3.8.13" "$DEPS_DESTDIR" "${CROSS[@]}" \
    --disable-doc --disable-manpages --disable-tools --disable-tests --disable-cxx --disable-nls \
    --disable-libdane --disable-valgrind-tests --disable-full-test-suite --disable-maintainer-mode \
    --without-p11-kit --without-idn --with-included-unistring --without-tpm --without-tpm2 \
    --without-zlib --without-brotli --without-zstd --without-leancrypto \
    --with-system-priority-file= --with-unbound-root-key-file="$PREFIX/etc/unbound/root.key"

# HVF (an experimental Apple font driver, macOS 15.4+, weak-linked to /usr/lib/libhvf.dylib) is left
# out: Wine does not use it and macOS 12 has no libhvf.
build freetype "$SRC/freetype-2.15.0" "$DEPS_DESTDIR" "${CROSS[@]}" CC_BUILD="$NATIVE_CC" \
    --without-harfbuzz --without-png --without-bzip2 --without-brotli --with-zlib=yes ac_cv_header_hvf_Scaler_h=no

# Proof: every installed library is x86_64 only, for macOS 12.3 or earlier, and links only macOS's
# own libraries and each other.
bad=0
for f in "$DEPS"/lib/*.dylib; do
    [[ -L "$f" ]] && continue
    a=$(lipo -archs "$f"); m=$(vtool -show-build "$f" 2>/dev/null | awk '/minos/ {print $2; exit}')
    printf '  %-28s %s minos %s\n' "$(basename "$f")" "$a" "$m"
    [[ "$a" == x86_64 ]] || bad=1
    otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -v -E "^(/usr/lib/lib(System\.B|z\.1)\.dylib|/System/Library/Frameworks/(Security|CoreFoundation)\.framework/|$PREFIX/lib/)" && bad=1
done
[[ $bad == 0 ]] || die "a library is not x86_64-only"
log "done: $DEPS"
