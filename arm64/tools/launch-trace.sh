#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Where does a launch spend its time? Starts PuTTY 64 in a fresh clone of the golden prefix with
# Wine's timestamped process/module tracing, waits for its window, closes it politely, and prints
# the gaps longer than 0.4 s between consecutive trace lines. Shows one window for about 2 s.
# Usage: tools/launch-trace.sh [exe]
source "$(dirname "$0")/../env.sh"
source "$SPIKE/engine-env.sh"
set +e
exe="${1:-$DOWNLOADS/programs/putty64/putty.exe}"
export WINEPREFIX="$PREFIXES/trace"
rm -rf "$WINEPREFIX"; cp -Rc "$GOLDEN" "$WINEPREFIX"
out="$TESTLOGS/launch-trace.log"
t0=$(now)
WINEDEBUG=+timestamp,+process,+loaddll "$WINE" "$exe" > "$out" 2>&1 &
for _ in $(seq 1 240); do
    [[ -n "$("$WINLIST" "$ENGINE_ROOT/" | awk -F'\t' '$6 == 0 {split($5, d, "x"); if (d[1] > 100) print $1}')" ]] && break
    sleep 0.25
done
echo "window after $(echo "$(now) - $t0" | bc) s"
sleep 1
"$WINE" taskkill /im "$(basename "$exe")" > /dev/null 2>&1
wait_engine_exit 30 || "$WINESERVER" -k
# Lines start "<seconds>:<pid>:<tid>:..." with +timestamp.
awk -F: '$1 ~ /^[0-9]+\.[0-9]+$/ { t = $1 + 0; if (prev && t - prev > 0.4) printf "gap %.2f s before: %s\n", t - prev, substr($0, 1, 160); prev = t }' "$out"
