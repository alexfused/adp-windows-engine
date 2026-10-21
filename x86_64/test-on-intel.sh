#!/bin/bash
# SPDX-License-Identifier: MIT
# Headless test of the Intel Windows engine, on an Intel Mac. It was built on Apple silicon and has
# never run anywhere: this script is its first run.
#
#   ./test-on-intel.sh [--keep] [--no-matrix] [--mac-driver] [ENGINE.tar.xz]
#
# Run it from the test kit folder archive.sh makes (dist/testkit/engine-x86_64-<ver>-intel-test):
# the engine archive and its .sha256, hello32.exe, hello64.exe, loaders/. No sudo, nothing installed,
# no window (Wine's Mac driver is off unless --mac-driver), no network. Needs only what macOS 12.3+
# ships (no Xcode or Command Line Tools: lipo, otool and strings would ask to install them, so the
# script reads Mach-O headers with xxd). Not on the venue iMac while the venue is open.
#
#  1. Refuses to run unless this is a real Intel Mac: x86_64, no arm64 hardware, not translated.
#  2. Checks the archive's SHA-256, unpacks it into a new temporary folder, removes quarantine
#     (ADP Monitor does the same), checks every Mach-O is x86_64-only with a valid signature, and
#     records what Gatekeeper says about the loader.
#  3. wine --version                              expects wine-11.18
#  4. wineboot -u                                 makes a new prefix (HOME is a temporary folder too),
#                                                 then waits for wineserver to exit (wineserver -w: it
#                                                 writes the registry then) and checks for system.reg
#  5. wine cmd /c ver                             64-bit cmd.exe
#  6. wine C:\windows\syswow64\cmd.exe /c ver     32-bit cmd.exe through WoW64
#  7. hello64.exe, hello32.exe                    architecture (hello32 must say wow64=1), executable
#                                                 memory written then called, SuspendThread+GetThreadContext,
#                                                 schannel (GnuTLS loaded from lib/ext), Tahoma measured
#                                                 (FreeType loaded from lib/ext); tools/hello.c
#  8. Entitlement matrix (skip with --no-matrix): the loader as signed without disable-library-validation,
#     without allow-unsigned-executable-memory, with neither, and with both plus
#     disable-executable-page-protection (loaders/ in the kit, signed on the build Mac), each swapped
#     in for the shipped loader and run on steps 3, 5, 7 against the same prefix. An entitlement is
#     needed if removing it breaks a step; the "plus" loader only matters if the shipped one fails.
#     Informational: it never fails the run.
#  9. --mac-driver: also start cmd /c ver with the Mac driver on (needs a logged-in desktop; may show
#     a Dock icon for a second).
# 10. Cleanup on any exit: wineserver -k, kill whatever still runs from the temporary folder, delete
#     it and wineserver's socket folder for that prefix in /tmp/.wine-<uid> (unless --keep).
# Results: test-on-intel-<host>-<time>.log next to this script, and a summary on screen. Exit 0 only
# if every required step (2-7) passed.

KEEP=; MATRIX=1; MACDRV=; ARCHIVE=
while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1 ;;
        --no-matrix) MATRIX= ;;
        --mac-driver) MACDRV=1 ;;
        -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) ARCHIVE="$1" ;;
    esac
    shift
done

KIT="$(cd "$(dirname "$0")" && pwd)"
[ -n "$ARCHIVE" ] || ARCHIVE=$(ls "$KIT"/engine-x86_64-*.tar.xz 2>/dev/null | head -1)
[ -f "$ARCHIVE" ] || { echo "no engine archive (engine-x86_64-*.tar.xz) given or next to this script" >&2; exit 2; }
# 1. A real Intel Mac only. A translated shell on Apple silicon reports x86_64 from uname, so ask
# the hardware (hw.optional.arm64) and the kernel (sysctl.proc_translated) too.
arch=$(uname -m); arm=$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0); tr=$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)
if [ "$arch" != x86_64 ] || [ "$arm" = 1 ] || [ "$tr" = 1 ]; then
    echo "This is not an Intel Mac (uname -m $arch, hw.optional.arm64 $arm, translated $tr)." >&2
    echo "The Intel engine must never run through Rosetta; run this on an Intel Mac." >&2
    exit 3
fi
ENGINE_NAME=$(basename "$ARCHIVE" .tar.xz)
LOG="$KIT/test-on-intel-$(hostname -s)-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
PASSES=0; FAILS=0; RESULTS=""
record() {   # step result detail
    RESULTS="$RESULTS$(printf '%-34s %-5s %s' "$1" "$2" "$3")
"
    if [ "$2" = PASS ]; then PASSES=$((PASSES + 1)); else FAILS=$((FAILS + 1)); fi
    say "  -> $2 $1 $3"
}

say "Intel engine test: $ENGINE_NAME on $(hostname -s), macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n machdep.cpu.brand_string)"
say "log: $LOG"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/adp-intel-engine.XXXXXX") || exit 1
ROOT="$TMP/$ENGINE_NAME"
export HOME="$TMP/home"; mkdir -p "$HOME"
export WINEPREFIX="$TMP/prefix"
export WINEDEBUG="${WINEDEBUG-}"   # Wine's default: err: lines stay in the log
HEADLESS="winemac.drv=;winemenubuilder.exe=d;mscoree,mshtml="
export WINEDLLOVERRIDES="$HEADLESS"
unset WINESERVER WINELOADER DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_INSERT_LIBRARIES

cleanup() {
    local r sdir=
    [ -x "$ROOT/bin/wineserver" ] && "$ROOT/bin/wineserver" -k >/dev/null 2>&1
    sleep 1
    local left; left=$(pgrep -f "$TMP" 2>/dev/null | grep -v "^$$\$")
    if [ -n "$left" ]; then say "cleanup: stopping leftover processes $left"; kill $left 2>/dev/null; sleep 1; kill -9 $left 2>/dev/null; fi
    # wineserver's socket folder: /tmp/.wine-<uid>/server-<dev>-<inode of the prefix>, in hex
    # (Wine's server/request.c). Only that one folder, and the parent if nothing else is in it.
    if [ -d "$WINEPREFIX" ]; then
        set -- $(stat -f '%d %i' "$WINEPREFIX")
        sdir="/tmp/.wine-$(id -u)/server-$(printf '%x' "$1")-$(printf '%x' "$2")"
    fi
    if [ -n "$KEEP" ]; then say "kept: $TMP${sdir:+ (and $sdir)}"; return; fi
    rm -rf "$TMP"
    if [ -n "$sdir" ] && [ -d "$sdir" ] && [ -O "$sdir" ]; then rm -rf "$sdir"; rmdir "/tmp/.wine-$(id -u)" 2>/dev/null; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }
run() {   # seconds outfile command...: runs with a time limit, returns its status (124 = timed out)
    local limit="$1" out="$2" pid i rc; shift 2
    "$@" > "$out" 2>&1 < /dev/null &
    pid=$!
    i=0
    while kill -0 $pid 2>/dev/null; do
        if [ $i -ge $((limit * 10)) ]; then kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; return 124; fi
        sleep 0.1; i=$((i + 1))
    done
    wait $pid; rc=$?
    return $rc
}
step() {   # name limit expect-regex command...: one required step
    local name="$1" limit="$2" expect="$3" t0 t1 rc out; shift 3
    out="$TMP/out-$(printf '%s' "$name" | tr -c 'A-Za-z0-9' _).txt"
    say "== $name: $*"
    t0=$(now); run "$limit" "$out" "$@"; rc=$?; t1=$(now)
    sed 's/^/   | /' "$out" | tail -40 >> "$LOG"
    if [ $rc = 0 ] && grep -E -q "$expect" "$out"; then
        record "$name" PASS "($(echo "$t1 - $t0" | bc) s) $(grep -E -m1 "$expect" "$out" | tr -d '\r' | cut -c1-80)"
    else
        record "$name" FAIL "(exit $rc$( [ $rc = 124 ] && echo ', timed out')$( [ $rc = 137 ] && echo ', Killed: 9')) $(tr -d '\r' < "$out" | grep -v '^$' | tail -1 | cut -c1-100)"
    fi
}

# 2. Archive, unpack, signatures.
say "== archive"
if [ -f "$ARCHIVE.sha256" ]; then
    want=$(cut -d' ' -f1 "$ARCHIVE.sha256"); got=$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)
    if [ "$want" = "$got" ]; then record "archive sha256" PASS "$got"; else record "archive sha256" FAIL "got $got, want $want"; fi
else
    say "  (no $ARCHIVE.sha256 next to the archive: hash not checked)"
fi
t0=$(now)
if tar -xJf "$ARCHIVE" -C "$TMP" && [ -d "$ROOT" ]; then record "unpack" PASS "($(echo "$(now) - $t0" | bc) s) $(find "$ROOT" -type f | wc -l | tr -d ' ') files, $(du -sh "$ROOT" | cut -f1)"
else record "unpack" FAIL "tar failed or no $ENGINE_NAME folder"; exit 1; fi
gk=$(spctl -a -t exec -vv "$ROOT/lib/wine/x86_64-unix/wine" 2>&1 | tr '\n' ' ')
say "  Gatekeeper on the loader (informational; ADP Monitor removes quarantine): $gk"
xattr -dr com.apple.quarantine "$ROOT" 2>/dev/null
bad=0; n=0
# x86_64-only = a thin 64-bit Mach-O (magic cffaedfe) whose CPU type is x86_64 (07000001, little
# endian), as ADP Monitor's MachOArchs reads it. A universal file (cafebabe) or another CPU fails.
while IFS= read -r -d '' f; do
    h=$(head -c 8 "$f" | xxd -p)
    case "$h" in cffaedfe*|cefaedfe*|cafebabe*|bebafeca*|feedfacf*|feedface*) ;; *) continue ;; esac
    n=$((n + 1))
    [ "$h" = cffaedfe07000001 ] || { say "  not x86_64-only: ${f#$ROOT/}: header $h ($(file -b "$f" | cut -c1-80))"; bad=1; }
    codesign --verify --strict "$f" 2>>"$LOG" || { say "  bad signature: ${f#$ROOT/}"; bad=1; }
done < <(find "$ROOT" -type f ! -path '*-windows/*' -print0)
if [ $bad = 0 ]; then record "Mach-O arch and signatures" PASS "$n files, all x86_64, all valid"; else record "Mach-O arch and signatures" FAIL "see log"; fi
codesign -dvv "$ROOT/lib/wine/x86_64-unix/wine" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Authority|Timestamp|Runtime)' | sed 's/^/   | /' >> "$LOG"
codesign -d --entitlements - "$ROOT/lib/wine/x86_64-unix/wine" 2>/dev/null | sed 's/^/   | /' >> "$LOG"

WINE="$ROOT/bin/wine"; WINESERVER_BIN="$ROOT/bin/wineserver"
# 3-7. The engine.
step "wine --version" 30 '^wine-11\.18' "$WINE" --version
step "wineboot -u (new prefix)" 300 '.*' "$WINE" wineboot -u
# Wine writes the registry files (system.reg, user.reg) when wineserver exits, a few seconds after its
# last client, so wait for that before looking. If it is still up after 60 s, stop it and wait again.
run 60 "$TMP/wineserver-wait.txt" "$WINESERVER_BIN" -w; rc=$?
if [ $rc = 124 ]; then
    say "  wineserver still running 60 s after wineboot: stopping it (-k) and waiting"
    "$WINESERVER_BIN" -k >/dev/null 2>&1; run 30 "$TMP/wineserver-wait.txt" "$WINESERVER_BIN" -w
fi
if [ -f "$WINEPREFIX/system.reg" ]; then record "prefix has system.reg" PASS "$(wc -c < "$WINEPREFIX/system.reg" | tr -d ' ') bytes, after wineserver exited"
else record "prefix has system.reg" FAIL "no $WINEPREFIX/system.reg after wineserver exited"; fi
step "cmd /c ver (64-bit)" 60 'Microsoft Windows' "$WINE" cmd /c ver
step "syswow64 cmd /c ver (32-bit, WoW64)" 60 'Microsoft Windows' "$WINE" 'C:\windows\syswow64\cmd.exe' /c ver
step "hello64.exe" 60 'result: all passed' "$WINE" "$KIT/hello64.exe"
step "hello32.exe (WoW64)" 60 'result: all passed' "$WINE" "$KIT/hello32.exe"
grep -q 'wow64=1' "$TMP/out-hello32_exe__WoW64_.txt" 2>/dev/null || say "  note: hello32 did not report wow64=1"
say "  Wine processes still running:"; ps -axo pid,ppid,rss,command | grep -F "$TMP/" | grep -v grep | sed 's/^/   | /' | tee -a "$LOG"
"$WINESERVER_BIN" -k >/dev/null 2>&1; sleep 1

if [ -n "$MACDRV" ]; then
    say "== Mac driver (winemac.drv on)"
    WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree,mshtml=" step "cmd /c ver with the Mac driver" 90 'Microsoft Windows' "$WINE" cmd /c ver
    "$WINESERVER_BIN" -k >/dev/null 2>&1; sleep 1
fi

REQUIRED_FAILS=$FAILS
MATRIX_RESULTS=""
if [ -n "$MATRIX" ] && [ -d "$KIT/loaders" ]; then
    say "== entitlement matrix (informational)"
    # Same engine, same paths, same prefix: only the loader file is swapped. rm first, so each copy
    # is a new file (the kernel caches a file's signature; rewriting a signed file in place gets it
    # killed). The shipped loader is put back afterwards.
    LOADER="$ROOT/lib/wine/x86_64-unix/wine"
    cp -p "$LOADER" "$TMP/loader-shipped"
    for v in "$KIT"/loaders/*/; do
        v=$(basename "$v")
        "$WINESERVER_BIN" -k >/dev/null 2>&1; sleep 1
        rm -f "$LOADER"; cp "$KIT/loaders/$v/wine" "$LOADER"; chmod 755 "$LOADER"
        ents=$(codesign -d --entitlements - --xml "$LOADER" 2>/dev/null | grep -o 'com\.apple\.[a-z.-]*' | tr '\n' ' ')
        say "-- $v: entitlements: ${ents:-none}"
        line="$v:"
        for t in version cmd hello64 hello32; do
            case $t in
                version) set -- "$WINE" --version; expect='^wine-' ;;
                cmd) set -- "$WINE" cmd /c ver; expect='Microsoft Windows' ;;
                hello64) set -- "$WINE" "$KIT/hello64.exe"; expect='result: all passed' ;;
                hello32) set -- "$WINE" "$KIT/hello32.exe"; expect='result: all passed' ;;
            esac
            out="$TMP/matrix-$v-$t.txt"
            run 60 "$out" "$@"; rc=$?
            if [ $rc = 0 ] && grep -E -q "$expect" "$out"; then r=pass; else r="FAIL(exit $rc)"; fi
            sed "s/^/   | $v $t: /" "$out" | tail -8 >> "$LOG"
            line="$line $t=$r"
        done
        say "   $line"
        MATRIX_RESULTS="$MATRIX_RESULTS$line
"
    done
    "$WINESERVER_BIN" -k >/dev/null 2>&1; sleep 1
    rm -f "$LOADER"; cp -p "$TMP/loader-shipped" "$LOADER"
fi

say ""
say "================ summary: $ENGINE_NAME on $(hostname -s), macOS $(sw_vers -productVersion)"
printf '%s' "$RESULTS" | tee -a "$LOG"
[ -n "$MATRIX_RESULTS" ] && { say "entitlement matrix (full engine = both entitlements; see README.md):"; printf '%s' "$MATRIX_RESULTS" | sed 's/^/  /' | tee -a "$LOG"; }
if [ "$REQUIRED_FAILS" = 0 ]; then say "RESULT: PASS ($PASSES checks)"; exit 0; fi
say "RESULT: FAIL ($REQUIRED_FAILS of $((PASSES + REQUIRED_FAILS)) required checks failed; details in $LOG)"
exit 1
