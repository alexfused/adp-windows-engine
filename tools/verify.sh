#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Check the assembled release before anything is published. Read-only except for downloads/work/.
#   1. every file in downloads/release/ matches SHA256SUMS; nothing extra; no file over GitHub's 2 GiB asset limit
#   2. the manifests: every "url" (and "urls" entry) is BASE_URL/<a file of this release>, with that file's
#      SHA-256 and size where the manifest gives them; each archive has the SHA-256 release.conf pins
#   3. arm64/ and x86_64/ are what tools/import-build-scripts.py makes from the commits that built the engines,
#      and the two build tarballs hold exactly those folders
#   4. from the release files alone, for each engine: unpack its build tarball, run its unpack-sources.sh on the
#      release's source files, and compare the result file by file with the trees the engine was built from
#      (ARM64_SPIKE/work/src, X86_64_SPIKE/work/src): Wine and FEX patched, and every library tarball
#   5. every LGPL/GPL component in components.json names source files that are in the release
#   6. nothing that will be published contains a token or private key
#   7. the engine guard (tools/engine-guard.py archives): no Mach-O file signed as ADP Monitor, none accepted by
#      the root helper's requirement, no build path outside tools/path-scan.allow, no personal path
#   8. no personal path in the repository files or in any release file (tarballs read member by member)
# Usage: tools/verify.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '3,17p' "$0"; exit 0; }
source "$ROOT/release.conf"
REL="$ROOT/downloads/release"; SRCS="$ROOT/downloads/release-sources"; V="$ROOT/downloads/work/verify"
fails=0
ok() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
note() { printf 'note  %s\n' "$*"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
dircmp() { python3 -I "$HERE/dircmp.py" "$@"; }
rm -rf "$V"; mkdir -p "$V"

# 1
if (cd "$REL" && shasum -a 256 -c --quiet SHA256SUMS); then ok "downloads/release/: $(wc -l < "$REL/SHA256SUMS" | tr -d ' ') files match SHA256SUMS"; else bad "SHA256SUMS mismatch"; fi
extra=$(cd "$REL" && ls | grep -vxF -f <(cut -d' ' -f3 SHA256SUMS) | grep -vx SHA256SUMS || true)
[[ -z "$extra" ]] && ok "no file in downloads/release/ is missing from SHA256SUMS" || bad "not in SHA256SUMS: $extra"
big=$(find "$REL" -type f -size +2147483647c)
[[ -z "$big" ]] && ok "every asset is under 2 GiB (largest: $(ls -S "$REL" | head -1))" || bad "over 2 GiB: $big"
if diff <(sort "$SRCS/SHA256SUMS") <(grep -F -f <(cut -d' ' -f3 "$SRCS/SHA256SUMS" | sed 's/^/  /') "$REL/SHA256SUMS" | sort) > /dev/null; then
    ok "release-sources/SHA256SUMS agrees with release/SHA256SUMS"; else bad "release-sources and release disagree"; fi

# 2
if python3 -I - "$REL" "$BASE_URL" "$ROOT/manifests" "$ARM64_ARCHIVE_SHA256" "$X86_64_ARCHIVE_SHA256" <<'EOF'
import json, os, sys
rel, base, mdir, *pins = sys.argv[1:]
sums = dict(reversed(l.split("  ", 1)) for l in open(os.path.join(rel, "SHA256SUMS")).read().splitlines())
bad = 0
def walk(node, where, found):
    if isinstance(node, dict):
        if "url" in node:
            found.append((where, node["url"], node.get("sha256"), node.get("bytes")))
        for u in node.get("urls", []) if isinstance(node.get("urls"), list) else []:
            found.append((where + ".urls", u, node.get("sha256"), node.get("bytes")))
        for k, v in node.items():
            walk(v, f"{where}.{k}", found)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, f"{where}[{i}]", found)
for f in sorted(os.listdir(mdir)):
    m = json.load(open(os.path.join(mdir, f)))
    if open(os.path.join(mdir, f), "rb").read() != open(os.path.join(rel, f), "rb").read():
        print(f"  {f}: differs from the copy in downloads/release"); bad += 1
    if m["archive"]["sha256"] not in pins:
        print(f"  {f}: archive SHA-256 is not one release.conf pins"); bad += 1
    found = []
    walk(m, "manifest", found)
    for where, url, digest, size in found:
        name = url[len(base) + 1:] if url.startswith(base + "/") else None
        if name is None or name not in sums:
            print(f"  {f}: {where}: {url} is not a file of this release"); bad += 1; continue
        if digest and sums[name] != digest:
            print(f"  {f}: {where}: SHA-256 differs from SHA256SUMS"); bad += 1
        if size and os.path.getsize(os.path.join(rel, name)) != size:
            print(f"  {f}: {where}: size differs"); bad += 1
    print(f"  {f}: {len(found)} urls, all files of this release")
sys.exit(1 if bad else 0)
EOF
then ok "every url in the manifests is $BASE_URL/<file> with matching hashes and sizes"; else bad "manifest check"; fi

# 3
if python3 -I "$HERE/import-build-scripts.py" --check > "$V/import-check.log"; then
    ok "arm64/ and x86_64/ are a fresh import of ${ARM64_SCRIPTS_COMMIT:0:12} and ${X86_64_SCRIPTS_COMMIT:0:12}"
else bad "arm64/ or x86_64/ differs from a fresh import: $V/import-check.log"; fi
for e in arm64 x86_64; do
    eng=$( [[ $e == arm64 ]] && echo "$ARM64_ENGINE" || echo "$X86_64_ENGINE" )
    b="adp-$eng-build"; mkdir -p "$V/tar-$e"; tar -xf "$SRCS/$b.tar.xz" -C "$V/tar-$e"
    if dircmp "$ROOT/$e" "$V/tar-$e/$b" > "$V/tar-$e.log"; then ok "$b.tar.xz holds exactly $e/"; else bad "$b.tar.xz differs from $e/: $V/tar-$e.log"; fi
done

# 4: Apple silicon
B="adp-$ARM64_ENGINE-build"; A="$V/tar-arm64/$B"
if ADP_NO_TOOLCHAIN=1 "$A/unpack-sources.sh" "$SRCS" > "$V/arm64-unpack.log" 2>&1; then
    IGN=(--ignore .git --ignore .adp-patches --ignore .adp-release)
    if dircmp "$A/work/src/wine" "$ARM64_SPIKE/work/src/wine" "${IGN[@]}" > "$V/arm64-wine.log"; then
        ok "arm64: release Wine + 30 Hadron patches = the tree the engine was built from ($(tail -1 "$V/arm64-wine.log" | awk '{print $1}') files)"
    else bad "arm64: patched Wine differs: $V/arm64-wine.log"; fi
    # Left out of the release: the submodules the build does not compile (SUBMODULES-ADP.txt), and submodules
    # nested in the ones it does (the build tree has them from `submodule update --recursive`; today only
    # range-v3's doc/gh-pages, its generated HTML documentation).
    skip=(); for p in $FEX_SUBMODULES; do
        skip+=(--ignore "$p/.git")
        [[ -f "$A/work/src/fex/$p/.gitmodules" ]] || continue
        while read -r nested; do skip+=(--ignore "$p/$nested"); done \
            < <(sed -n 's/^[[:space:]]*path = //p' "$A/work/src/fex/$p/.gitmodules")
    done
    while read -r path commit inc rest; do [[ "$inc" == no ]] && skip+=(--ignore "$path"); done \
        < <(tail -n +8 "$A/work/src/fex/SUBMODULES-ADP.txt")
    if dircmp "$A/work/src/fex" "$ARM64_SPIKE/work/src/fex" "${IGN[@]}" --ignore SUBMODULES-ADP.txt "${skip[@]}" > "$V/arm64-fex.log"; then
        ok "arm64: release FEX + 5 Hadron patches = the tree the engine was built from, with the 6 submodules it compiles ($(tail -1 "$V/arm64-fex.log" | awk '{print $1}') files)"
    else bad "arm64: patched FEX differs: $V/arm64-fex.log"; fi
    n=0; m=0
    while IFS=$'\t' read -r name version file rest; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        n=$((n + 1))
        [[ "$(sha "$A/downloads/ext/$name/$file")" == "$(sha "$ARM64_SPIKE/downloads/ext/$name/$file")" ]] && m=$((m + 1)) \
            || echo "  $file differs from the build's copy"
    done < "$A/ext.conf"
    [[ $n == "$m" ]] && ok "arm64: the $n lib/ext source files from the release are the files build-ext.sh built from" \
        || bad "arm64: $((n - m)) lib/ext source files differ"
else bad "arm64: unpack-sources.sh failed: $V/arm64-unpack.log"; fi

# 4: Intel
B="adp-$X86_64_ENGINE-build"; X="$V/tar-x86_64/$B"
mingw=$(ls "$X86_64_SPIKE"/downloads/llvm-mingw/*.tar.xz 2>/dev/null | head -1 || true)
if LLVM_MINGW_TARBALL="$mingw" "$X/unpack-sources.sh" "$SRCS" > "$V/x86_64-unpack.log" 2>&1; then
    trees=0; same=0
    for d in "$X"/work/src/*/; do
        t=$(basename "$d"); trees=$((trees + 1))
        if dircmp "$d" "$X86_64_SPIKE/work/src/$t" > "$V/x86_64-$t.log"; then same=$((same + 1)); else echo "  $t differs: $V/x86_64-$t.log"; fi
    done
    [[ $trees -gt 0 && $trees == "$same" ]] \
        && ok "x86_64: release sources + 16 Hadron patches + 3 of ours = the $trees trees the engine was built from ($(ls "$X/work/src" | tr '\n' ' '))" \
        || bad "x86_64: $((trees - same)) of $trees source trees differ"
else bad "x86_64: unpack-sources.sh failed: $V/x86_64-unpack.log"; fi
rm -rf "$A/work" "$A/downloads" "$X/work" "$X/downloads"   # source trees and toolchain: large, and already compared

# 5
if python3 -I - "$ROOT/components.json" "$SRCS/SHA256SUMS" <<'EOF'
import json, re, sys
comps = json.load(open(sys.argv[1]))["components"]
have = {l.split("  ", 1)[1] for l in open(sys.argv[2]).read().splitlines()}
bad = 0
for c in comps:
    copyleft = re.search(r"\b(L?GPL)", c["licence"]) and not re.match(r"FTL \(chosen", c["licence"])
    missing = [s for s in c.get("source", []) if s not in have]
    if missing or (copyleft and not c.get("source")) or ("built from source" in c["name"] and len(c.get("source", [])) < 2):
        print(f"  {c['engine']}: {c['name']}: {'missing ' + str(missing) if missing else 'no source file named'}")
        bad += 1
print(f"  {len(comps)} components, {sum(1 for c in comps if c.get('source'))} with source files")
sys.exit(1 if bad else 0)
EOF
then ok "every LGPL/GPL and every built-from-source component names its source files, all in the release"; else bad "source coverage"; fi

# 6
pub=("$ROOT"/{README.md,NOTICE.md,THIRD-PARTY-LICENSES.md,LICENSE,RELEASE-NOTES.md,components.json,release.conf,publish-release.sh,.gitignore}
     "$ROOT"/{tools,arm64,x86_64,overlay,manifests,licenses})
if grep -rIlE 'gh[opsu]_[A-Za-z0-9]{20,}|github_pa[t]_[A-Za-z0-9_]{20,}|BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|xox[bp]-[0-9]' "${pub[@]}"; then
    bad "possible secret in a file to be published (listed above)"; else ok "no tokens or private keys in the files to be published"; fi

# 7
if python3 -I "$HERE/engine-guard.py" archives "$V/guard" "$REL/$(basename "$ARM64_ARCHIVE")" "$REL/$(basename "$X86_64_ARCHIVE")" > "$V/guard.log" 2>&1; then
    ok "engine guard: no file signed as $ADP_MONITOR_BUNDLE_ID or accepted by the root helper, no unexplained build path, no personal path ($V/guard/)"
else bad "engine guard refused an engine: $V/guard.log"; fi

# 8
if python3 -I "$HERE/engine-guard.py" personal "${pub[@]}" "$REL" > "$V/personal.log" 2>&1; then
    ok "no personal path in the repository files or the $(wc -l < "$REL/SHA256SUMS" | tr -d ' ') release files"
else bad "personal paths found: $V/personal.log"; fi

echo
[[ $fails == 0 ]] && echo "verify: all checks passed" || { echo "verify: $fails check(s) failed"; exit 1; }
