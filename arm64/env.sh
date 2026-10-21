# SPDX-License-Identifier: MIT
# Paths and pins for the arm64 Windows engine spike. Source it, don't execute it.
# Pins are in SOURCES.md too; change both together.

set -euo pipefail

SPIKE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$SPIKE/work"            # checkouts and build trees (ignored)
DOWNLOADS="$SPIKE/downloads"  # verified downloads, one folder each (ignored)
DIST="$SPIKE/dist"            # installed engine trees and archives (ignored)

HADRON_URL=https://github.com/Broyojo/hadron.git
HADRON_REF=d523fe6b8fa0d8632911d49d02980769f2d4261c   # main, 20 Oct 2026 (0.3.1 + log-cap, retina-cursor)
HADRON="$WORK/hadron"

LLVM_MINGW_VERSION=20260922   # the release Hadron's setup-toolchain.sh pins
LLVM_MINGW_NAME="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal"
LLVM_MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$LLVM_MINGW_NAME.tar.xz"
LLVM_MINGW_SHA256=52e5f5a7b131021d0c39a37a38fa380a1da7885cd04bd61afd0cd4ecfb8bc1f3
MINGW="$WORK/toolchains/llvm-mingw/bin"

# The prefix configure scripts compile in. It is neutral: no user can create /nonexistent (the
# system volume is read-only), so a compiled-in fallback path below it can never be opened.
# Wine and FEX find their files relative to their own binaries; make install goes through DESTDIR.
NEUTRAL_PREFIX=/nonexistent/adp-winehost
# Build paths become relative in __FILE__ strings and debug info (asserts, fallback messages).
PREFIX_MAP="-ffile-prefix-map=$WORK=adp-work"

WINE_SRC="$WORK/src/wine"
FEX_SRC="$WORK/src/fex"
WINE_BUILD="$WORK/build/wine"
FEX_BUILD="$WORK/build"
ENGINE_DESTDIR="$DIST/engine-root"
ENGINE="$ENGINE_DESTDIR$NEUTRAL_PREFIX"   # make install target: bin/ lib/ share/

# lib/ext: built from source by build-ext.sh, installed under the same neutral prefix.
EXT_SRC="$WORK/ext-src"
EXT_ROOT="$WORK/ext-root"
EXT="$EXT_ROOT$NEUTRAL_PREFIX"           # lib/, include/, lib/pkgconfig/
# pkg-config sees only these: lib/ext's own files and the macOS zlib/bzip2 (build-ext.sh writes those).
EXT_PKG_CONFIG_LIBDIR="$EXT/lib/pkgconfig:$WORK/ext-sys-pkgconfig"

# Signing: Alex's Developer ID and the engine's own App ID, whose profile grants
# cross-architecture support. Never ADP Monitor's own id (com.alexparkin.adpmonitor): the root
# helper and macOS's privacy grants trust that one.
IDENTITY="Developer ID Application: Alex Parkin (2F2FVY326V)"
TEAM_ID=2F2FVY326V
PROFILE="${ADP_PROFILE:-$SPIKE/../../dist/profiles/ADP_Monitor_Windows_Engine_Developer_ID.provisionprofile}"
BUNDLE_ID="${ADP_BUNDLE_ID:-com.alexparkin.adpmonitor.winehost}"   # must be the profile's App ID
ADP_MONITOR_BUNDLE_ID=com.alexparkin.adpmonitor
[[ "$BUNDLE_ID" != "$ADP_MONITOR_BUNDLE_ID" ]] || { echo "error: the engine must not use ADP Monitor's bundle id" >&2; exit 1; }
ENGINE_REV="${ENGINE_REV:-2}"

BREW="$(brew --prefix)"
# Homebrew LLVM is the PE cross compiler for Wine (aarch64/arm64ec/i386-windows), lld its linker;
# macOS bison 2.3 is too old for Wine. Build tools only: nothing from Homebrew is linked or shipped.
export PATH="$BREW/opt/llvm/bin:$BREW/opt/lld/bin:$BREW/opt/bison/bin:$BREW/opt/flex/bin:$PATH"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -m)" == arm64 ]] || die "this engine is for Apple silicon hosts"
# No Rosetta, ever: refuse to run if this shell itself is translated.
[[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" == 0 ]] || die "running under Rosetta"

# TRACE=1 shows every command (debugging a script).
[[ -z "${TRACE:-}" ]] || set -x
