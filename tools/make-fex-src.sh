#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Make downloads/own/fex-<FEX_COMMIT>-src.tar.xz: `git archive` of FEX at FEX_COMMIT plus each submodule the build
# compiles (FEX_SUBMODULES) at the commit FEX records for it, and SUBMODULES-ADP.txt listing every submodule and
# whether it is included. tools/dettar.py makes the same bytes from the same commits, so the result must have the
# SHA-256 release.conf pins (FEX_SRC_SHA256); the script fails otherwise.
# FEX_GIT: a FEX clone that has FEX_COMMIT and those submodules' commits (for example the arm64 build's
# work/src/fex). Reads that clone; writes only downloads/own/ and downloads/work/fex-tar/.
# Usage: FEX_GIT=/path/to/fex tools/make-fex-src.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '3,9p' "$0"; exit 0; }
source "$ROOT/release.conf"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ -d "${FEX_GIT:-}" ]] || die "set FEX_GIT to a FEX clone holding $FEX_COMMIT"
out="$ROOT/downloads/own/fex-$FEX_COMMIT-src.tar.xz"
t="$ROOT/downloads/work/fex-tar"; rm -rf "$t"; mkdir -p "$t/extra" "$(dirname "$out")"
prefix="fex-$FEX_COMMIT"
git -C "$FEX_GIT" archive --format=tar -o "$t/fex.tar" "$FEX_COMMIT"
args=(--tar "$t/fex.tar" "$prefix")
{
    echo "FEX $FEX_COMMIT with the submodules that the ADP Monitor engine build compiles"
    echo "(work/build/fex-*/build.ninja: External/fmt, xxhash, range-v3, unordered_dense, rpmalloc and"
    echo "Source/Common/cpp-optparse). The other submodules are left out: the build options used"
    echo "(BUILD_TESTING=False, no VIXL, Zydis, tracy, jemalloc, thunks) do not use them, and the three"
    echo "*-bins submodules hold prebuilt Linux test binaries."
    echo
    printf '%-45s %-42s %s\n' path commit included
    git -C "$FEX_GIT" config -f .gitmodules --get-regexp '^submodule\..*\.path$' | while read -r key path; do
        commit=$(git -C "$FEX_GIT" ls-tree "$FEX_COMMIT" "$path" | awk '{print $3}')
        url=$(git -C "$FEX_GIT" config -f .gitmodules --get "${key%.path}.url")
        inc=no; [[ " $FEX_SUBMODULES " == *" $path "* ]] && inc=yes
        printf '%-45s %-42s %s  %s\n' "$path" "$commit" "$inc" "$url"
    done
} > "$t/extra/SUBMODULES-ADP.txt"
for p in $FEX_SUBMODULES; do
    commit=$(git -C "$FEX_GIT" ls-tree "$FEX_COMMIT" "$p" | awk '{print $3}')
    [[ -n "$commit" ]] || die "no submodule $p at $FEX_COMMIT"
    f="$t/$(echo "$p" | tr / _).tar"
    git -C "$FEX_GIT/$p" archive --format=tar -o "$f" "$commit"
    args+=(--tar "$f" "$prefix/$p")
done
args+=(--dir "$t/extra" "$prefix" --mtime "$SOURCE_DATE_EPOCH")
python3 -I "$HERE/dettar.py" "$out" "${args[@]}"
rm -rf "$t"
got=$(shasum -a 256 "$out" | cut -d' ' -f1)
[[ "$got" == "$FEX_SRC_SHA256" ]] || die "$out has SHA-256 $got, release.conf pins $FEX_SRC_SHA256"
echo "==> $out: SHA-256 matches release.conf"
