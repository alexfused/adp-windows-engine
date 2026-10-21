#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copy the result logs worth keeping from work/logs into evidence/<engine>/, with this checkout's
# path and the home folder shortened. Rerunnable.
source "$(dirname "$0")/../env.sh"
source "$SPIKE/engine-env.sh"
for f in programs.tsv programs.procs.tsv programs-tso.procs.tsv programs-quarantine.procs.tsv \
         programs.procs-summary.txt programs-quarantine.procs-summary.txt entitlement-matrix.out \
         quarantine-test.out smoke.out smoke.procs.tsv smoke-full.procs.tsv; do
    [[ -f "$WORK/logs/$f" ]] || continue
    sed -e "s|$SPIKE|<spike>|g" -e "s|$HOME|~|g" -- "$WORK/logs/$f" > "$EVIDENCE/$f"
done
ls -la "$EVIDENCE"
