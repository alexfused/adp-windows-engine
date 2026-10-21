# Windows engine for Apple silicon, built without Rosetta: results (21 Oct 2026)

Brief: `docs/windows-apps-design.md` ("No Rosetta"). Background: `spikes/windows-arm64/RESULTS.md` (the
provisioning profile probe) and `REPORT-2026-10-21.md` (why Hadron). Sources and hashes: `SOURCES.md`.
Nothing in `Sources/`, nothing installed, no `bundle.sh`. MacBook Pro M3 Max, macOS 27.0.1.

**Verdict: it works.** Wine (arm64 host, ARM64EC and i386 WoW64) with FEX inside it, built here from source with
Hadron's patches, runs PuTTY 64-bit, PuTTY 32-bit, the 7-Zip installer and 7-Zip File Manager, and Notepad++ as
normal Mac windows. Every engine process seen during those runs was native arm64 and not translated, and Rosetta's
`oahd` did nothing. The engine is packaged our way (the loader is the main executable of `WineHost.app`, which
carries the Developer ID provisioning profile), Apple notarised it with no issues, and a quarantined copy (as a
browser download would leave it) still ran PuTTY 64 and 32.

**Ship engine-arm64-11.18-2, never 11.18-1.** 11.18-1 signed `WineHost.app` as `com.alexparkin.adpmonitor`, so the
root helper would have accepted it as a caller and it inherited ADP Monitor's privacy grants; it also carried
Homebrew paths and `/Users` build paths, and its licence folder was incomplete. 11.18-2 (next section) fixes all of
that. Sections 1 to 7 describe the 11.18-1 build; most of it still holds for 11.18-2, and where it does not, the
next section says so. 11.18-1's evidence moved to `evidence/engine-arm64-11.18-1/`.

## engine-arm64-11.18-2 (21 Oct 2026)

Same Wine, FEX and Hadron pins and patches as 11.18-1 (`SOURCES.md`). What changed:

| | 11.18-1 | 11.18-2 |
|---|---|---|
| `WineHost.app` identity | `com.alexparkin.adpmonitor` (ADP Monitor's), ADP Monitor's profile | `com.alexparkin.adpmonitor.winehost`, its own App ID (Cross-architecture Compatibility Framework only) and Developer ID profile `ADP_Monitor_Windows_Engine_Developer_ID.provisionprofile` |
| `WineHost.app` entitlements | profile's three + allow-jit, allow-unsigned-executable-memory, disable-library-validation | profile's three (application-identifier, team-identifier, cross-architecture-support) + allow-unsigned-executable-memory, disable-library-validation. No allow-jit (the matrix shows it is not needed), no keychain-access-groups (in the profile, not claimed) |
| Other Mach-O identifiers | file name only | `com.alexparkin.adpmonitor.winehost.<file name>` |
| `lib/ext` | Homebrew bottles (11 libraries, Homebrew paths compiled in) | 9 libraries built here from upstream tarballs (`build-ext.sh`, `ext.conf`): GMP 6.3.0, Nettle 4.0, libtasn1 4.21.0, libunistring 1.4.2, libidn2 2.3.8, GnuTLS 3.8.13, libpng 1.6.59, FreeType 2.14.3. p11-kit and gettext's libintl dropped (GnuTLS `--without-p11-kit --disable-nls`) |
| Install prefix and build paths | `/Users/.../dist/engine`, build tree paths in ~513 files | `--prefix=/nonexistent/adp-winehost` for Wine, FEX and lib/ext (installed with DESTDIR), `-ffile-prefix-map=<work>=adp-work` everywhere |
| Libraries Wine opens by name | FreeType, GnuTLS via `@loader_path`; CUPS, ODBC by bare name | also CUPS as `/usr/lib/libcups.2.dylib` and ODBC as `@loader_path/../../ext/libodbc.dylib` (not shipped, so no ODBC driver manager loads); `build-wine.sh` stops if any name is bare or outside the engine and the OS |
| `licenses/` | 34 files: Wine, FEX and Hadron licences, Homebrew's copies of the lib/ext licences; no Wine NOTICES.md, GSM, FAudio or FEX third-party notices, no GPL-3 text for Nettle, no FreeType FTL, CRYPTOGAMS or inih; SOURCES.md called the Homebrew libraries unmodified | 50 texts (list below) and a `SOURCES.md` that says how each component was changed |
| Scripts | | MIT (`LICENSE`), SPDX lines |

Results (`evidence/engine-arm64-11.18-2/`):

| Check | Result |
|---|---|
| Identity (`package.sh` gates, rechecked by hand) | `WineHost.app`: CFBundleIdentifier and signing identifier `com.alexparkin.adpmonitor.winehost`, embedded profile byte-identical to the winehost profile, entitlements exactly the five above. All 41 Mach-O files: Developer ID Application: Alex Parkin (2F2FVY326V), hardened runtime (`flags=0x10000(runtime)`), secure timestamp, arm64 only; every one except the loader has identifier `com.alexparkin.adpmonitor.winehost.<file name>` and no entitlements |
| Root helper refuses it (`helper-check.sh`, `helper-check.txt`) | The helper's caller requirement, read from `Sources/ADPHelper/main.swift` and `HelperProtocol.swift`: `identifier "com.alexparkin.adpmonitor" and (certificate root = H"7d6ad979b37022c4120f1e676a2d4b6359208919" or (anchor apple generic and certificate leaf[subject.OU] = "2F2FVY326V"))`. `codesign --verify -R=...` refused all 42 engine files (`WineHost.app` and the 41 Mach-O files), rc=3 "code failed to satisfy specified code requirement(s)". Controls accepted (rc=0): `/Applications/ADP Monitor.app` and 11.18-1's `WineHost.app`, so the requirement is live |
| Paths (`tools/path-scan.py`, `path-scan.txt`, `path-scan.tsv`) | 41 Mach-O and 1,590 PE files read like `strings -a` (ASCII and UTF-16LE) for `/opt/homebrew`, `/usr/local`, `/opt/local`, `/Users/`, `/tmp`, `/private/tmp`, `/var/folders`, `/private/var/folders`. No `/opt/homebrew`, `/opt/local`, `/var/folders` or the build Mac's home folder anywhere (also checked with `grep -r` over every file in the engine). 41 hits in 12 files remain, each explained in `tools/path-scan.allow`: `/Users/runner/work/llvm-mingw/...` `__FILE__` strings in llvm-mingw's prebuilt libc++abi/libunwind inside the FEX DLLs (assert text, never opened); Wine's wineserver socket folder `/tmp/.wine-%u` (created 0700, Wine refuses it unless owned by the user with no group/other access); FEX's `/tmp/perf-{}.map` (debug option, off; resolves inside the prefix); `/tmpmtrx` (PostScript text); read-only fallbacks Wine tries only after the engine's own copy or the macOS keychain: `/usr/local/share/wine/nls` (wineserver, after `share/wine/nls`), `/usr/local/share/certs/` (crypt32, only when the keychain gives no root certificate, checked in `dlls/crypt32/unixlib.c`), dbghelp's and winemenubuilder's default search paths |
| Licences | `licenses/`: Wine LICENSE, COPYING.LIB, AUTHORS, NOTICES.md, libs/gsm COPYRIGHT, libs/faudio LICENSE; Hadron's licences and patch-queue licences; FEX LICENSE and its compiled-in third-party code (SoftFloat-3e notice, cephes, fmt, xxHash, tiny-json, unordered_dense, rpmalloc, range-v3, cpp-optparse, the VIXL notice, musl's COPYRIGHT); llvm-mingw LICENSE.TXT; FreeType LICENSE.TXT, FTL.TXT, GPLv2.TXT, the bdf and pcf READMEs, the zlib and ft-hb notices; libpng LICENSE; GnuTLS COPYING.LESSERv2, README, inih LICENSE, CRYPTOGAMS notice (aarch64 assembly) and the x86 licence; Nettle and GMP COPYING.LESSERv3 with COPYINGv3 and COPYINGv2; libtasn1, libidn2 (incl. COPYING.unicode), libunistring texts. gettext's COPYING.LIB is no longer needed (libintl not shipped). The VIXL library, Zydis and Tracy are not compiled into FEX here (`ENABLE_VIXL_*`, `ENABLE_ZYDIS`, profiler off). Two pieces of third-party code inside FEX's own tree are, and the first archive shipped no notice for them (found by review on 21 Oct, fixed the same day): functions taken from VIXL in FEX's code emitter (`CodeEmitter/CodeEmitter/VixlUtils.inl`, Copyright 2015 VIXL authors, BSD-3-Clause; `fex/VIXL-NOTICE` is that file's licence comment) and musl routines in FEX's Windows runtime (`Source/Windows/Common/CRT/Musl/`, 20 files, Rich Felker et al. and Arm Limited, MIT; `fex/Musl-COPYRIGHT` is musl's COPYRIGHT file from Wine's copy of musl, since FEX's copies carry only SPDX lines). Both are in the two FEX DLLs (and their `xtajit` copies), not in the unixlib `.so` files. `package.sh` now stops if any file of FEX's tree that the FEX builds read (`ninja -t deps`, 473 files) has a copyright line, a public-domain statement or a licence other than MIT without a line in `tools/fex-notices.tsv` whose text is in `licenses/` (`fex-notices.txt`: 219 such files, all covered) |
| Headless (`smoke.sh`) | all pass: `cmd /c ver` arm64 4.1 s, `hello-x86_64.exe` 0.2 s, `hello-i686.exe` 0.1 s, 32-bit `cmd` 0.8 s, and new `crypto-gnutls` (`tools/tls-check.c`, x86_64): RSA-2048 PKCS#1 sign/verify, AES-128 FIPS-197 vector and a schannel ClientHello through the from-source GnuTLS |
| Entitlement matrix, rerun | same as 11.18-1: shipped set and shipped + allow-jit pass; without disable-library-validation, without allow-unsigned-executable-memory, profile entitlements only, and no profile all fail as before |
| Programs (`test-programs.sh`, each in its own prefix cloned from a golden one) | PuTTY 64, PuTTY 32, 7-Zip installer (`/S`, exit 0) and File Manager, Notepad++: every window appeared twice and closed cleanly; screenshots `*-first.png`, `*-second.png`. 112 engine processes, all `arm64`, `translated=0`; `oahd` CPU 0:01.72 before and after, no `oahd-helper`, no `oah` log lines |
| Notarisation | `WineHost.app` zip: Accepted, job `bb725613-9b31-44e7-a0cc-d769a0f9926e`, stapled (`stapler validate` ok, `spctl`: `source=Notarized Developer ID`). Whole engine (199,496,558-byte zip): Accepted, job `9e0d82b3-8bc3-4a85-ac85-68c2add44d84`, 0 issues, 42 ticket entries whose cdhashes match the staged files |
| Quarantine (`quarantine-test.sh`) | 1,850 files and folders quarantined: `spctl` accepted, `wine --version` ok, new golden prefix 26.6 s, smoke pass, PuTTY 64 6.6 / 5.9 s and PuTTY 32 6.2 / 6.2 s, 53 processes all arm64 not translated. Control (Developer ID, not notarised): `spctl` rejected (`Unnotarized Developer ID`), `wine --version` killed (137) |
| Archive (`archive.sh`) | `dist/archive/engine-arm64-11.18-2.tar.xz` 85,920,516 bytes (82 MB), SHA-256 `67cb8cde7299c701a3aae047ba13ae7fff69237904e383eae8536d1f8e8e1c94` (`.sha256` beside it); unpacked 1,010,637,269 bytes in 1,822 files. Packed in 120 s, unpacked in 5 s; after unpacking: same file list, every signature verifies, `WineHost.app` still stapled, `wine --version` runs. Manifest `engine-manifest.example.json` (url placeholder `https://REPLACE-WITH-HOSTED-URL/...`; now also the lib/ext tarballs, llvm-mingw's URL and hash, and the identifier prefix of the other files). This is the second packing of 11.18-2: `package.sh --licences-only` added the VIXL and musl texts to the notarised stage (only `licenses/README.md`, `licenses/SOURCES.md` and the two new files changed; the other 1,770 files and 14 symlinks are byte-identical, so every signature and the stapled ticket still hold) and `archive.sh` repacked it, with all its checks passing again and `spctl` still `source=Notarized Developer ID` on the unpacked copy. The first packing (85,876,920 bytes, SHA-256 `423d623b...da791e5`, 1,820 files) lacked those two texts; do not ship it |

Launch times in the main program run were slower than 11.18-1 (PuTTY 7.0 to 7.8 s with one 23.8 s outlier, 7-Zip
File Manager 27.8 / 32.8 s, Notepad++ 37.1 / 16.4 s, the 7-Zip installer 32.1 s against 10.9 s). The Mac was busy
with other work during this run (load average 66 to 89 on 14 cores when checked two hours later; not recorded at the
time), and PuTTY from the quarantined copy 15 minutes later was back to 5.9 to 6.6 s. Treat these as unmeasured:
rerun `test-programs.sh` on an idle Mac before quoting launch times for 11.18-2.

## 1. What was built

| Part | Result |
|---|---|
| Wine | `wine-11.18-276-g8f4bf95c31`: Hadron's pin of upstream Wine (28 Sep 2026) + 30 of Hadron's 39 Wine patches. `--enable-archs=arm64ec,aarch64,i386`, unix side Apple clang, PE side Homebrew clang 23. `make -j14`: 286 s. |
| FEX | Hadron's pin (28 Sep 2026) + Hadron's 5 FEX patches. `libarm64ecfex.dll` (x86_64 code, installed as `xtajit64.dll`), `libwow64fex.dll` (i386 code under WoW64, as `xtajit.dll`), `libarm64ecfex.so`/`libwow64fex.so` (macOS helpers). 108 s. |
| Left out | Everything of Hadron's that is not Wine or FEX: Steam (lsteamclient, NotProton), DXMT, mtld3d, Mesa/KosmicKrisp/Zink, vkd3d-proton, DXVK, FFmpeg, GStreamer, its launcher and app. Wine is configured `--without-vulkan --without-gstreamer --without-ffmpeg --without-sdl --without-usb` and other Homebrew-only options, so it carries only FreeType and GnuTLS. |
| Wine patches skipped | 0007, 0012, 0014 (DXMT/mtld3d Metal views), 0009, 0026 (Steam), 0017 (winevulkan), 0023, 0028 (OpenGL on EGL/Zink), 0037 (Retina mode by default: old utilities are not DPI-aware). Reasons per patch in `patches.conf`. The other 30 applied cleanly with `git am --3way`; no extra patch of our own. |
| Notable patches kept | 0008 (loader claims the soft `__PAGEZERO` = memory below 4 GB, and runs from `<name>.app/Contents/MacOS`), 0002/0006/0011 (W^X and MAP_JIT for FEX), 0004 (x18 keeps the TEB), 0010 (hardware TSO, opt-in), 0020 (CPU features for FEX), 0022 (`WINELOADER` names the loader, used for shims below), 0033 (a Windows program never changes the Mac's display mode: it is emulated), 0034-0036 (4 KB Windows pages on 16 KB host pages). |
| Not built | Wine Mono and Gecko (the Rosetta engine ships them, 305 MB). The tests turn them off, as the Tier 1 spike did. .NET programs are untested. |

Hadron does not use 4 KB-page processes: Wine runs with 16 KB host pages and patches 0034-0036 handle 4 KB Windows
pages. The probe's 4 KB spawn attribute is unused here; so is hardware TSO by default (both Wine and FEX enable it
only with `HADRON_HARDWARE_TSO=1`; Hadron found whole-thread TSO made games slower). What the engine does need from
the cross-architecture entitlement is memory below 4 GB (32-bit programs and `KUSER_SHARED_DATA` at `0x7ffe0000`).

## 2. Packaging (`package.sh`)

```
engine-arm64-11.18-1/
  bin/wine -> ../lib/wine/aarch64-unix/WineHost.app/Contents/MacOS/wine
  bin/wineserver                       plain executable, never runs Windows code
  lib/wine/aarch64-unix/WineHost.app   Info.plist (com.alexparkin.adpmonitor, LSUIElement), MacOS/wine = the loader,
                                       embedded.provisionprofile = dist/profiles/ADP_Monitor_Developer_ID.provisionprofile
  lib/wine/aarch64-unix/wine -> WineHost.app/Contents/MacOS/wine     (ntdll starts child processes through this)
  lib/wine/aarch64-unix/*.so           Wine and FEX unix libraries
  lib/wine/aarch64-windows/            ARM64X DLLs + FEX (xtajit.dll, xtajit64.dll)    709 MB
  lib/wine/i386-windows/               32-bit DLLs for WoW64                           202 MB
  lib/ext/                             FreeType, GnuTLS and their 9 libraries (7 MB)
  share/wine/  licenses/  ENGINE-NAME
```

- Every Wine process, including the Windows programs, runs as `WineHost.app`'s main executable: `procarch` shows
  `.../WineHost.app/Contents/MacOS/wine` as the kernel's path for all of them, reached through the `bin/wine` and
  `aarch64-unix/wine` symlinks. Only `wineserver` runs outside it.
- Wine opens FreeType and GnuTLS by name. `build-wine.sh` points those names at `@loader_path/../../ext/...`, so no
  `DYLD_*` variable and no `allow-dyld-environment-variables` entitlement is needed.
- 42 Mach-O files plus `WineHost.app`, all arm64 only (`package.sh` refuses any x86_64 slice), all signed with
  "Developer ID Application: Alex Parkin (2F2FVY326V)", hardened runtime, secure timestamp. Minimum macOS is 27.0
  (Apple clang's default for the SDK; Hadron also needs 27). Builds for older systems are untested.

### Which entitlements `WineHost.app` needs (`entitlement-matrix.sh`, headless)

Each variant: a clone of the engine with only `WineHost.app` re-signed, then a new prefix (`wineboot -u`), `cmd /c
ver` (arm64), `hello-x86_64.exe` (FEX ARM64EC), `hello-i686.exe` and `syswow64\cmd.exe` (FEX WoW64).

| Variant | Result | What failed |
|---|---|---|
| profile ids + cross-architecture + allow-jit + allow-unsigned-executable-memory + disable-library-validation | **pass** (prefix 23.4 s) | |
| without disable-library-validation | fail | `map_image_into_view failed to set 60000020 protection on ...ntdll.dll section .text, noexec filesystem?` (mapping PE files executable) |
| without allow-unsigned-executable-memory | fail | the loader is `Killed: 9` during `wineboot` |
| without allow-jit | **pass** | (MAP_JIT is allowed by the cross-architecture entitlement, as the probe found) |
| profile entitlements only | fail | as without disable-library-validation |
| no profile, no cross-architecture entitlement (the three exceptions only) | fail | `map_fixed_area out of memory for 0x7ffe0000-0x7ffe1000`, `failed to map the shared user data` |

Needed: `com.apple.application-identifier`, `com.apple.developer.team-identifier`,
`com.apple.developer.cross-architecture-support` (all three from the profile),
`com.apple.security.cs.allow-unsigned-executable-memory`, `com.apple.security.cs.disable-library-validation`.
`allow-jit` is not needed today; the shipped set keeps it (it adds nothing that unsigned executable memory does not
already allow, and FEX's MAP_JIT path then does not depend on undocumented behaviour). Not needed and not given:
`custom-x18-abi-toggle` (the cross-architecture entitlement covers x18), `allow-dyld-environment-variables`.

## 3. Programs (`test-programs.sh`, each in its own prefix cloned from the golden one)

Golden prefix: `wineboot -u` 23.7 s (22 to 30 s over seven runs), then the Desktop/Documents/Downloads/Music/
Pictures/Videos links to the Mac user's folders replaced by empty folders. Each program's prefix is a `cp -Rc` clone
of it: 0.28 to 0.33 s. Two launches each, each with a new wineserver; window = first engine-owned window larger than
100 x 60; RSS = sum over all engine processes (counts shared libraries more than once: an upper bound).
Screenshots of the windows only (`screencapture -l`) are in `evidence/engine-arm64-11.18-1/`.

| Program | Code | Window (launch 1 / 2) | RSS | Closes cleanly | Screenshot | Rosetta engine (Tier 1) |
|---|---|---|---|---|---|---|
| PuTTY 0.85 64-bit | x86_64 via FEX ARM64EC | 5.28 / 5.27 s | 472 MB | yes / yes | `putty64-first.png` | 5.6 s, 266 MB |
| PuTTY 0.85 32-bit | i386 via FEX WoW64 | 5.26 / 5.29 s | 484 MB | yes / yes | `putty32-first.png` | 6.2 s, 290 MB |
| 7-Zip 26.04 installer `/S` | x86_64 | exit 0 in 10.9 s | | | | 9.4 s |
| 7-Zip File Manager | x86_64 | 6.76 / 7.82 s | 462 MB | yes / yes | `7zip-first.png` | 5.6 s, 283 MB |
| Notepad++ 8.9.8.1 x64 | x86_64 | 7.28 / 6.39 s | 493 MB | yes / yes | `npp-first.png` | 6.6 s, 312 MB |
| PuTTY 64 / 32 with `HADRON_HARDWARE_TSO=1` | | 5.27 / 5.28, 5.26 / 5.27 s | 472 / 485 MB | yes | (not kept) | |
| PuTTY 64 / 32 from the quarantined, notarised copy | | 7.62 / 5.30, 5.64 / 5.32 s | 428-486 MB | yes | `putty*-quarantine-*.png` | |

Headless (`smoke.sh`, warm wineserver): `cmd /c ver` 3.9 s cold, `hello-x86_64.exe` 0.1 to 0.2 s, `hello-i686.exe`
0.1 s, 32-bit `cmd /c ver` 0.8 s. `WINEDEBUG=+loaddll` shows `xtajit64.dll` loaded for the x86_64 program and
`xtajit.dll` for the i386 one; the i386 program reports `wow64=1`.

Where launch time goes (`tools/launch-trace.sh`): no single wait. Each Wine process that starts (wineboot, services,
explorer, the program) spends about 0.6 s before `imm32.dll` loads, which is the Mac driver starting up. A
wineserver kept alive between launches should save most of it, as the Tier 1 spike measured (4.5 s to 1.6 s).

Memory is 180 to 210 MB higher than the Rosetta engine per program (sum of RSS; the ARM64X DLLs and FEX's JIT).

### Proof of no Rosetta

- Every engine process during the runs was recorded every 0.2 s by `tools/procarch` (kernel `P_TRANSLATED` flag and
  `proc_pidinfo(PROC_PIDARCHINFO)`): 112 processes in the main run, 53 in the TSO run, 52 in the quarantine run, all
  `arm64`, `translated=0` (`evidence/engine-arm64-11.18-1/programs*.procs.tsv`, `programs.procs-summary.txt`).
- `oahd` CPU time 0:01.70 before and after every run; no `oahd-helper` process appeared; `log show` for the `oah`
  processes and `com.apple.oah` subsystem: 0 lines during each run.
- No Mach-O file in the engine has an x86_64 slice: `package.sh` checks each with `lipo -archs` (all `arm64`). x86
  Windows code (the programs, the i386 DLLs) only ever runs inside FEX's JIT.
- One slip, before any engine work: my first environment check ran `arch -x86_64 /usr/bin/true` to see whether
  Rosetta was present. That ran the x86_64 slice of `/usr/bin/true` under Rosetta once. Nothing else touched it; the
  oahd figure above was taken after that and never moved.

## 4. Notarisation and a quarantined copy (`notarize-engine.sh`, `quarantine-test.sh`)

| Step | Result |
|---|---|
| `WineHost.app` alone (profile embedded, the five entitlements plus allow-jit, hardened runtime), 20 KB zip | **Accepted** in 18 s, 0 issues (`evidence/engine-arm64-11.18-1/notary-winehost*.json`). Stapled; `spctl -a -t execute`: accepted, `source=Notarized Developer ID`. |
| The whole engine, 193 MB zip | **Accepted** in 95 s, 0 issues, 44 ticket entries (`evidence/engine-arm64-11.18-1/notary-engine*.json`). |
| Copy with `com.apple.quarantine` (`0083;...;Safari;<uuid>`) on all 1,837 files and folders | `spctl` accepted, `wine --version` ok, new golden prefix in 26.9 s, `smoke.sh` all pass, PuTTY 64 and 32 windows (table above). |
| Control: the same, but `WineHost.app` re-signed with other entitlements and never notarised | `spctl`: rejected, `source=Unnotarized Developer ID`; `wine --version` killed (exit 137). |

So Apple accepts a Developer ID app that embeds the cross-architecture profile, and Gatekeeper lets a downloaded copy
run. A copy that differs only in its signing timestamp has the same cdhash and the same ticket (the first control
attempt showed that). Only `WineHost.app` can be stapled; the other Mach-O files rely on Gatekeeper's online ticket
check, which this Mac could do. A Mac offline at first launch is untested. ADP Monitor's own download (URLSession)
adds no quarantine flag at all (Tier 1 spike), so this matters only for copies that come through a browser or AirDrop.

## 5. The archive (`archive.sh`)

| | |
|---|---|
| `dist/archive/engine-arm64-11.18-1.tar.xz` | 85,976,392 bytes (82 MB), SHA-256 `ff3d6474e25b111098e1ac0dc27f185a6f7f6e456bbeaa95a9089f62e6a070e5` |
| Unpacked | 1,012,100,362 bytes in 1,808 files (Rosetta engine: 185 MB download, 682 MB unpacked) |
| Pack / unpack | 153 s (`xz -9`, threaded) / 5 s with `/usr/bin/tar` |
| Check after unpacking | same file list, every signature verifies, `WineHost.app` ticket still stapled, `wine --version` runs |
| Manifest | `engine-manifest.example.json`: version, `url` placeholder (`ENGINE_URL` sets it), sha256, sizes, layout (wine, wineserver, loader app, emulator DLLs), health check, signing (team, bundle id, entitlements, notary submission id) and source revisions |

`.tar.zst` was not possible with the system `tar` (no zstd in macOS's libarchive); `.tar.xz` unpacks with nothing
extra installed.

## 6. Found along the way

1. **WineHost shares ADP Monitor's bundle id, and that leaks.** Launch Services registered every `WineHost.app` copy
   the tests ran as another `com.alexparkin.adpmonitor` (`tools/lsresolve`). It still picks `/Applications/ADP
   Monitor.app` (CFBundleVersion 265 beats 11.18.1), but a Windows program also inherits whatever privacy grants
   (Screen Recording, Accessibility) macOS gave ADP Monitor, and shares its preferences domain. Recommendation:
   register a second App ID, `com.alexparkin.adpmonitor.winehost`, with the cross-architecture capability and its own
   Developer ID profile, and rebuild with `ADP_BUNDLE_ID` and `ADP_PROFILE` pointing at it. `cleanup.sh` unregistered the
   test copies. **Done in 11.18-2** (`env.sh` now defaults to that App ID and profile and refuses ADP Monitor's id).
2. **Shims work without copying the loader** (`tools/shim-identity.sh`). A shim bundle whose
   `Contents/MacOS/<name>` is a symlink to `WineHost.app`'s loader, started with `WINELOADER` set to that symlink
   (Wine patch 0022): the kernel runs WineHost's signed loader (entitlement honoured, PuTTY 64 ran), and Launch
   Services shows the shim: name "PuTTY Test", bundle id `com.alexparkin.adpmonitor.winapp.putty-test`, Foreground,
   ARM64. So each Windows program can still be its own Mac app (Dock, Cmd-Tab), as in the Tier 1 shim.
3. **The golden prefix is 1.05 GB, and 1,047 MB of it is byte-identical to engine files** (`tools/prefix-dedup.py`):
   Wine copies its DLLs into `system32`/`syswow64`. The engine manager should replace those copies with APFS clones
   of the engine's files after `wineboot` (`cp -c`), so the golden costs about 5 MB of real disk. Program prefixes are
   clones of the golden anyway.
4. Wine messages that are expected with this build and harmless for these programs: `winegstreamer.dll ... not
   found` (no GStreamer: no Media Foundation/DirectShow decoding), `winebth` driver fails to start (Bluetooth),
   `no Kerberos support`, `Wine was built without Vulkan support`.
5. Two Wines: Apple silicon gets this 11.18 development snapshot, Intel gets Wine 11.0 stable (Gcenx). Programs could
   behave differently between them. Moving both to one Wine release (or rebasing Hadron's queue onto 11.0.x) is a
   decision for the integration step.

## 7. What failed or was not done

- Script bugs fixed during the run, results above are from the fixed versions: `package.sh`'s Mach-O lister ended
  on a false test and stopped the script with no message; the first entitlement matrix counted a failed `wineboot` as
  a pass (fixed check, matrix rerun); the first quarantine control used a copy with the notarised cdhash.
- Not tested: a second Apple silicon Mac that was never registered to the team; macOS 26 or older (the build needs 27);
  offline Gatekeeper; USB drives as drive letters and USB-serial adapters as COM ports on this engine; .NET and
  embedded-browser programs (no Mono/Gecko); the 4 KB-page process mode; long sessions and memory over time.
- Hadron's prebuilt `Hadron-0.3.1.dmg` was not downloaded for comparison: not needed, and it would have been an
  untrusted binary on this Mac.
- Nothing was installed outside this spike's folders except the Homebrew formulae above. No sudo, no display change,
  no other Mac.

## Rerun

```
./fetch.sh            # llvm-mingw, lib/ext tarballs (hashes checked), Hadron, Wine and FEX at the pins, patches.conf applied
./build-ext.sh        # work/ext-root: GMP, Nettle, libtasn1, libunistring, libidn2, GnuTLS, libpng, FreeType
./build-wine.sh       # dist/engine-root
./build-fex.sh        # into dist/engine-root
./programs.sh         # test programs (hash checked) and the hello and tls-check test programs
./package.sh          # dist/stage/<engine>: WineHost.app, lib/ext, licences, every Mach-O signed, path scan, FEX notices
./package.sh --licences-only         # rewrite only licenses/ of a notarised stage (signatures untouched); then archive.sh
./helper-check.sh                    # the root helper must refuse every engine file
./golden.sh && ./smoke.sh            # headless
./entitlement-matrix.sh              # headless
./test-programs.sh                   # windows for about 3 s each; evidence/<engine>/
./notarize-engine.sh --winehost      # uploads to Apple
./notarize-engine.sh --engine
./quarantine-test.sh
./archive.sh                         # dist/archive/<engine>.tar.xz, .sha256, .manifest.json
tools/collect-evidence.sh; ./cleanup.sh
```
`work/`, `downloads/` and `dist/` are ignored. `TRACE=1` before any script shows each command.
