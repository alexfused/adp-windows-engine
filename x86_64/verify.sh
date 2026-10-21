#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Prove the Intel engine is what it claims, without running any of it (it is x86_64). Checks the
# staged engine, or with --archive the hosted archive unpacked into a scratch folder:
#   1. every Mach-O is x86_64 only (lipo, file); every PE file is i386 or x86-64 (none arm64)
#   2. every Mach-O targets macOS 12.3 or earlier (LC_BUILD_VERSION minos, or LC_VERSION_MIN_MACOSX), and
#      every symbol newer than that (weak-linked) is one the code checks before calling
#   3. every Mach-O links only macOS's own libraries, @loader_path or @rpath, and its rpaths stay
#      inside the engine
#   4. path scan of every file (Mach-O, PE, data): no /Users/, /opt/homebrew, /usr/local, /opt/local,
#      user name or build folder; the neutral prefix and the mapped build folder are listed
#   5. signatures: valid (strict), Developer ID Team 2F2FVY326V, hardened runtime, secure timestamp,
#      identifier com.alexparkin.adpmonitor.winehost[.<file>], never com.alexparkin.adpmonitor;
#      entitlements only on the loader and exactly entitlements/loader.plist (no keychain access
#      group, no application identifier, no provisioning profile anywhere)
#   6. ADP Monitor's root helper would refuse every one of them: its caller requirement
#      (identifier "com.alexparkin.adpmonitor" and the trusted-signer clause) fails, while the same
#      clause with the file's own identifier passes (so the signer matches and the identifier is what
#      keeps them out)
#   7. with --archive: the app manifest passes ADP Monitor's own checks (tools/check-manifest)
#   8. licences: every licence text and notice the engine needs is in licenses/
# Writes evidence/verify[-archive].txt (paths shortened to <engine>) and exits non-zero on any failure.
# Usage: verify.sh [--archive]

source "$(dirname "$0")/env.sh"
MODE=stage; [[ "${1:-}" == --archive ]] && MODE=archive
rosetta_guard_start "verify-$MODE"
R="$STAGE"
if [[ $MODE == archive ]]; then
    tarball="$DIST/archive/$ENGINE_NAME.tar.xz"; [[ -f "$tarball" ]] || die "run archive.sh first"
    u="$WORK/verify-unpacked"; rm -rf "$u"; mkdir -p "$u"; tar -xJf "$tarball" -C "$u"; R="$u/$ENGINE_NAME"
fi
[[ -d "$R" ]] || die "no engine at $R (run package.sh)"
EV="$SPIKE/evidence"; mkdir -p "$EV"
report="$EV/verify.txt"; [[ $MODE == stage ]] || report="$EV/verify-archive.txt"
: > "$report.tmp"
out() { printf '%s\n' "$*" >> "$report.tmp"; }
FAILS=0
check() { if [[ "$2" == ok ]]; then out "PASS  $1"; else out "FAIL  $1: $2"; FAILS=$((FAILS + 1)); fi; }

out "# $ENGINE_NAME: verify.sh ($MODE) on $(date -u '+%Y-%m-%d %H:%M UTC'), build Mac $(uname -m) macOS $(sw_vers -productVersion)"
[[ $MODE == archive ]] && out "archive: $(basename "$tarball") $(sha256 "$tarball") $(stat -f %z "$tarball") bytes"
out "files: $(find "$R" -type f | wc -l | tr -d ' '), links: $(find "$R" -type l | wc -l | tr -d ' '), size: $(du -sh "$R" | cut -f1)"

machos=(); pes=()
while IFS= read -r -d '' f; do
    case "$(head -c 4 "$f" | xxd -p)" in
        cffaedfe|cafebabe|feedfacf|cefaedfe|feedface|bebafeca) machos+=("$f") ;;
        4d5a*) pes+=("$f") ;;
    esac
done < <(find "$R" -type f -print0)
out "Mach-O files: ${#machos[@]}, PE files: ${#pes[@]}"

# 1. Architectures.
out ""; out "## 1. Architectures"
bad=""
for f in "${machos[@]}"; do a=$(lipo -archs "$f" 2>&1); [[ "$a" == x86_64 ]] || bad+="${f#"$R"/}: $a; "; done
check "every Mach-O is x86_64 only (lipo -archs)" "${bad:-ok}"
file -b "${machos[@]}" | sed 's/ \[.*//' | sort | uniq -c | sed 's/^/      /' >> "$report.tmp"
pe_kinds=$(file -b "${pes[@]}" | sed -E 's/, [0-9]+ sections//; s/ \(stripped to external PDB\)//' | sort | uniq -c)
printf '%s\n' "$pe_kinds" | sed 's/^/      /' >> "$report.tmp"
grep -q -i -E 'aarch64|arm64|ARM' <<< "$pe_kinds" && check "no ARM PE files" "found ARM PE files" || check "no ARM PE files (i386 and x86-64 only)" ok
n32=$(find "$R/lib/wine/i386-windows" -type f | wc -l | tr -d ' '); n64=$(find "$R/lib/wine/x86_64-windows" -type f | wc -l | tr -d ' ')
out "      lib/wine/i386-windows: $n32 files (WoW64), lib/wine/x86_64-windows: $n64 files"
[[ -d "$R/lib/wine/x86_64-unix" && ! -d "$R/lib/wine/i386-unix" ]] && check "new-style WoW64: x86_64-unix only, no i386-unix (no 32-bit Mac code)" ok \
    || check "new-style WoW64" "unexpected unix folders: $(ls "$R/lib/wine" | tr '\n' ' ')"

# 2. Deployment target.
out ""; out "## 2. Minimum macOS (must be <= $MACOS_MIN)"
bad=""; minos_list=""
for f in "${machos[@]}"; do
    m=$(vtool -show-build "$f" 2>/dev/null | awk '$1 == "minos" {print $2; exit}' || true)
    s=$(vtool -show-build "$f" 2>/dev/null | awk '$1 == "sdk" {print $2; exit}' || true)
    if [[ -z "$m" ]]; then m=$(otool -l "$f" | awk '/LC_VERSION_MIN_MACOSX/ {f=1} f && $1 == "version" {print $2; exit}'); s="(LC_VERSION_MIN_MACOSX)"; fi
    [[ -n "$m" ]] || { bad+="${f#"$R"/}: no minimum version; "; continue; }
    awk -v a="$m" -v b="$MACOS_MIN" 'BEGIN { split(a, x, "."); split(b, y, "."); exit !((x[1] + 0 < y[1] + 0) || (x[1] + 0 == y[1] + 0 && x[2] + 0 <= y[2] + 0)) }' || bad+="${f#"$R"/}: minos $m; "
    minos_list+="minos $m sdk $s"$'\n'
done
check "every Mach-O has minos <= $MACOS_MIN" "${bad:-ok}"
printf '%s' "$minos_list" | sort | uniq -c | sed 's/^/      /' >> "$report.tmp"
# A symbol newer than the deployment target is weak-linked: on an older Mac it is NULL, so the code
# must check before calling it. Only these are known to be checked (Wine's sources, reviewed):
#   __availability_version_check    what __builtin_available calls
#   _os_sync_wait_on_address[_with_timeout], _os_sync_wake_by_address_any   ntdll sync.c, behind
#                                   __builtin_available(macOS 14.4) with a __ulock fallback
#   OpenCL 1.1 functions            weak because the header marks them deprecated; present on 12.3
# Anything else (pipe2 was one: macOS 27, called unchecked) fails.
allowed_weak='^(__availability_version_check|_os_sync_wait_on_address|_os_sync_wait_on_address_with_timeout|_os_sync_wake_by_address_any|_clCreateImage2D|_clCreateImage3D|_clEnqueueBarrier|_clEnqueueMarker|_clEnqueueWaitForEvents|_clUnloadCompiler)$'
bad=""; weak=""
for f in "${machos[@]}"; do
    while read -r sym from; do
        weak+="$sym $from"$'\n'
        [[ "$sym" =~ $allowed_weak ]] || bad+="${f#"$R"/}: $sym $from; "
    done < <(nm -m "$f" 2>/dev/null | awk '/\(undefined\) weak external/ { f = $6; sub(/\)$/, "", f); print $4, "from " f }')
done
check "no unchecked symbol newer than macOS $MACOS_MIN (every weak import is one Wine checks at run time)" "${bad:-ok}"
printf '%s' "$weak" | sort | uniq -c | sed 's/^/      weak: /' >> "$report.tmp"

# 3. Linked libraries and rpaths.
out ""; out "## 3. Linked libraries"
bad=""; deps=""
for f in "${machos[@]}"; do
    while read -r d; do
        deps+="$d"$'\n'
        [[ "$d" =~ ^(/usr/lib/|/System/Library/|@loader_path/|@rpath/) ]] || bad+="${f#"$R"/} links $d; "
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
    while read -r rp; do
        [[ -z "$rp" ]] && continue
        [[ "$rp" == @loader_path* || "$rp" == @executable_path* ]] || bad+="${f#"$R"/} rpath $rp; "
    done < <(otool -l "$f" | awk '/cmd LC_RPATH/ {getline; getline; print $2}')
done
check "only macOS libraries, @loader_path and @rpath; rpaths inside the engine" "${bad:-ok}"
printf '%s' "$deps" | grep -v '^@' | sort | uniq -c | sort -rn | sed 's/^/      /' >> "$report.tmp"
printf '%s' "$deps" | grep '^@' | sed 's#/[^/]*$#/...#' | sort | uniq -c | sed 's/^/      /' >> "$report.tmp"
out "      lib/ext: $(ls "$R/lib/ext" | tr '\n' ' ')"

# 4. Path scan.
out ""; out "## 4. Path scan (all $(find "$R" -type f | wc -l | tr -d ' ') files, binary-safe)"
# Personal paths fail anywhere. Package-manager prefixes fail anywhere except in the text of the Wine
# patches shipped as source (licenses/wine-patches/: our 0002 and 0003 remove such paths from Wine,
# so their diff lines and descriptions name them); those hits are listed, not failed.
# (The user name is searched as a path component: as a bare word it is in every signing
# identifier, com.alexparkin.adpmonitor.winehost.*, which is meant to be there.)
for p in /Users/ "/$(id -un)" "$HOME" "$WORK" /opt/homebrew /usr/local /opt/local /opt/X11 /sw/; do
    all=$(grep -rlaF -e "$p" "$R" 2>/dev/null | sed "s#^$R/##" || true)
    hits="$all"; src=""
    case "$p" in /opt/homebrew|/usr/local|/opt/local|/opt/X11|/sw/)
        hits=$(grep -v '^licenses/wine-patches/.*\.patch$' <<< "$all" || true)
        src=$(grep '^licenses/wine-patches/.*\.patch$' <<< "$all" || true) ;;
    esac
    if [[ -z "$hits" ]]; then check "no \"$p\" in any binary or data file$( [[ -n "$src" ]] && echo " (only in patch text: $(tr '\n' ' ' <<< "$src"))")" ok
    else
        check "no \"$p\" in any binary or data file" "$(wc -l <<< "$hits" | tr -d ' ') files"
        for h in $(head -5 <<< "$hits"); do out "      $h: $(strings -a "$R/$h" | grep -F -e "$p" | head -2 | tr '\n' '|' | cut -c1-160)"; done
    fi
done
for p in "$PREFIX" adp-build/ /home/ /private/var/folders /tmp/; do
    hits=$(grep -rlaF -e "$p" "$R" 2>/dev/null | sed "s#^$R/##" || true)
    out "info  \"$p\": $( [[ -z "$hits" ]] && echo none || echo "$(wc -l <<< "$hits" | tr -d ' ') files, e.g. $(head -3 <<< "$hits" | tr '\n' ' ')")"
    if [[ "$p" == "$PREFIX" && -n "$hits" ]]; then
        strings -a $(sed "s#^#$R/#" <<< "$hits") 2>/dev/null | grep -F "$p" | sort | uniq -c | sort -rn | head -12 | sed 's/^/        /' >> "$report.tmp"
    fi
done

# 5. Signatures.
out ""; out "## 5. Signatures"
loader="$R/lib/wine/x86_64-unix/wine"
want_ents=$(plutil -convert xml1 -o - "$SPIKE/entitlements/loader.plist" | grep -o '<key>[^<]*</key>' | sort | tr '\n' ' ')
bad=""; ids=""
for f in "${machos[@]}"; do
    rel="${f#"$R"/}"
    codesign --verify --strict "$f" 2>/dev/null || { bad+="$rel: invalid; "; continue; }
    info=$(codesign -dvvv "$f" 2>&1)
    id=$(sed -n 's/^Identifier=//p' <<< "$info"); team=$(sed -n 's/^TeamIdentifier=//p' <<< "$info")
    ids+="$id"$'\n'
    [[ "$id" == "$ID_PREFIX" || "$id" == "$ID_PREFIX".* ]] || bad+="$rel: identifier $id; "
    [[ "$id" != "$ADP_MONITOR_ID" ]] || bad+="$rel: ADP Monitor's own identifier; "
    [[ "$team" == "$TEAM_ID" ]] || bad+="$rel: team $team; "
    grep -q 'flags=0x10000(runtime)' <<< "$info" || bad+="$rel: no hardened runtime ($(grep -o 'flags=[^ ]*' <<< "$info")); "
    grep -q '^Timestamp=' <<< "$info" || bad+="$rel: no secure timestamp; "
    grep -q '^Authority=Developer ID Application: .*('"$TEAM_ID"')' <<< "$info" || bad+="$rel: not Developer ID; "
    ents=$(codesign -d --entitlements - --xml "$f" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null | grep -o '<key>[^<]*</key>' | sort | tr '\n' ' ' || true)
    if [[ "$f" == "$loader" ]]; then [[ "$ents" == "$want_ents" ]] || bad+="$rel: entitlements $ents; "
    else [[ -z "$ents" ]] || bad+="$rel: unexpected entitlements $ents; "; fi
    grep -q -E 'keychain-access-groups|application-identifier|cross-architecture' <<< "$ents" && bad+="$rel: restricted entitlement; "
done
check "every Mach-O: valid, Developer ID ($TEAM_ID), hardened runtime, timestamp, identifier $ID_PREFIX[.<file>], entitlements only on the loader" "${bad:-ok}"
profiles=$(find "$R" -name '*.provisionprofile' -o -name 'embedded.provisionprofile' | sed "s#^$R/##")
check "no provisioning profile in the engine" "$( [[ -z "$profiles" ]] && echo ok || echo "$profiles")"
out "      loader ($(codesign -dvvv "$loader" 2>&1 | sed -n 's/^Identifier=//p')): $(codesign -d --entitlements - --xml "$loader" 2>/dev/null | plutil -convert xml1 -o - - | grep -o '<key>[^<]*</key>' | sed 's/<[^>]*>//g' | tr '\n' ' ')"
out "      identifiers: $(printf '%s' "$ids" | sort -u | wc -l | tr -d ' ') distinct, e.g. $(printf '%s' "$ids" | sort -u | head -4 | tr '\n' ' ')"
out "      signer: $(codesign -dvvv "$loader" 2>&1 | grep '^Authority=' | sed 's/^Authority=//' | tr '\n' '<' | sed 's/<$//; s/</ < /g')"
read -r ip_off ip_size < <(otool -l "$loader" | awk '$1 == "sectname" {s = ($2 == "__info_plist")} s && $1 == "size" {z = $2} s && $1 == "offset" {print $2, z; exit}')
info_plist_id=$(dd if="$loader" bs=1 skip="${ip_off:-0}" count="$(( ${ip_size:-0} ))" 2>/dev/null | plutil -extract CFBundleIdentifier raw -o - - 2>/dev/null || true)
check "the loader's embedded Info.plist says CFBundleIdentifier $ID_PREFIX" "$( [[ "$info_plist_id" == "$ID_PREFIX" ]] && echo ok || echo "it says '$info_plist_id'")"

# 6. ADP Monitor's root helper caller requirement (Sources/ADPHelper/main.swift callerRequirement).
out ""; out "## 6. ADP Monitor's root helper would refuse the engine"
REPO="$(cd "$SPIKE/../.." && pwd)"
clause=$(grep -A1 "static let trustedSignerClause" "$REPO/Sources/SMCKit/HelperProtocol.swift" | grep -o '#".*"#' | head -1 | sed 's/^#"//; s/"#$//' || true)
[[ -n "$clause" ]] || die "could not read trustedSignerClause from Sources/SMCKit/HelperProtocol.swift"
grep -q "identifier \"$ADP_MONITOR_ID\" and \"# + HelperProtocol.trustedSignerClause" "$REPO/Sources/ADPHelper/main.swift" || die "ADPHelper's callerRequirement is not what verify.sh expects"
out "      helper requirement: identifier \"$ADP_MONITOR_ID\" and $clause"
bad=""; ok_own=0
for f in "${machos[@]}"; do
    rel="${f#"$R"/}"
    if codesign --verify -R "=identifier \"$ADP_MONITOR_ID\" and $clause" "$f" 2>/dev/null; then bad+="$rel passes the helper's requirement; "; fi
    id=$(codesign -dv "$f" 2>&1 | sed -n 's/^Identifier=//p')
    codesign --verify -R "=identifier \"$id\" and $clause" "$f" 2>/dev/null && ok_own=$((ok_own + 1)) || bad+="$rel fails the signer clause itself; "
done
check "no Mach-O satisfies the helper's requirement; all ${#machos[@]} satisfy the signer clause with their own identifier" "${bad:-ok}"
# Control: the same requirement accepts ADP Monitor itself, so the string is right and its refusal counts.
ctl="${ADP_MONITOR_APP:-/Applications/ADP Monitor.app}"
if [[ -d "$ctl" ]]; then
    codesign --verify -R "=identifier \"$ADP_MONITOR_ID\" and $clause" "$ctl" 2>/dev/null \
        && check "control: the helper's requirement accepts $(basename "$ctl") ($(codesign -dv "$ctl" 2>&1 | sed -n 's/^Identifier=//p'))" ok \
        || check "control: the helper's requirement accepts $(basename "$ctl")" "it does not (requirement string wrong?)"
else
    out "info  control skipped: no $ctl on this Mac"
fi

# 7. The app manifest through ADP Monitor's code.
if [[ $MODE == archive ]]; then
    out ""; out "## 7. ADP Monitor's engine manager (FleetCore WindowsEngineManifest)"
    "$SPIKE/tools/build-check-manifest.sh" > /dev/null
    res=$("$WORK/tools/check-manifest" "$DIST/archive/$ENGINE_NAME.app-manifest.json" "$u" 2>&1) && rc=0 || rc=$?
    sed 's/^/      /' <<< "$res" >> "$report.tmp"
    check "app manifest decodes, isValid, chosen for Intel only, nativeBinaries x86_64 (MachOArchs)" "$( [[ $rc == 0 ]] && echo ok || echo "exit $rc")"
fi

# 8. Licences and notices (what the licence review of the arm64 engine found missing there).
out ""; out "## 8. Licences and notices (licenses/)"
L="$R/licenses"; missing=""
need=(README.md SOURCES.md build-scripts-LICENSE
      wine/COPYING.LIB wine/LICENSE wine/AUTHORS wine/NOTICES.md
      wine-patches/hadron/LICENSE wine-patches/hadron/COPYING.LIB
      gnutls/COPYING gnutls/COPYING.LESSERv2 gnutls/COPYING.LESSERv3 gnutls/CRYPTOGAMS-license.txt gnutls/inih-LICENSE.txt gnutls/crau-LICENSE
      nettle/COPYING.LESSERv3 nettle/COPYINGv3 nettle/COPYINGv2
      gmp/COPYING.LESSERv3 gmp/COPYINGv3 gmp/COPYINGv2
      libtasn1/COPYING.LESSERv2
      freetype/FTL.TXT freetype/LICENSE.TXT freetype/bdf-README freetype/pcf-README)
for f in "${need[@]}"; do [[ -s "$L/$f" ]] || missing+="$f "; done
# Every third-party folder of Wine's that has a licence file in the source has one in the engine.
for d in "$SRC"/wine/libs/*/; do
    n=$(basename "$d")
    ls "$d" | grep -q -E -i '^(licen[cs]e|copying|copyright)' || continue
    ls "$L/wine/libs/$n" 2>/dev/null | grep -q -E -i '^(licen[cs]e|copying|copyright)' || missing+="wine/libs/$n "
done
for n in $(awk '$2 == "apply" { print $1 }' "$SPIKE/patches.conf"); do ls "$L/wine-patches/hadron/$n-"*.patch > /dev/null 2>&1 || missing+="hadron patch $n "; done
for p in "$SPIKE"/patches/*.patch; do cmp -s "$p" "$L/wine-patches/adp/$(basename "$p")" || missing+="adp/$(basename "$p") "; done
check "every licence text and notice is in licenses/ (Wine and its libs/, every applied patch, GnuTLS incl. LGPL-3 text, Nettle, GMP, libtasn1, FreeType FTL and driver READMEs)" "${missing:-ok}"
grep -q -i -E 'homebrew.*unmodified|unmodified.*homebrew' "$L/SOURCES.md" && check "SOURCES.md does not call any library an unmodified Homebrew copy" "it does" \
    || check "SOURCES.md does not call any library an unmodified Homebrew copy" ok
grep -q 'FreeType Project' "$L/README.md" && check "FreeType credit (FTL clause 3) in licenses/README.md" ok || check "FreeType credit (FTL clause 3) in licenses/README.md" "missing"
out "      $(find "$L" -type f | wc -l | tr -d ' ') files in licenses/: $(ls "$L" | tr '\n' ' ')"

out ""; out "RESULT: $( [[ $FAILS == 0 ]] && echo PASS || echo "FAIL ($FAILS)")"
sed -e "s#$R/#<engine>/#g" -e "s#$R#<engine>#g" -e "s#$SPIKE/#<spike>/#g" "$report.tmp" > "$report"; rm -f "$report.tmp"
if [[ $MODE == archive ]]; then
    rm -rf "$u"
    # The build's other evidence: every Rosetta guard run so far, and what the probes that try to run
    # ./conftest anyway answered under the exec barrier.
    sed -e "s#$SPIKE/#<spike>/#g" "$GUARD_LOG_DIR/summary.tsv" > "$EV/rosetta-guard.tsv" 2>/dev/null || true
    for d in "$BUILD"/deps-*/; do
        [[ -s "$d/probes.txt" ]] && sed "s#^#$(basename "$d"): #" "$d/probes.txt"
    done > "$EV/barrier-probes.txt" || true
fi
cat "$report"
[[ $FAILS == 0 ]]
