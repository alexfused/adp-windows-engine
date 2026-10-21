# SPDX-License-Identifier: MIT
# Paths, pins and toolchain for the Intel (x86_64 host) Windows engine. Source it, don't execute it.
#
# The build Mac is Apple silicon. Every x86_64 file is cross-compiled and never run here: no
# Rosetta, ever. Three layers:
#  1. configure gets both --build and --host, so autoconf knows it is cross compiling; build-time
#     generators (GMP, Nettle, FreeType, Wine's tools) are built natively for arm64.
#  2. Every cross configure, make and install runs under sandbox-exec with exec denied inside the
#     x86_64 build and install trees (x86_sandboxed below): the kernel refuses to start a file
#     from there, so no x86_64 instruction can run even when a script forgets it is cross compiling
#     (gnulib's locale probes run ./conftest unconditionally: README.md, "Rosetta incident").
#  3. rosetta_guard_* watches the process table for anything translated and fails the step.
# Pins are in SOURCES.md too; change both together.

set -euo pipefail

SPIKE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$SPIKE/work"            # source trees, build trees, toolchain, guard logs (git-ignored)
DOWNLOADS="$SPIKE/downloads"  # verified downloads, one folder each (git-ignored)
DIST="$SPIKE/dist"            # staged engine, archive, manifests (git-ignored)

WINE_VERSION=11.18
ENGINE_REV="${ENGINE_REV:-1}"
ENGINE_NAME="engine-x86_64-$WINE_VERSION-$ENGINE_REV"
STAGE="$DIST/stage/$ENGINE_NAME"

# The same Wine tree as the arm64 engine: Hadron's pin of upstream Wine.
WINE_COMMIT=6880117619afdf62b4ccc40a8c6268c86613131f
HADRON_URL=https://github.com/Broyojo/hadron
HADRON_REF=d523fe6b8fa0d8632911d49d02980769f2d4261c   # the arm64 engine's Hadron pin
LLVM_MINGW_VERSION=20260922                            # the release Hadron's setup-toolchain.sh pins
LLVM_MINGW_NAME="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal"

# Earlier verified downloads on this Mac. fetch.sh clones a file from here instead of downloading it
# again, only when its SHA-256 equals the pin in sources.tsv. Missing folders are fine.
# Defaults are relative to the main checkout (this folder may be in a git worktree).
MAIN_CHECKOUT="$(git -C "$SPIKE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##' || true)"
SEED_DIRS=(
    "${ADP_RELEASE_DOWNLOADS:-$MAIN_CHECKOUT/spikes/windows-engine-release/downloads/fetch}"
    "${ADP_ARM64_SPIKE:-$MAIN_CHECKOUT/spikes/windows-engine-arm64}/downloads"
)
HADRON_SEED="${ADP_ARM64_SPIKE:-$MAIN_CHECKOUT/spikes/windows-engine-arm64}/work/hadron"

SRC="$WORK/src"
BUILD="$WORK/build"
MINGW="$WORK/toolchains/llvm-mingw/bin"

# Target: x86_64 macOS 12.3 or later (the Intel venue iMac and older Intel Macs).
HOST_TRIPLE=x86_64-apple-darwin
BUILD_TRIPLE=aarch64-apple-darwin
MACOS_MIN=12.3
export MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN

# The prefix compiled into the binaries. It cannot exist: macOS's root volume is sealed and
# read-only, so nobody can create /nonexistent without root, /etc/synthetic.conf and a reboot.
# Files are installed under DESTDIR (in work/), never at the prefix. The engine itself is
# relocatable: Wine finds everything relative to ntdll.so, and lib/ext is @loader_path.
PREFIX=/nonexistent/adp-windows-engine
DEPS_DESTDIR="$WORK/destdir-deps"         # x86_64 GMP, Nettle, libtasn1, GnuTLS, FreeType
DEPS="$DEPS_DESTDIR$PREFIX"
WINE_DESTDIR="$WORK/destdir-wine"
WINE_INSTALL="$WINE_DESTDIR$PREFIX"
NATIVE_DEPS="$WORK/native-deps"           # arm64 FreeType for Wine's own build tools (never shipped)

# Signing. The engine has its own identity, never ADP Monitor's (com.alexparkin.adpmonitor).
IDENTITY="${ADP_ENGINE_IDENTITY:-Developer ID Application: Alex Parkin (2F2FVY326V)}"
TEAM_ID=2F2FVY326V
ID_PREFIX=com.alexparkin.adpmonitor.winehost
ADP_MONITOR_ID=com.alexparkin.adpmonitor

# Toolchain: Xcode's clang and the macOS SDK, and nothing from Homebrew, MacPorts or /usr/local
# on the compiler's search paths. Two host tools come from Homebrew because macOS's are too old
# or missing; they only generate C code or read .pc files we wrote:
#   bison >= 3 (macOS has 2.3), pkg-config (reads only our own .pc files: PKG_CONFIG_LIBDIR).
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"; export SDKROOT
CLANG="$(xcrun --sdk macosx -f clang)"
BISON="${BISON:-$(ls /opt/homebrew/opt/bison/bin/bison /usr/local/opt/bison/bin/bison 2>/dev/null | head -1 || true)}"
PKG_CONFIG_BIN="${PKG_CONFIG_BIN:-$(ls /opt/homebrew/bin/pkg-config /usr/local/bin/pkg-config 2>/dev/null | head -1 || true)}"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# Every compile maps the build folder away, so no /Users path reaches a binary through __FILE__,
# asserts or debug info; work/ holds every source, build and DESTDIR tree, and the PE toolchain.
MAP_FLAGS="-ffile-prefix-map=$WORK/=adp-build/"
# x86-cc: clang -arch x86_64 -mmacosx-version-min=12.3 that clears the execute bit of every x86_64
# executable it links (configure probes that run ./conftest anyway get EACCES; tools/x86-cc).
export ADP_CLANG="$CLANG" ADP_MACOS_MIN="$MACOS_MIN"
X86_CC="$SPIKE/tools/x86-cc"
X86_CFLAGS="-O2 $MAP_FLAGS"
X86_LDFLAGS="-mmacosx-version-min=$MACOS_MIN -Wl,-headerpad_max_install_names"
NATIVE_CC="$CLANG -arch arm64"            # for build-time generators only; their output is data

JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

[[ "$(uname -m)" == arm64 ]] || die "these scripts cross-compile on an Apple silicon Mac (test-on-intel.sh is the Intel side)"
# No Rosetta, ever: refuse to run if this shell itself is translated.
[[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" == 0 ]] || die "running under Rosetta"
[[ -x "$CLANG" && -d "$SDKROOT" ]] || die "no Xcode or Command Line Tools clang/SDK"

# ---- Exec barrier --------------------------------------------------------------------------
# Nothing inside the x86_64 trees may be executed. Allowed there by name: the native generators the
# libraries build with CC_FOR_BUILD (GMP gen-*, Nettle eccdata, FreeType apinames; build-deps.sh
# checks they are arm64), the native compiler probes of those configure scripts (a.out, b.out,
# conftest in a deps tree: an x86_64 one has no execute bit, see x86-cc, so it cannot start), and
# shell scripts (run by /bin/sh; text, not x86_64 code). Wine's tree and every install tree allow
# nothing. The native trees (Wine's tools, the arm64 FreeType) are outside the denied paths.
X86_TREES=("$BUILD/deps-gmp" "$BUILD/deps-nettle" "$BUILD/deps-libtasn1" "$BUILD/deps-gnutls"
           "$BUILD/deps-freetype" "$BUILD/wine" "$DEPS_DESTDIR" "$WINE_DESTDIR" "$DIST")
SANDBOX_PROFILE="(version 1)(allow default)"
for t in "${X86_TREES[@]}"; do SANDBOX_PROFILE+="(deny process-exec (subpath \"$t\"))"; done
SANDBOX_PROFILE+="(allow process-exec (regex #\"^$BUILD/deps-gmp/gen-\" #\"^$BUILD/deps-nettle/eccdata\$\" #\"^$BUILD/deps-freetype/(objs/)?apinames\$\""
SANDBOX_PROFILE+=" #\"^$BUILD/deps-(gmp|nettle|freetype)/(a\\.out|b\\.out|conftest)\$\""
SANDBOX_PROFILE+=" #\"/libtool\$\" #\"/config\\.status\$\" #\"\\.sh\$\"))"
x86_sandboxed() { /usr/bin/sandbox-exec -p "$SANDBOX_PROFILE" "$@"; }

# ---- Rosetta guard -------------------------------------------------------------------------
# A native watcher lists every process 100 times a second and records any that is translated
# (P_TRANSLATED) or is Rosetta's translator (oahd-helper), with its path; it kills a translated
# process whose executable is inside this spike. rosetta_guard_stop fails the script if it saw
# one, and logs oahd's CPU time before and after (it grows when Rosetta translates a new binary).
GUARD_BIN="$WORK/tools/rosetta-watch"
GUARD_LOG_DIR="$WORK/guard"
# (ps is setuid, which the exec barrier's sandbox refuses: then "n/a". It is a weak signal anyway:
# it did not move when the first build ran 24 translated probes, README.md.)
oahd_cpu() { local p t; p=$(pgrep -x oahd 2>/dev/null | head -1 || true); [[ -n $p ]] || { echo none; return; }
             t=$(ps -o time= -p "$p" 2>/dev/null | tr -d ' ' || true); echo "${t:-n/a}"; }
rosetta_guard_start() {   # stage name
    mkdir -p "$GUARD_LOG_DIR" "$WORK/tools"
    if [[ ! -x "$GUARD_BIN" || "$SPIKE/tools/rosetta-watch.c" -nt "$GUARD_BIN" ]]; then
        $NATIVE_CC -O2 -o "$GUARD_BIN" "$SPIKE/tools/rosetta-watch.c" || die "cannot build the Rosetta guard"
    fi
    GUARD_STAGE="$1"; GUARD_LOG="$GUARD_LOG_DIR/$1.log"
    GUARD_OAHD_BEFORE=$(oahd_cpu)
    "$GUARD_BIN" "$SPIKE/" "$$" > "$GUARD_LOG" 2>&1 &
    GUARD_PID=$!
    trap rosetta_guard_stop EXIT
}
rosetta_guard_stop() {
    local rc=$? seen
    trap - EXIT
    [[ -n "${GUARD_PID:-}" ]] || return $rc
    kill -INT "$GUARD_PID" 2>/dev/null || true
    wait "$GUARD_PID" 2>/dev/null || true
    GUARD_PID=
    printf 'oahd cpu before %s after %s\n' "$GUARD_OAHD_BEFORE" "$(oahd_cpu)" >> "$GUARD_LOG"
    seen=$(grep -c '^TRANSLATED' "$GUARD_LOG" || true)
    # One line per run, kept across runs (evidence/rosetta-guard.txt is a copy).
    printf '%s\t%s\texit %s\t%s; %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$GUARD_STAGE" "$rc" \
        "$(grep '^watched' "$GUARD_LOG" | tail -1)" "$(tail -1 "$GUARD_LOG")" >> "$GUARD_LOG_DIR/summary.tsv"
    if [[ "$seen" != 0 ]]; then
        printf 'error: Rosetta guard saw %s translated process(es) during %s:\n' "$seen" "$GUARD_STAGE" >&2
        grep '^TRANSLATED' "$GUARD_LOG" >&2
        exit 70
    fi
    log "rosetta guard ($GUARD_STAGE): no translated process; $(tail -1 "$GUARD_LOG")"
    return $rc
}

# TRACE=1 shows every command (debugging a script).
[[ -z "${TRACE:-}" ]] || set -x
