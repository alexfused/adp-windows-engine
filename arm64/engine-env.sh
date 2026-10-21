# SPDX-License-Identifier: MIT
# Source after env.sh: how the test scripts run an engine tree. ENGINE_ROOT picks which one
# (default: the staged, signed engine). Prefixes and logs live under work/, results worth keeping
# under evidence/<engine name>/.
STAGE_NAME=$(cat "$DIST/stage/engine-arm64-"*"-$ENGINE_REV/ENGINE-NAME" 2>/dev/null | head -1 || true)
ENGINE_ROOT="${ENGINE_ROOT:-$DIST/stage/$STAGE_NAME}"
EVIDENCE="${EVIDENCE:-$SPIKE/evidence/$STAGE_NAME}"
mkdir -p "$EVIDENCE"
WINE="$ENGINE_ROOT/bin/wine"
WINESERVER="$ENGINE_ROOT/bin/wineserver"
PREFIXES="${PREFIXES:-$WORK/prefixes}"
GOLDEN="$PREFIXES/_golden"
TESTLOGS="$WORK/logs"
PROCARCH="$WORK/tools/procarch"
WINLIST="$WORK/tools/winlist"
mkdir -p "$PREFIXES" "$TESTLOGS"
export WINESERVER
# No Start-menu/Desktop entries, no Mono/Gecko download prompts (neither ships in this engine).
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-winemenubuilder.exe=d;mscoree,mshtml=}"
# WINEDEBUG stays at Wine's default so err: lines (self-repair evidence) reach the logs.
now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
oahd_cpu() { ps -o time= -p "$(pgrep -x oahd | head -1)" 2>/dev/null | tr -d ' ' || echo none; }
engine_pids() { "$PROCARCH" "$ENGINE_ROOT/" 2>/dev/null | cut -f1; }
wait_engine_exit() {  # seconds; 0 when every engine process is gone
    local i
    for ((i = 0; i < $1 * 4; i++)); do [[ -z "$(engine_pids)" ]] && return 0; sleep 0.25; done
    return 1
}
