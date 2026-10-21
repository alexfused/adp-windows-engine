#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Delete what the Intel engine build leaves on this Mac. Nothing here was ever run (the engine is
# x86_64), so there are no processes, prefixes or Launch Services registrations to undo.
#   (default)  build and install trees, scratch copies, guard logs: keeps sources, downloads, dist/
#   --all      also dist/ (stage, archive, test kit), the unpacked sources and the toolchain;
#              downloads/ stays (verified files, reused by fetch.sh)
# Usage: cleanup.sh [--all]

source "$(dirname "$0")/env.sh"
rm -rf "$BUILD" "$DEPS_DESTDIR" "$WINE_DESTDIR" "$NATIVE_DEPS" "$GUARD_LOG_DIR" "$WORK/archive-check" "$WORK/verify-unpacked"
[[ "${1:-}" == --all ]] && rm -rf "$DIST" "$SRC" "$WORK/toolchains" "$WORK/tools"
log "cleaned ($(du -sh "$SPIKE" | cut -f1) left in $SPIKE)"
