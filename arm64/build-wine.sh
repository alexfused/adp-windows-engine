#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build Wine natively for arm64 macOS, as Hadron's scripts/build-wine.sh does, minus its graphics
# and media layers (no Zink/EGL, FFmpeg, GStreamer, Vulkan, SDL).
#   PE archs: aarch64 (native ARM64 Windows code), arm64ec (x86_64 code through FEX),
#             i386 (32-bit DLLs for new-style WoW64; i386 code through FEX's WoW64 DLL)
#   Unix side: Apple clang (AppKit for winemac.drv). PE side: Homebrew clang + lld-link.
# Configured with the neutral prefix (env.sh) and -ffile-prefix-map, so no build or install path
# under /Users is compiled in; Wine finds its files relative to its own binaries. FreeType and
# GnuTLS come from build-ext.sh (work/ext-root), nothing from Homebrew's include or lib folders.
# Installs into dist/engine-root (make install DESTDIR). Rerunnable: configure runs once (or with
# --reconfigure, or when its command line changes), make is incremental.
# Usage: build-wine.sh [--reconfigure]

source "$(dirname "$0")/env.sh"
reconfigure=; [[ "${1:-}" == --reconfigure ]] && reconfigure=1
[[ -f "$WINE_SRC/.adp-patches" ]] || die "run fetch.sh first"
[[ -f "$EXT/lib/libgnutls.30.dylib" && -f "$EXT/lib/libfreetype.6.dylib" ]] || die "run build-ext.sh first"

# Only lib/ext's pkg-config files are visible, so configure cannot find a Homebrew library.
export PKG_CONFIG="$BREW/bin/pkg-config" PKG_CONFIG_LIBDIR="$EXT_PKG_CONFIG_LIBDIR" PKG_CONFIG_SYSROOT_DIR="$EXT_ROOT"
unset PKG_CONFIG_PATH
args=(
    CC=/usr/bin/clang CXX=/usr/bin/clang++
    CFLAGS="-g -O2 $PREFIX_MAP" CROSSCFLAGS="-g -O2 $PREFIX_MAP"
    --prefix="$NEUTRAL_PREFIX"
    --enable-archs=arm64ec,aarch64,i386
    --with-mingw="$BREW/opt/llvm/bin/clang"
    --without-x --disable-tests
    --without-alsa --without-capi --without-dbus --without-ffmpeg --without-fontconfig
    --without-gettext --without-gphoto --without-gstreamer --without-hwloc --without-inotify
    --without-krb5 --without-netapi --without-oss --without-pcap --without-pcsclite
    --without-pulse --without-sane --without-sdl --without-udev --without-usb --without-v4l2
    --without-va --without-vulkan --without-wayland
    BISON="$BREW/opt/bison/bin/bison"
)
mkdir -p "$WINE_BUILD"
cd "$WINE_BUILD"
if [[ ! -f Makefile || -n $reconfigure || "$(cat .adp-configure 2>/dev/null)" != "${args[*]}" ]]; then
    log "configuring wine"
    "$WINE_SRC/configure" "${args[@]}" > configure.out 2>&1 || { tail -40 configure.out; die "configure failed"; }
    grep -E '^configure: (WARNING|error)' configure.out || true
    echo "${args[*]}" > .adp-configure
fi

# Libraries Wine dlopen()s by name. configure found FreeType and GnuTLS under the neutral prefix;
# point those names at the copies package.sh puts in lib/ext, relative to the unix library that
# opens them (lib/wine/aarch64-unix/*.so), so no DYLD_* variable (and no
# allow-dyld-environment-variables entitlement) is needed. Bare names make dyld search folders
# such as /usr/local/lib; give CUPS its absolute system name (macOS's copy, in the shared cache)
# and send ODBC to the engine's own lib/ext, which has none (no host ODBC driver manager is
# loaded unless LIB_ODBC_DRIVER_MANAGER names one).
want_soname() {
    case $1 in
        FREETYPE|GNUTLS) echo "@loader_path/../../ext/$(basename "$2")" ;;
        CUPS) echo "/usr/lib/libcups.2.dylib" ;;
        ODBC) echo "@loader_path/../../ext/libodbc.dylib" ;;
        *) echo "$2" ;;
    esac
}
changed=
while IFS= read -r line; do
    lib=$(sed -n 's/^#define SONAME_LIB\([A-Z0-9_]*\) ".*"/\1/p' <<< "$line")
    cur=$(sed -n 's/^#define SONAME_LIB[A-Z0-9_]* "\(.*\)"/\1/p' <<< "$line")
    new=$(want_soname "$lib" "$cur")
    if [[ "$cur" != "$new" ]]; then
        sed -i '' "s|^#define SONAME_LIB$lib \".*\"|#define SONAME_LIB$lib \"$new\"|" include/config.h
        log "SONAME_LIB$lib: $cur -> $new"
        echo "$cur" > ".soname-$lib"   # package.sh reads the configure-time names
        changed=1
    fi
done < <(grep -E '^#define SONAME_LIB' include/config.h)
for lib in FREETYPE GNUTLS; do grep -q "^#define SONAME_LIB$lib \"@loader_path" include/config.h || die "configure did not find $lib"; done
grep -E '^#define SONAME_LIB' include/config.h | sed 's/^/    /'
# Anything left by name, or under a user-writable or package-manager folder, would be loaded from there.
grep -E '^#define SONAME_LIB' include/config.h | grep -v -E '"(@loader_path/|/usr/lib/|/System/)' \
    && die "a library is still opened by bare name or from outside the engine and the OS (above)"

log "building wine with $JOBS jobs"
t0=$(date +%s)
make -j"$JOBS" > make.out 2>&1 || { grep -E 'error|Error' make.out | tail -30; die "make failed (work/build/wine/make.out)"; }
log "build took $(( $(date +%s) - t0 )) s"

log "installing to $ENGINE (DESTDIR $ENGINE_DESTDIR)"
rm -rf "$ENGINE_DESTDIR"
make install DESTDIR="$ENGINE_DESTDIR" > install.out 2>&1 || { tail -20 install.out; die "make install failed"; }
[[ -x "$ENGINE/bin/wineserver" ]] || die "make install put nothing in $ENGINE"
log "done ($(du -sh "$ENGINE" | cut -f1)); wine --version needs the signed loader (package.sh)"
