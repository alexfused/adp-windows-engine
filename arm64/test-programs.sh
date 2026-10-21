#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run the test programs as Mac windows on the arm64 engine, each in its own prefix cloned from
# the golden one (cp -c), and record per launch: seconds to the first window, a screenshot of
# that window only (screencapture -l), summed RSS of the engine's processes, and whether it
# closed cleanly. Two launches per program, each with a new wineserver. Proof of no Rosetta:
# every engine process seen during the run (sampled every 0.2 s) must be arm64 and not
# translated, oahd's CPU time must not move, no oahd-helper may appear, and Rosetta's log
# subsystem must stay silent for the run.
# Only windows owned by engine processes are looked at; nothing is clicked or typed. Windows
# stay up about 3 s. Results: work/logs/programs.tsv, screenshots: evidence/<engine>/.
# Usage: test-programs.sh [program...]   programs: putty64 putty32 7zip npp (default: all)
#        HADRON_HARDWARE_TSO=1 to have Wine and FEX use the hardware TSO mode.

source "$(dirname "$0")/env.sh"
source "$SPIKE/engine-env.sh"
set +e
[[ -x "$WINE" ]] || die "no engine at $ENGINE_ROOT"
"$SPIKE/golden.sh" >/dev/null || die "golden prefix failed"
P="$DOWNLOADS/programs"
TAG="${TAG:-}"   # appended to labels and screenshot names (e.g. -quarantine)
results="$TESTLOGS/programs.tsv"
programs=("${@:-putty64 putty32 7zip npp}"); read -r -a programs <<< "${programs[*]}"

stop="$TESTLOGS/programs$TAG.stop"; procs="$TESTLOGS/programs$TAG.procs.tsv"; rm -f "$stop"
"$SPIKE/tools/sample-procs.sh" "$ENGINE_ROOT" "$procs" "$stop" & sampler=$!
( : > "$TESTLOGS/oahd-helper$TAG.seen"; while [[ ! -e "$stop" ]]; do pgrep -fl 'oahd-helper|oahd-root-helper' >> "$TESTLOGS/oahd-helper$TAG.seen"; sleep 0.5; done ) &
oahd0=$(oahd_cpu); logstart=$(date '+%Y-%m-%d %H:%M:%S')

launch() {  # name label exe args... ; prints "seconds rss_mb wid" or NOWINDOW
    local name="$1" label="$2" exe="$3" t0 t1 wid pid tries=0; shift 3
    t0=$(now)
    ( cd "$(dirname "$exe")" && exec "$WINE" "$exe" "$@" ) >> "$TESTLOGS/$name$TAG.log" 2>&1 &
    pid=$!
    while ((tries < 480)); do   # up to 120 s
        wid=$("$WINLIST" "$ENGINE_ROOT/" | awk -F'\t' '$6 == 0 {split($5, d, "x"); if (d[1] > 100 && d[2] > 60) {print $1; exit}}')
        [[ -n "$wid" ]] && { t1=$(now); break; }
        kill -0 $pid 2>/dev/null || break
        sleep 0.25; tries=$((tries + 1))
    done
    [[ -n "$wid" ]] || { echo NOWINDOW; return; }
    sleep 2   # let it finish painting
    screencapture -x -o -l"$wid" "$EVIDENCE/$name$TAG-$label.png" 2>> "$TESTLOGS/$name$TAG.log"
    local rss; rss=$("$PROCARCH" "$ENGINE_ROOT/" 2>/dev/null | awk -F'\t' '{s += $5} END {printf "%.0f", s / 1024}')
    local title; title=$("$WINLIST" "$ENGINE_ROOT/" | awk -F'\t' -v w="$wid" '$1 == w {print $4}')
    echo "$(echo "$t1 - $t0" | bc) $rss $wid \"$title\""
}

close_prog() {  # polite close (WM_CLOSE through taskkill without /f), then wait for every engine process to exit
    "$WINE" taskkill /im "$1" >> "$TESTLOGS/$2$TAG.log" 2>&1
    if wait_engine_exit 30; then echo clean; else "$WINESERVER" -k; wait_engine_exit 10; echo "killed-after-30s"; fi
}

for prog in "${programs[@]}"; do
    case $prog in
        putty64) exe_rel=""; src="$P/putty64/putty.exe" ;;
        putty32) exe_rel=""; src="$P/putty32/putty.exe" ;;
        7zip)    exe_rel="drive_c/Program Files/7-Zip/7zFM.exe" ;;
        npp)     exe_rel="drive_c/npp/notepad++.exe" ;;
        *) die "unknown program $prog" ;;
    esac
    export WINEPREFIX="$PREFIXES/$prog$TAG"
    rm -rf "$WINEPREFIX"; t0=$(now); cp -Rc "$GOLDEN" "$WINEPREFIX"; clone_s=$(echo "$(now) - $t0" | bc)
    : > "$TESTLOGS/$prog$TAG.log"
    extra=""
    case $prog in
        7zip)
            t0=$(now)
            "$WINE" "$P/sevenzip/7z2604-x64.exe" /S >> "$TESTLOGS/$prog$TAG.log" 2>&1; rc=$?
            "$WINESERVER" -w
            extra="installer_rc=$rc installer_s=$(echo "$(now) - $t0" | bc)"
            exe="$WINEPREFIX/$exe_rel" ;;
        npp)
            mkdir -p "$WINEPREFIX/drive_c/npp"; cp -Rc "$P/npp/unpacked/." "$WINEPREFIX/drive_c/npp/"
            exe="$WINEPREFIX/$exe_rel" ;;
        *) exe="$src" ;;
    esac
    [[ -f "$exe" ]] || { printf '%s\tFAIL\tno %s\t%s\n' "$prog$TAG" "$exe" "$extra" | tee -a "$results"; continue; }
    r1=$(launch "$prog" first "$exe"); c1=$(close_prog "$(basename "$exe")" "$prog")
    r2=$(launch "$prog" second "$exe"); c2=$(close_prog "$(basename "$exe")" "$prog")
    ok=pass; [[ "$r1" == NOWINDOW || "$r2" == NOWINDOW ]] && ok=FAIL
    printf '%s\t%s\tclone_s=%s\t%s\tlaunch1(s rss_mb wid title)=%s\tclose1=%s\tlaunch2=%s\tclose2=%s\tprefix=%s\ttso=%s\n' \
        "$prog$TAG" "$ok" "$clone_s" "$extra" "$r1" "$c1" "$r2" "$c2" \
        "$(du -sk "$WINEPREFIX" | awk '{printf "%.0fMB", $1/1024}')" "${HADRON_HARDWARE_TSO:-0}" | tee -a "$results"
done

touch "$stop"; wait "$sampler" 2>/dev/null; sleep 0.6
oahd1=$(oahd_cpu)
n=$(wc -l < "$procs" | tr -d ' '); bad=$(awk -F'\t' '$3 != "arm64" || $4 != 0' "$procs" | wc -l | tr -d ' ')
helpers=$(sort -u "$TESTLOGS/oahd-helper$TAG.seen" | wc -l | tr -d ' ')
oahlog=$(/usr/bin/log show --start "$logstart" --style compact \
    --predicate 'process BEGINSWITH "oah" OR subsystem BEGINSWITH "com.apple.oah" OR sender BEGINSWITH "liboah"' 2>/dev/null | grep -c -v -E '^(Timestamp|Filtering)' )
printf 'rosetta-proof%s\tprocesses_seen=%s\tnot_native=%s\toahd_cpu_before=%s\toahd_cpu_after=%s\toahd_helpers_seen=%s\toah_log_lines=%s\n' \
    "$TAG" "$n" "$bad" "$oahd0" "$oahd1" "$helpers" "$oahlog" | tee -a "$results"
cut -f3,4,6,7 "$procs" | sed "s|$ENGINE_ROOT|<engine>|" | sort | uniq -c | sort -rn > "$TESTLOGS/programs$TAG.procs-summary.txt"
