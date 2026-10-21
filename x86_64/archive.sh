#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Pack the staged, signed engine and everything needed to test it on an Intel Mac:
#   dist/archive/engine-x86_64-11.18-1.tar.xz              what gets hosted
#   dist/archive/engine-x86_64-11.18-1.tar.xz.sha256
#   dist/archive/engine-x86_64-11.18-1.app-manifest.json   exactly what ADP Monitor decodes
#                                                          (WindowsEngineManifest: WindowsEngineCatalog's format)
#   dist/archive/engine-x86_64-11.18-1.manifest.json       the release manifest (as the arm64 engine's),
#                                                          with the app manifest inside
#   dist/testkit/engine-x86_64-11.18-1-intel-test.tar      for test-on-intel.sh: the archive, hello32.exe
#                                                          and hello64.exe (tools/hello.c), and the loader
#                                                          signed four more ways for the entitlement matrix
# Then unpacks the archive into a scratch folder and checks the copy: same file list, every Mach-O's
# signature, and the app manifest through ADP Monitor's own code (tools/check-manifest). Nothing in
# the engine is run: it is x86_64.
# The URL is a placeholder until the engine is hosted (ENGINE_URL overrides it). Tar entries carry
# owner root:wheel, no macOS metadata, no extended attributes.
# Usage: archive.sh [--no-timestamp]

source "$(dirname "$0")/env.sh"
if [[ -z "${ADP_IN_BARRIER:-}" ]]; then
    export ADP_IN_BARRIER=1
    exec /usr/bin/sandbox-exec -p "$SANDBOX_PROFILE" /bin/bash "$0" "$@"
fi
TS=(--timestamp); [[ "${1:-}" == --no-timestamp ]] && TS=(--timestamp=none)
[[ -f "$STAGE/ENGINE-NAME" ]] || die "run package.sh first"
rosetta_guard_start archive
out="$DIST/archive"; mkdir -p "$out"
tarball="$out/$ENGINE_NAME.tar.xz"
APP_VERSION="$WINE_VERSION-$ENGINE_REV"
URL="${ENGINE_URL:-https://REPLACE-WITH-HOSTED-URL/$ENGINE_NAME.tar.xz}"

log "packing $tarball"
t0=$(date +%s); rm -f "$tarball"
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --uid 0 --gid 0 --uname root --gname wheel \
    --options xz:compression-level=9,xz:threads=0 -cJf "$tarball" -C "$DIST/stage" "$ENGINE_NAME"
pack_s=$(( $(date +%s) - t0 ))
sha=$(sha256 "$tarball"); bytes=$(stat -f %z "$tarball")
echo "$sha  $(basename "$tarball")" > "$tarball.sha256"
log "$(du -h "$tarball" | cut -f1) in ${pack_s} s, sha256 $sha"

log "checking an unpacked copy"
check="$WORK/archive-check"; rm -rf "$check"; mkdir -p "$check"
t0=$(date +%s); tar -xJf "$tarball" -C "$check"; unpack_s=$(( $(date +%s) - t0 ))
diff <(cd "$STAGE" && find . | sort) <(cd "$check/$ENGINE_NAME" && find . | sort) > /dev/null || die "file list differs after unpacking"
bad=0; nmacho=0
while IFS= read -r -d '' f; do
    [[ "$(head -c 4 "$f" | xxd -p)" == cffaedfe ]] || continue
    nmacho=$((nmacho + 1))
    codesign --verify --strict "$f" 2>/dev/null || { echo "bad signature: $f"; bad=1; }
done < <(find "$check/$ENGINE_NAME" -type f ! -path '*-windows/*' -print0)
[[ $bad == 0 ]] || die "the unpacked archive does not verify"
owners=$(tar -tvJf "$tarball" | awk '{print $3 ":" $4}' | sort -u | tr '\n' ' ')
unpacked_bytes=$(find "$check/$ENGINE_NAME" -type f -print0 | xargs -0 stat -f %z | awk '{s += $1} END {print s}')
files=$(find "$check/$ENGINE_NAME" -type f | wc -l | tr -d ' ')
log "unpacked in ${unpack_s} s: $files files, $nmacho Mach-O signatures valid, tar owners: $owners"

# The app manifest: WindowsEngineManifest exactly (Sources/FleetCore/WindowsApps/WindowsEngine.swift).
apply=$(awk '$2 == "apply" { printf "%s ", $1 }' "$SPIKE/patches.conf"); apply="${apply% }"
napply=$(echo "$apply" | wc -w | tr -d ' '); nown=$(ls "$SPIKE"/patches/*.patch | wc -l | tr -d ' ')
python3 -I - "$out/$ENGINE_NAME.app-manifest.json" "$APP_VERSION" "$URL" "$sha" "$bytes" "$ENGINE_NAME" "$napply" "$nown" "$WINE_COMMIT" <<'EOF'
import json, sys
path, version, url, sha, size, root, napply, nown, commit = sys.argv[1:]
m = {
    "version": version,
    "arch": "x86_64",
    "urls": [url],
    "sha256": sha,
    "bytes": int(size),
    "archiveRoot": root,
    "wine": "bin/wine",
    "wineserver": "bin/wineserver",
    "nativeBinaries": ["bin/wine", "bin/wineserver", "lib/wine/x86_64-unix/wine", "lib/wine/x86_64-unix/ntdll.so"],
    "label": "Wine 11.18 (ADP Monitor %s)" % root,
    "licence": ("Wine 11.18 is LGPL 2.1+, built from source by ADP Monitor with %s of Hadron's patches and %s of ours; "
                "GnuTLS, Nettle, GMP and libtasn1 (LGPL) and FreeType (FTL) inside. Licences, notices and sources: "
                "licenses/ in the engine. Source: https://gitlab.winehq.org/wine/wine (commit %s)" % (napply, nown, commit[:12])),
}
json.dump(m, open(path, "w"), indent=2, sort_keys=True); open(path, "a").write("\n")
EOF
"$SPIKE/tools/build-check-manifest.sh" > /dev/null
"$WORK/tools/check-manifest" "$out/$ENGINE_NAME.app-manifest.json" "$check" > "$WORK/check-manifest.out" || { cat "$WORK/check-manifest.out"; die "the app manifest does not pass ADP Monitor's checks"; }
log "app manifest: $(tail -1 "$WORK/check-manifest.out") (ADP Monitor's WindowsEngineManifest, isValid, catalog choice, MachOArchs)"

# The release manifest.
loader="$STAGE/lib/wine/x86_64-unix/wine"
python3 -I - "$out/$ENGINE_NAME.manifest.json" "$out/$ENGINE_NAME.app-manifest.json" "$loader" "$unpacked_bytes" "$files" \
    "$WINE_COMMIT" "$apply" "$HADRON_URL" "$HADRON_REF" "$LLVM_MINGW_VERSION" "$SPIKE/sources.tsv" "$ID_PREFIX" "$TEAM_ID" "$MACOS_MIN" "$SPIKE/patches" <<'EOF'
import json, os, plistlib, subprocess, sys, hashlib
(path, app_path, loader, ubytes, nfiles, commit, apply, hadron_url, hadron_ref, mingw, sources_tsv,
 id_prefix, team, macos_min, own_dir) = sys.argv[1:]
app = json.load(open(app_path))
ents = plistlib.loads(subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", loader], capture_output=True).stdout or b"<plist><dict/></plist>")
src = {}
for line in open(sources_tsv):
    if line.startswith("#") or not line.strip(): continue
    i, f, sha, _, urls = line.rstrip("\n").split("\t")
    src[i] = {"file": f, "sha256": sha, "url": urls.split()[0]}
own = sorted(p for p in os.listdir(own_dir) if p.endswith(".patch"))
m = {
    "schema": 1,
    "kind": "adp-monitor-windows-engine",
    "name": app["archiveRoot"],
    "version": app["version"],
    "wineVersion": "11.18",
    "arch": "x86_64",
    "minimumMacOS": macos_min,
    "rosetta": False,
    "archive": {"format": "tar.xz", "url": app["urls"][0], "sha256": app["sha256"], "bytes": app["bytes"]},
    "unpacked": {"bytes": int(ubytes), "files": int(nfiles)},
    "layout": {
        "root": app["archiveRoot"], "wine": "bin/wine", "wineserver": "bin/wineserver",
        "loader": "lib/wine/x86_64-unix/wine", "ext": "lib/ext",
        "pe": {"x86_64": "lib/wine/x86_64-windows", "i386": "lib/wine/i386-windows"},
        "licenses": "licenses",
    },
    "healthCheck": {"argv": ["bin/wine", "--version"], "stdoutPrefix": "wine-"},
    "environment": {"WINEDLLOVERRIDES": "winemenubuilder.exe=d;mscoree,mshtml="},
    "signing": {
        "teamID": team,
        "identifierPrefix": id_prefix,
        "loaderIdentifier": id_prefix,
        "loaderEntitlements": sorted(ents),
        "provisioningProfile": None,
        "notarized": False,
    },
    "sources": {
        "wine": {"url": "https://gitlab.winehq.org/wine/wine.git", "commit": commit, "hadronPatches": apply,
                 "adpPatches": own, "tarball": src["wine"]},
        "hadron": {"url": hadron_url, "commit": hadron_ref},
        "llvmMingw": mingw,
        "libraries": {k: src[k] for k in ("gmp", "nettle", "libtasn1", "gnutls", "gnutls-fix", "freetype")},
    },
    "app": app,
}
json.dump(m, open(path, "w"), indent=2); open(path, "a").write("\n")
EOF
cp "$out/$ENGINE_NAME.manifest.json" "$SPIKE/engine-manifest.example.json"
cp "$out/$ENGINE_NAME.app-manifest.json" "$SPIKE/app-manifest.example.json"

# Test kit for test-on-intel.sh.
kitname="$ENGINE_NAME-intel-test"; kit="$DIST/testkit/$kitname"
log "test kit $kit"
rm -rf "$kit"; mkdir -p "$kit/loaders"
cp -c "$tarball" "$tarball.sha256" "$kit/"
cp "$SPIKE/test-on-intel.sh" "$kit/"; chmod 755 "$kit/test-on-intel.sh"
for a in i686:hello32 x86_64:hello64; do
    # -s: no symbols or debug info (llvm-mingw's prebuilt CRT objects carry its CI runner's paths).
    "$MINGW/${a%%:*}-w64-mingw32-clang" -O2 -Wall -Werror -s "$MAP_FLAGS" -o "$kit/${a##*:}.exe" "$SPIKE/tools/hello.c" -lsecur32 -lgdi32 \
        || die "cannot build ${a##*:}.exe"
done
file "$kit/hello32.exe" | grep -q 'PE32 executable.*Intel 80386' || die "hello32.exe is not an i386 PE"
file "$kit/hello64.exe" | grep -q 'PE32+ executable.*x86-64' || die "hello64.exe is not an x86-64 PE"
variant() {   # name plist-body
    mkdir -p "$kit/loaders/$1"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>%s</dict></plist>\n' "$2" > "$WORK/loader-$1.plist"
    cp "$loader" "$kit/loaders/$1/wine"
    codesign --force --sign "$IDENTITY" "${TS[@]}" --options runtime --identifier "$ID_PREFIX" --entitlements "$WORK/loader-$1.plist" "$kit/loaders/$1/wine" \
        || die "codesign failed: loader variant $1"
    codesign --verify --strict "$kit/loaders/$1/wine" || die "bad signature: loader variant $1"
}
paths=$(grep -laF -e /Users/ -e /opt/homebrew -e /usr/local -e "$WORK" "$kit"/*.exe || true)
[[ -z "$paths" ]] || die "build or package-manager paths in the test programs: $paths"
variant no-dlv '<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>'
variant no-unsigned-mem '<key>com.apple.security.cs.disable-library-validation</key><true/>'
variant none ''
# Diagnostic only, never shipped: if the shipped loader fails on Intel, this tells whether the one
# stronger hardened-runtime exception would fix it.
variant plus-no-page-protection '<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/><key>com.apple.security.cs.disable-library-validation</key><true/><key>com.apple.security.cs.disable-executable-page-protection</key><true/>'
cat > "$kit/README.txt" <<EOF
Test kit for $ENGINE_NAME (the Intel Windows engine). On an Intel Mac, in this folder:

    ./test-on-intel.sh

It unpacks the engine into a temporary folder, runs it headless (no window, no sudo, no network),
and deletes everything again. Results: test-on-intel-<host>-<time>.log here. Exit 0 = every
required check passed. Options: --keep (keep the temporary folder), --no-matrix (skip the
entitlement matrix), --mac-driver (also start Wine's Mac driver; needs a logged-in desktop).

Files: $ENGINE_NAME.tar.xz (+ .sha256) the engine; hello32.exe / hello64.exe test programs
(source: tools/hello.c in ADP Monitor's spikes/windows-engine-intel, MIT); loaders/ the engine's
loader signed without one or both of its entitlements, and with one extra (diagnostic), for the
matrix. Needs nothing beyond macOS 12.3 or later: no Xcode, no Command Line Tools, no Rosetta.
EOF
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --uid 0 --gid 0 --uname root --gname wheel -cf "$DIST/testkit/$kitname.tar" -C "$DIST/testkit" "$kitname"
echo "$(sha256 "$DIST/testkit/$kitname.tar")  $kitname.tar" > "$DIST/testkit/$kitname.tar.sha256"
rm -rf "$check"
log "done: $tarball ($bytes bytes), manifests in $out, test kit $DIST/testkit/$kitname.tar"
