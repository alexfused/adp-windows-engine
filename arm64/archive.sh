#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Pack the staged (signed, notarised, stapled) engine for the app's engine manager:
#   dist/archive/<engine>.tar.xz          what gets hosted
#   dist/archive/<engine>.tar.xz.sha256
#   dist/archive/<engine>.manifest.json   version, url placeholder, sha256, sizes, layout, signing
# Then unpacks the archive into a scratch folder and checks it: same file list, every Mach-O's
# signature, WineHost.app's stapled ticket, wine --version.
# The url in the manifest is a placeholder until the engine is hosted (ENGINE_URL overrides it).
# Usage: archive.sh

source "$(dirname "$0")/env.sh"
source "$SPIKE/engine-env.sh"
STAGE="$DIST/stage/$STAGE_NAME"; APP="$STAGE/lib/wine/aarch64-unix/WineHost.app"
[[ -d "$STAGE" ]] || die "run package.sh first"
notarized=false; xcrun stapler validate "$APP" > /dev/null 2>&1 && notarized=true
out="$DIST/archive"; mkdir -p "$out"
tarball="$out/$STAGE_NAME.tar.xz"
log "packing $tarball (notarised: $notarized)"
t0=$(date +%s)
rm -f "$tarball"
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --options xz:compression-level=9,xz:threads=0 -cJf "$tarball" -C "$DIST/stage" "$STAGE_NAME"
pack_s=$(( $(date +%s) - t0 ))
sha=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
echo "$sha  $(basename "$tarball")" > "$tarball.sha256"
bytes=$(stat -f %z "$tarball")
log "$(du -h "$tarball" | cut -f1) in ${pack_s} s, sha256 $sha"

log "checking an unpacked copy"
check="$WORK/archive-check"; rm -rf "$check"; mkdir -p "$check"
t0=$(date +%s); tar -xJf "$tarball" -C "$check"; unpack_s=$(( $(date +%s) - t0 ))
diff <(cd "$STAGE" && find . | sort) <(cd "$check/$STAGE_NAME" && find . | sort) > /dev/null || die "file list differs after unpacking"
bad=0
while IFS= read -r -d '' f; do
    [[ "$(head -c 4 "$f" | xxd -p)" == cffaedfe ]] || continue
    codesign --verify --strict "$f" 2>/dev/null || { echo "bad signature: $f"; bad=1; }
done < <(find "$check/$STAGE_NAME" -type f ! -path '*-windows/*' -print0)
codesign --verify --strict "$check/$STAGE_NAME/lib/wine/aarch64-unix/WineHost.app" || bad=1
[[ $notarized == false ]] || xcrun stapler validate "$check/$STAGE_NAME/lib/wine/aarch64-unix/WineHost.app" > /dev/null || bad=1
ver=$("$check/$STAGE_NAME/bin/wine" --version) || bad=1
[[ $bad == 0 ]] || die "the unpacked archive does not verify"
log "unpacked in ${unpack_s} s, signatures ok, $ver"
unpacked_bytes=$(find "$check/$STAGE_NAME" -type f -print0 | xargs -0 stat -f %z | awk '{s += $1} END {print s}')
files=$(find "$check/$STAGE_NAME" -type f | wc -l | tr -d ' ')
rm -rf "$check"

notary_id=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$EVIDENCE/notary-engine.json" 2>/dev/null || echo "")
python3 -I - "$out/$STAGE_NAME.manifest.json" "$EXT_ROOT/BUILD-RECORD.tsv" <<EOF
import json, plistlib, subprocess, sys
ents = plistlib.loads(subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", "$APP"], capture_output=True).stdout)
ext = []
for line in open(sys.argv[2]).read().splitlines()[1:]:
    name, version, file, sha, url, conf = line.split("\t")
    ext.append({"name": name, "version": version, "file": file, "sha256": sha, "url": url})
manifest = {
    "schema": 1,
    "kind": "adp-monitor-windows-engine",
    "name": "$STAGE_NAME",
    "version": "${STAGE_NAME#engine-arm64-}",
    "wineVersion": "$(sed -n 's/^Wine version //p' "$WINE_SRC/VERSION")",
    "arch": "arm64",
    "minimumMacOS": "27.0",
    "rosetta": False,
    "archive": {
        "format": "tar.xz",
        "url": "${ENGINE_URL:-https://REPLACE-WITH-HOSTED-URL/$STAGE_NAME.tar.xz}",
        "sha256": "$sha",
        "bytes": $bytes,
    },
    "unpacked": {"bytes": $unpacked_bytes, "files": $files},
    "layout": {
        "root": "$STAGE_NAME",
        "wine": "bin/wine",
        "wineserver": "bin/wineserver",
        "loaderApp": "lib/wine/aarch64-unix/WineHost.app",
        "loader": "lib/wine/aarch64-unix/WineHost.app/Contents/MacOS/wine",
        "emulators": {"x86_64": "lib/wine/aarch64-windows/xtajit64.dll", "i386": "lib/wine/aarch64-windows/xtajit.dll"},
        "licenses": "licenses",
    },
    "healthCheck": {"argv": ["bin/wine", "--version"], "stdoutPrefix": "wine-"},
    "environment": {"WINEDLLOVERRIDES": "winemenubuilder.exe=d;mscoree,mshtml="},
    "signing": {
        "teamID": "2F2FVY326V",
        "loaderBundleID": "$BUNDLE_ID",
        "otherFilesIdentifierPrefix": "$BUNDLE_ID.",
        "loaderEntitlements": sorted(ents),
        "notarized": $( [[ $notarized == true ]] && echo True || echo False ),
        "notarySubmission": "$notary_id",
        "stapled": ["lib/wine/aarch64-unix/WineHost.app"] if $( [[ $notarized == true ]] && echo True || echo False ) else [],
    },
    "sources": {
        "wine": {"url": "https://gitlab.winehq.org/wine/wine.git", "commit": "$(cut -d@ -f2 "$WINE_SRC/.adp-patches")",
                 "hadronPatches": "$(cut -d@ -f1 "$WINE_SRC/.adp-patches" | xargs)"},
        "fex": {"url": "https://github.com/FEX-Emu/FEX.git", "commit": "$(cut -d@ -f2 "$FEX_SRC/.adp-patches")",
                "hadronPatches": "$(cut -d@ -f1 "$FEX_SRC/.adp-patches" | xargs)"},
        "hadron": {"url": "$HADRON_URL", "commit": "$HADRON_REF"},
        "llvmMingw": {"version": "$LLVM_MINGW_VERSION", "url": "$LLVM_MINGW_URL", "sha256": "$LLVM_MINGW_SHA256"},
        "libExt": ext,
    },
}
json.dump(manifest, open(sys.argv[1], "w"), indent=2)
print(json.dumps(manifest["archive"]))
EOF
cp "$out/$STAGE_NAME.manifest.json" "$SPIKE/engine-manifest.example.json"
log "manifest: $out/$STAGE_NAME.manifest.json (copy in engine-manifest.example.json)"
