#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Record every process running from an engine folder until a stop file appears, so short-lived
# Wine processes are seen too. One procarch line per process per sample, then a summary.
# Usage: sample-procs.sh <engine root> <out.tsv> <stop file>
root="$1" out="$2" stop="$3"
procarch="$(dirname "$0")/../work/tools/procarch"
: > "$out.raw"
while [[ ! -e "$stop" ]]; do
    "$procarch" "$root/" 2>/dev/null >> "$out.raw"
    sleep 0.2
done
# One line per pid: pid, ppid, cputype, translated, max rss, path, name
sort -t$'\t' -k1,1n -k5,5nr "$out.raw" | awk -F'\t' '!seen[$1]++' > "$out"
rm -f "$out.raw"
