#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Headless checks of one engine tree, no windows (the Mac driver is turned off):
#   wine --version; prefix creation (wineboot -u) or a clone of the golden prefix;
#   cmd /c ver (native arm64 Windows code); hello-x86_64.exe (x86_64 through FEX, xtajit64.dll);
#   hello-i686.exe and syswow64\cmd.exe (i386 through FEX's WoW64 DLL, xtajit.dll);
#   tls-check-x86_64.exe (bcrypt RSA/AES and a schannel ClientHello on lib/ext's GnuTLS).
# Every engine process seen is checked for arm64 and not translated (tools/procarch).
# Prints one TSV result line per check and a summary; exit 0 only if everything passed.
# Usage: smoke.sh [--fresh-prefix] [--label NAME]   (ENGINE_ROOT picks the engine tree)

source "$(dirname "$0")/env.sh"
source "$SPIKE/engine-env.sh"
set +e   # a failed check is a result, not the end of the run
fresh=; label=smoke
while (($#)); do case $1 in --fresh-prefix) fresh=1 ;; --label) label="$2"; shift ;; *) die "unknown option $1" ;; esac; shift; done
H="$DOWNLOADS/programs/hello"
[[ -f "$H/hello-i686.exe" && -f "$H/tls-check-x86_64.exe" ]] || die "run programs.sh first"
export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;winemac.drv=d"
pfx="$PREFIXES/$label"; logf="$TESTLOGS/$label.log"; : > "$logf"
procs="$TESTLOGS/$label.procs.tsv"; stop="$TESTLOGS/$label.stop"; rm -f "$stop"
"$SPIKE/tools/sample-procs.sh" "$ENGINE_ROOT" "$procs" "$stop" & sampler=$!
fails=0
check() {  # name expected-substring command...
    local name="$1" want="$2" t0 out rc; shift 2
    t0=$(now)
    out=$("$@" 2>>"$logf"); rc=$?
    echo "--- $name rc=$rc: $out" >> "$logf"
    if [[ $rc -eq 0 && "$out" == *"$want"* ]]; then r=pass; else r=FAIL; fails=$((fails + 1)); fi
    printf '%s\t%s\t%s\trc=%s\t%.1fs\t%s\n' "$label" "$name" "$r" "$rc" "$(echo "$(now) - $t0" | bc)" "$(echo "$out" | tr -d '\r' | tr '\n' ' ' | cut -c1-90)"
}
check version wine- "$WINE" --version
rm -rf "$pfx"
if [[ -n $fresh || ! -f "$GOLDEN/system.reg" ]]; then
    export WINEPREFIX="$pfx"
    check wineboot "prefix ready" sh -c '"$0" wineboot -u && "$1" -w && test -f "$WINEPREFIX/system.reg" && echo prefix ready' "$WINE" "$WINESERVER"
else
    t0=$(now); cp -Rc "$GOLDEN" "$pfx"; printf '%s\tclone-golden\tpass\trc=0\t%.1fs\n' "$label" "$(echo "$(now) - $t0" | bc)"
    export WINEPREFIX="$pfx"
fi
check cmd-arm64 "Microsoft Windows" "$WINE" cmd /c ver
check hello-x86_64 "hello from x86_64" "$WINE" "$H/hello-x86_64.exe"
check hello-i686 "hello from i386" "$WINE" "$H/hello-i686.exe"
check cmd-i386 "Microsoft Windows" "$WINE" 'C:\windows\syswow64\cmd.exe' /c ver
check crypto-gnutls "crypto ok" "$WINE" "$H/tls-check-x86_64.exe"
# Which emulator DLL each x86 program loaded.
WINEDEBUG=+loaddll "$WINE" "$H/hello-x86_64.exe" 2>&1 | grep -i -E 'xtajit|fex' | head -2 >> "$logf"
WINEDEBUG=+loaddll "$WINE" "$H/hello-i686.exe" 2>&1 | grep -i -E 'xtajit|fex|wow64cpu' | head -3 >> "$logf"
"$WINESERVER" -w 2>/dev/null || true
touch "$stop"; wait "$sampler" 2>/dev/null
n=$(wc -l < "$procs" | tr -d ' ')
bad=$(awk -F'\t' '$3 != "arm64" || $4 != 0' "$procs" | wc -l | tr -d ' ')
[[ $bad -eq 0 && $n -gt 0 ]] || fails=$((fails + 1))
printf '%s\tprocesses\t%s\t%s seen, %s not native arm64\n' "$label" "$([[ $bad -eq 0 && $n -gt 0 ]] && echo pass || echo FAIL)" "$n" "$bad"
wait_engine_exit 20 || { "$WINESERVER" -k 2>/dev/null; echo "$label: engine processes left, killed" >&2; }
printf '%s\tsummary\t%s\t%s failure(s)\n' "$label" "$([[ $fails -eq 0 ]] && echo PASS || echo FAIL)" "$fails"
[[ $fails -eq 0 ]]
