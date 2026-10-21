#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build FEX's Wine emulator DLLs and their macOS unix helper, as Hadron's scripts/build-fex.sh:
#   libwow64fex.dll    aarch64 PE: runs i386 code under WoW64      (installed as xtajit.dll)
#   libarm64ecfex.dll  arm64ec PE: runs x86_64 code in ARM64EC     (installed as xtajit64.dll)
#   lib*fex.so         arm64 macOS helpers the DLLs reach through __wine_unix_call
# Configured with the neutral prefix (FEX compiles its data folders in: they name /nonexistent) and
# -ffile-prefix-map; installed with cmake --install and DESTDIR into the engine tree.
# Installs into dist/engine-root, so run it after build-wine.sh's make install (which puts Wine's
# xtajit stubs there). Rerunnable; cmake/ninja are incremental.

source "$(dirname "$0")/env.sh"
[[ -f "$FEX_SRC/.adp-patches" ]] || die "run fetch.sh first"
[[ -x "$MINGW/arm64ec-w64-mingw32-clang" ]] || die "missing llvm-mingw, run fetch.sh"

t0=$(date +%s)
for target in wow64 arm64ec; do
    case $target in
        wow64)   triple=aarch64-w64-mingw32 ;;
        arm64ec) triple=arm64ec-w64-mingw32 ;;
    esac
    log "building FEX $target DLL"
    PATH="$MINGW:$PATH" cmake -S "$FEX_SRC" -B "$FEX_BUILD/fex-$target" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$FEX_SRC/Data/CMake/toolchain_mingw.cmake" \
        -DMINGW_TRIPLE=$triple \
        -DCMAKE_INSTALL_PREFIX="$NEUTRAL_PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib/wine/aarch64-windows \
        -DCMAKE_C_FLAGS="$PREFIX_MAP" -DCMAKE_CXX_FLAGS="$PREFIX_MAP" \
        -DENABLE_LTO=False -DENABLE_ASSERTIONS=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False \
        -DBUILD_TESTING=False -DTUNE_ARCH=generic -DTUNE_CPU=none -DRANGES_NATIVE=OFF \
        > "$FEX_BUILD/fex-$target.cmake.log" 2>&1 || { tail -30 "$FEX_BUILD/fex-$target.cmake.log"; die "cmake $target failed"; }
    PATH="$MINGW:$PATH" cmake --build "$FEX_BUILD/fex-$target" -j "$JOBS" > "$FEX_BUILD/fex-$target.build.log" 2>&1 \
        || { grep -E 'error' "$FEX_BUILD/fex-$target.build.log" | tail -30; die "build $target failed"; }
done

log "building FEX unix helpers"
cmake -S "$FEX_SRC/Source/Windows/UnixLib" -B "$FEX_BUILD/fex-unixlib" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_C_FLAGS="$PREFIX_MAP" -DCMAKE_CXX_FLAGS="$PREFIX_MAP" \
    -DCMAKE_INSTALL_PREFIX="$NEUTRAL_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib/wine/aarch64-unix > "$FEX_BUILD/fex-unixlib.cmake.log" 2>&1 \
    || { tail -30 "$FEX_BUILD/fex-unixlib.cmake.log"; die "cmake unixlib failed"; }
cmake --build "$FEX_BUILD/fex-unixlib" > "$FEX_BUILD/fex-unixlib.build.log" 2>&1 \
    || { tail -30 "$FEX_BUILD/fex-unixlib.build.log"; die "build unixlib failed"; }
log "FEX built in $(( $(date +%s) - t0 )) s"

if [[ "${1:-}" == --no-install ]]; then exit 0; fi
[[ -d "$ENGINE/lib/wine/aarch64-windows" ]] || die "no Wine in $ENGINE yet: run build-wine.sh first, or pass --no-install"
# DESTDIR, not --prefix: FEX installs some data to absolute paths made from the configured prefix.
for target in wow64 arm64ec unixlib; do
    d="$FEX_BUILD/fex-$target"
    DESTDIR="$ENGINE_DESTDIR" cmake --install "$d" > "$FEX_BUILD/fex-$target.install.log" 2>&1 \
        || { tail -20 "$FEX_BUILD/fex-$target.install.log"; die "cmake --install $target failed"; }
done

# FEX under the emulator names Wine loads by default (HKLM\Software\Microsoft\Wow64\x86 and
# \amd64 fall back to xtajit.dll / xtajit64.dll), so it works from the first prefix boot.
W="$ENGINE/lib/wine/aarch64-windows"
rm -f "$W/xtajit.dll" "$W/xtajit64.dll"
cp "$W/libwow64fex.dll" "$W/xtajit.dll"
cp "$W/libarm64ecfex.dll" "$W/xtajit64.dll"
log "installed:"
ls -la "$W"/lib*fex.dll "$W"/xtajit*.dll "$ENGINE"/lib/wine/aarch64-unix/lib*fex.so
