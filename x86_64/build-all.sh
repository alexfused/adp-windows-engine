#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# The whole Intel engine, in order: fetch.sh, build-deps.sh, build-wine.sh, package.sh, archive.sh,
# verify.sh, verify.sh --archive. Each step is rerunnable on its own; this only chains them.
#   --clean   first delete every build, install and output tree (keeps downloads/, the unpacked
#             sources and the toolchain, which fetch.sh verifies again), so one guard summary
#             (work/guard/summary.tsv, copied to evidence/rosetta-guard.tsv) covers the whole build
# Usage: build-all.sh [--clean]

source "$(dirname "$0")/env.sh"
if [[ "${1:-}" == --clean ]]; then
    log "clean: removing build, install, guard and output trees"
    rm -rf "$BUILD" "$DEPS_DESTDIR" "$WINE_DESTDIR" "$NATIVE_DEPS" "$GUARD_LOG_DIR" "$DIST" "$WORK/archive-check" "$WORK/verify-unpacked"
fi
for step in fetch.sh build-deps.sh build-wine.sh package.sh archive.sh verify.sh "verify.sh --archive"; do
    log "---- $step"
    # shellcheck disable=SC2086
    "$SPIKE"/$step || die "$step failed"
done
log "all steps passed: $DIST/archive/$ENGINE_NAME.tar.xz, $DIST/testkit/$ENGINE_NAME-intel-test.tar"
