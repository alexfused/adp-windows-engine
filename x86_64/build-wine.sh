#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build Wine for x86_64 macOS 12.3 on this Apple silicon Mac, without running any x86_64 code.
#
#  1. work/build/wine-tools: a native arm64 configure of the same patched tree, then only
#     `make __tooldeps__` (makedep, winebuild, winegcc, widl, wrc, wmc, sfnt2fon, ...). These run
#     during the build; nothing from this tree is shipped.
#  2. work/build/wine: the cross build, --build=aarch64-apple-darwin --host=x86_64-apple-darwin
#     --with-wine-tools=work/build/wine-tools, PE archs i386 and x86_64 with llvm-mingw:
#     new-style WoW64 (32-bit programs run in 64-bit processes; no 32-bit Mac code exists).
#     Unix side: Xcode clang -arch x86_64 -mmacosx-version-min=12.3. Same optional-library choices
#     as the arm64 engine (no X11, Vulkan, GStreamer, FFmpeg, SDL, ...); FreeType and GnuTLS come
#     from build-deps.sh, CoreAudio, CUPS, OpenGL and OpenCL are macOS's own.
#  3. make install with DESTDIR into work/destdir-wine (the prefix in the binaries is neutral).
# The cross configure, make and install run under env.sh's exec barrier (nothing in work/build/wine
# or the install tree can be started) with CC=tools/x86-cc (x86_64 executables get no execute bit).
#
# Wine dlopen()s FreeType, GnuTLS, CUPS and ODBC by name; config.h gets fixed paths instead (see
# below), so nothing is looked up in $HOME/lib or /usr/local/lib, and no DYLD_* variable (nor the
# allow-dyld-environment-variables entitlement) is needed.
# Rerunnable: each configure runs once (or with --reconfigure); make is incremental.
# Usage: build-wine.sh [--reconfigure]

source "$(dirname "$0")/env.sh"
reconfigure=; [[ "${1:-}" == --reconfigure ]] && reconfigure=1
[[ -f "$SRC/wine/.adp-source" ]] || die "run fetch.sh first"
[[ -f "$DEPS/lib/libgnutls.30.dylib" && -f "$DEPS/lib/libfreetype.6.dylib" ]] || die "run build-deps.sh first"
[[ -x "$BISON" ]] || die "Wine needs bison 3 (macOS has 2.3): install Homebrew bison or set BISON"
rosetta_guard_start build-wine

# Optional libraries: as in the arm64 engine (spikes/windows-engine-arm64/build-wine.sh).
WITHOUT=(--without-x --disable-tests
    --without-alsa --without-capi --without-dbus --without-ffmpeg --without-fontconfig
    --without-gettext --without-gphoto --without-gstreamer --without-hwloc --without-inotify
    --without-krb5 --without-netapi --without-oss --without-pcap --without-pcsclite
    --without-pulse --without-sane --without-sdl --without-udev --without-usb --without-v4l2
    --without-va --without-vulkan --without-wayland)
export PATH="$MINGW:$PATH"   # i686-/x86_64-w64-mingw32-clang (universal binaries, run as arm64)

# 1. Native tools.
TOOLS="$BUILD/wine-tools"
if [[ ! -f "$TOOLS/Makefile" || -n $reconfigure ]]; then
    log "configuring the native tools"
    rm -rf "$TOOLS"; mkdir -p "$TOOLS"
    (cd "$TOOLS" && "$SRC/wine/configure" CC="$NATIVE_CC" CFLAGS="-O2" BISON="$BISON" \
        FREETYPE_CFLAGS="-I$NATIVE_DEPS/include/freetype2" FREETYPE_LIBS="-L$NATIVE_DEPS/lib -lfreetype" \
        --with-mingw=llvm-mingw --without-gnutls "${WITHOUT[@]}" > configure.out 2>&1) \
        || { tail -30 "$TOOLS/configure.out"; die "tools configure failed"; }
fi
log "building the native tools"
make -C "$TOOLS" -j"$JOBS" __tooldeps__ > "$TOOLS/make.out" 2>&1 || { grep -E 'error' "$TOOLS/make.out" | tail -20; die "tools build failed"; }
for t in makedep winebuild/winebuild winegcc/winegcc widl/widl wrc/wrc wmc/wmc sfnt2fon/sfnt2fon; do
    f="$TOOLS/tools/$t"; [[ -x "$f" ]] || die "tool $t was not built"
    [[ "$(lipo -archs "$f")" == arm64 ]] || die "tool $t is not native arm64"
done
log "tools: native arm64 ($(ls -d "$TOOLS"/tools/*/ | wc -l | tr -d ' ') folders)"

# 2. Cross build.
# Functions the macOS 27 SDK declares but macOS 12.3 lacks. configure's link tests use the SDK's
# libSystem, so they find them; the compiler then weak-links them (the deployment target is older)
# and Wine calls them without a runtime check: a call through a NULL pointer on every Intel Mac.
#   pipe2: macOS 27.0+. ntdll's server_pipe() uses it as each Wine process connects to wineserver.
# The check after make (and verify.sh's weak-import list) catches any new one.
NOT_ON_MIN_MACOS=(ac_cv_func_pipe2=no)
W="$BUILD/wine"
CONFIGURE=(--build="$BUILD_TRIPLE" --host="$HOST_TRIPLE" --with-wine-tools="$TOOLS"
    --prefix="$PREFIX" --enable-archs=i386,x86_64 --with-mingw=llvm-mingw
    CC="$X86_CC" CXX="$X86_CC" CFLAGS="$X86_CFLAGS" LDFLAGS="-mmacosx-version-min=$MACOS_MIN"
    CROSSCFLAGS="-O2 $MAP_FLAGS" BISON="$BISON"
    FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype"
    GNUTLS_CFLAGS="-I$DEPS/include" GNUTLS_LIBS="-L$DEPS/lib -lgnutls"
    "${NOT_ON_MIN_MACOS[@]}" "${WITHOUT[@]}")
stamp="$(cat "$SRC/wine/.adp-source") ${CONFIGURE[*]} $(xcrun --sdk macosx --show-sdk-version)"
if [[ ! -f "$W/Makefile" || -n $reconfigure || "$(cat "$W/.adp-configured" 2>/dev/null)" != "$stamp" ]]; then
    log "configuring wine for $HOST_TRIPLE (macOS $MACOS_MIN)"
    rm -rf "$W"; mkdir -p "$W"
    (cd "$W" && x86_sandboxed "$SRC/wine/configure" "${CONFIGURE[@]}" > configure.out 2>&1) \
        || { tail -40 "$W/configure.out"; die "wine configure failed"; }
    grep -q 'whether we are cross compiling\.\.\. yes' "$W/configure.out" || die "wine configure did not run as a cross build"
    grep -E '^configure: (WARNING|error)' "$W/configure.out" || true
    echo "$stamp" > "$W/.adp-configured"
fi
grep -q '^#define HAVE_PIPE2 1' "$W/include/config.h" && die "config.h has HAVE_PIPE2 (macOS 27+ only)"

# Libraries Wine opens by name. A bare name ("libcups.2.dylib") makes dyld search $HOME/lib and
# /usr/local/lib (Intel Homebrew's folder) before /usr/lib, so every name becomes a fixed path:
#   FreeType, GnuTLS -> @loader_path/../../ext/<file> (package.sh puts them there)
#   CUPS             -> /usr/lib/libcups.2.dylib (macOS's own)
#   ODBC             -> @loader_path/../../ext/libodbc.dylib, which the engine does not ship: no host
#                       ODBC driver manager unless LIB_ODBC_DRIVER_MANAGER names one (Wine's own switch)
# Idempotent; make rebuilds what includes config.h.
H="$W/include/config.h"
setname() {   # NAME new-value
    local cur; cur=$(sed -n "s/^#define SONAME_LIB$1 \"\(.*\)\"/\1/p" "$H")
    [[ -n "$cur" ]] || die "configure did not define SONAME_LIB$1"
    [[ "$cur" == "$2" ]] && return
    sed -i '' "s|^#define SONAME_LIB$1 \".*\"|#define SONAME_LIB$1 \"$2\"|" "$H"
    log "SONAME_LIB$1: $cur -> $2"
}
for lib in FREETYPE GNUTLS; do
    cur=$(sed -n "s/^#define SONAME_LIB$lib \"\(.*\)\"/\1/p" "$H"); [[ -n "$cur" ]] || die "configure did not find $lib"
    basename "$cur" > "$W/.soname-$lib"   # package.sh copies this library into lib/ext
    setname "$lib" "@loader_path/../../ext/$(basename "$cur")"
done
setname CUPS /usr/lib/libcups.2.dylib
setname ODBC @loader_path/../../ext/libodbc.dylib
others=$(sed -n 's/^#define SONAME_LIB[A-Z0-9_]* "\(.*\)"/\1/p' "$H" | grep -v -E '^(@loader_path/\.\./\.\./ext/|/usr/lib/|/System/Library/)' || true)
[[ -z "$others" ]] || die "config.h names libraries Wine would look up by bare name: $others"

log "building wine with $JOBS jobs"
t0=$(date +%s)
x86_sandboxed make -C "$W" -j"$JOBS" > "$W/make.out" 2>&1 || { grep -E 'error' "$W/make.out" | tail -30; die "make failed ($W/make.out)"; }
log "build took $(( $(date +%s) - t0 )) s"
# No call to an API newer than macOS 12.3 without a runtime check. clang flags them as
# -Wunguarded-availability(-new). Allowed: winemac.drv's two activation methods (macOS 14), which
# exist only in cocoa_app.m and are sent only after [NSApplication instancesRespondToSelector:
# @selector(yieldActivationToApplication:)]. Matched by message, not file name: parallel make can
# interleave two compilers' lines. make.out of an incremental run holds only what was recompiled;
# a configure change rebuilds everything. evidence/availability-warnings.txt keeps what was seen.
avail=$(grep -E "is only available on macOS [0-9.]+ or newer \[-Wunguarded-availability" "$W/make.out" | sed "s#$WORK/#<work>/#g" || true)
unguarded=$(grep -v -E "'(yieldActivationToApplication:|activateFromApplication:options:)' is only available on macOS 14\.0 " <<< "$avail" || true)
{ echo "# -Wunguarded-availability warnings in the last Wine make (deployment target $MACOS_MIN, SDK $(xcrun --sdk macosx --show-sdk-version))"
  echo "# allowed: yieldActivationToApplication:, activateFromApplication:options: (winemac.drv, behind instancesRespondToSelector:)"
  [[ -n "$avail" ]] && printf '%s\n' "$avail" || echo "(none in this make: nothing was recompiled, or none exist)"
  echo "# not allowed: $( [[ -z "$unguarded" ]] && echo none || echo "$(wc -l <<< "$unguarded" | tr -d ' ')" )"
} > "$SPIKE/evidence/availability-warnings.txt"
[[ -z "$unguarded" ]] || die "calls to APIs newer than macOS $MACOS_MIN without a runtime check:
$unguarded"

# 3. Install under DESTDIR (the binaries carry the neutral prefix, never this path).
log "installing to $WINE_INSTALL"
rm -rf "$WINE_DESTDIR"
x86_sandboxed make -C "$W" install DESTDIR="$WINE_DESTDIR" > "$W/install.out" 2>&1 || { tail -20 "$W/install.out"; die "make install failed"; }
for f in bin/wine bin/wineserver lib/wine/x86_64-unix/wine lib/wine/x86_64-unix/ntdll.so; do
    printf '  %-32s %s\n' "$f" "$(lipo -archs "$WINE_INSTALL/$f")"
done
log "done: $WINE_INSTALL (wine $(sed -n 's/^Wine version //p' "$SRC/wine/VERSION"); not run here: it is x86_64)"
