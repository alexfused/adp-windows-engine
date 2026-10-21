#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Which Mac app identity (Dock name, bundle id) does a Windows program get when its shim starts
# the loader through a link inside the shim's own bundle (Hadron's WINELOADER patch, Wine 0022)?
# Builds work/shim-test/PuTTY Test.app (Info.plist + Contents/MacOS/putty-test, a symlink to
# WineHost.app's loader), runs PuTTY 64 through it for about 3 s, prints what Launch Services
# reports for the program's process, closes it, then unregisters and deletes the test bundle.
# Shows one window. Usage: tools/shim-identity.sh
source "$(dirname "$0")/../env.sh"
source "$SPIKE/engine-env.sh"
set +e
lsreg=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
shim="$WORK/shim-test/PuTTY Test.app"
rm -rf "$WORK/shim-test"; mkdir -p "$shim/Contents/MacOS"
loader="$ENGINE_ROOT/lib/wine/aarch64-unix/WineHost.app/Contents/MacOS/wine"
ln -s "$loader" "$shim/Contents/MacOS/putty-test"
cat > "$shim/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>putty-test</string>
<key>CFBundleIdentifier</key><string>com.alexparkin.adpmonitor.winapp.putty-test</string>
<key>CFBundleName</key><string>PuTTY Test</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
export WINEPREFIX="$PREFIXES/shim-test"; rm -rf "$WINEPREFIX"; cp -Rc "$GOLDEN" "$WINEPREFIX"
exe="$DOWNLOADS/programs/putty64/putty.exe"
WINELOADER="$shim/Contents/MacOS/putty-test" "$shim/Contents/MacOS/putty-test" "$exe" > "$TESTLOGS/shim-identity.log" 2>&1 &
for _ in $(seq 1 120); do
    wid=$("$WINLIST" "$ENGINE_ROOT/" | awk -F'\t' '$6 == 0 {split($5, d, "x"); if (d[1] > 100) {print $1 "\t" $2; exit}}')
    [[ -n "$wid" ]] && break; sleep 0.25
done
pid=$(cut -f2 <<< "$wid")
echo "window owner pid $pid, owner name: $("$WINLIST" "$ENGINE_ROOT/" | awk -F'\t' -v p="$pid" '$2 == p {print $3; exit}')"
echo "kernel path: $("$PROCARCH" "$ENGINE_ROOT/" 2>/dev/null | awk -F'\t' -v p="$pid" '$1 == p {print $6 " (" $3 ", translated=" $4 ")"}')"
lsappinfo list | awk -v p="pid = $pid" 'BEGIN{RS="\n[0-9]+\\) "} index($0, p) {print}' | grep -E '"|bundleID|bundle path|executable path|type' | head -8
WINELOADER="$shim/Contents/MacOS/putty-test" "$WINE" taskkill /im putty.exe > /dev/null 2>&1
wait_engine_exit 30 || "$WINESERVER" -k
"$lsreg" -u "$shim" 2>/dev/null
rm -rf "$WORK/shim-test" "$WINEPREFIX"
