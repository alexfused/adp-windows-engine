# Windows engine for Intel Macs, built from source (engine-x86_64-11.18-1)

Brief: `docs/windows-apps-design.md`. Alex's decisions of 21 Oct 2026: our own Intel engine instead of mirroring
Gcenx's build, its own signing identity (`com.alexparkin.adpmonitor.winehost`, never ADP Monitor's), MIT for our
scripts. Companion: `spikes/windows-engine-arm64` (the Apple silicon engine, same Wine tree). Nothing in `Sources/`,
nothing installed, nothing published.

**State: built, signed and checked on the build Mac (Apple silicon); first run on an Intel Mac on 21 Oct 2026 passed
every required check except one, which failed because of a bug in the test script (fixed; rerun pending).** Running an
x86_64 engine here would need Rosetta, which these scripts refuse, so `test-on-intel.sh` runs it on an Intel Mac
(section 5, first run in section 5.1).

## 1. What it is

| Part | What |
|---|---|
| Wine | 11.18 at commit `6880117619af` (Hadron's pin, the arm64 engine's tree), from the GitLab archive of that commit, + 16 of Hadron's 39 Wine patches (`patches.conf`) + 3 of ours (`patches/`) |
| Architectures | Unix side x86_64 only (`lib/wine/x86_64-unix`), PE side x86_64 and i386 (`--enable-archs=i386,x86_64`): new-style WoW64, so 32-bit Windows programs run in 64-bit processes and there is no 32-bit Mac code |
| Libraries | GnuTLS 3.8.13, Nettle 4.0 (with Hogweed), GMP 6.3.0, libtasn1 4.21.0, FreeType 2.15.0, each built from the official tarball (`sources.tsv`, `SOURCES.md`) into `lib/ext` |
| Minimum macOS | 12.3 (`-mmacosx-version-min=12.3` on every compile and link; `LC_BUILD_VERSION minos 12.3` on all 36 Mach-O files) |
| Left out | X11, Vulkan, GStreamer, FFmpeg, SDL, USB, ... (the same `--without-*` list as the arm64 engine); Wine Mono and Gecko; no p11-kit, libidn2, gettext, zlib/brotli/zstd in GnuTLS |
| Size | 57 MB `tar.xz`, 418 MB unpacked, 1843 files |

### Hadron's patches: which and why (`patches.conf` has one line per patch)

The rule: the arm64 engine's 30, minus every patch that is specific to arm64, to FEX or to 16 KB host pages. Intel
Macs run x86_64 and i386 Windows code natively, with 4 KB pages.

- **Applied (16):** 0013, 0016, 0018, 0021, 0027, 0029, 0030, 0031, 0032, 0038, 0039 (winemac.drv: display modes,
  scrolling, Dock icons, window levels, Retina sizes), 0033 (a Windows program never changes the Mac's display mode),
  0015 (`WINE_LARGE_ADDRESS_AWARE`, off unless set), 0022 (`WINELOADER` names the loader), 0024 (VC runtime version
  in wine.inf), 0025 (skip occupied host mappings in macOS address searches).
- **Skipped as arm64/FEX/16 KB only (14):** 0001, 0002, 0003, 0004, 0006, 0008, 0010, 0011, 0019, 0020 (arm64 loader,
  W^X flipping, x18, KUSER_SHARED_DATA above 4 GB, the cross-architecture entitlement's `__PAGEZERO`, hardware TSO,
  FEX's JIT buffers and CPU registers, ARM64EC), 0034, 0035, 0036 (4 KB guest pages on 16 KB host pages), and 0005:
  it moves the top of Wine's top-down area 16 MB below the arm64 user-space limit (exec failed with EFAULT there); on
  x86_64 that area already ends 30 MB below the top of user space (`0x7ffffe000000` against `0x7fffffe00000`).
- **Skipped as in the arm64 engine (9):** 0007, 0012, 0014 (DXMT/Metal views), 0009, 0026 (Steam), 0017
  (winevulkan), 0023, 0028 (OpenGL on EGL), 0037 (Retina mode by default).

### Our patches (`patches/`, LGPL-2.1-or-later like Wine)

- 0001: the loader's embedded Info.plist says `com.alexparkin.adpmonitor.winehost` (Wine's says `org.winehq.wine`), the
  same as its signing identifier.
- 0002: wineserver reads `l_intl.nls` only from the engine, not from `/usr/local/share/wine/nls` (Homebrew's folder on
  an Intel Mac).
- 0003: crypt32 takes root certificates only from the Keychain on macOS, not from `/usr/local/share/certs` and other
  Linux/BSD fallbacks.

## 2. How it is built (on Apple silicon, without running x86_64 code)

```
./build-all.sh --clean    # everything below, in order, from verified sources: 13 minutes on this Mac
./fetch.sh                # downloads/ + work/src: every file pinned by SHA-256 (sources.tsv, patches.sha256)
./build-deps.sh           # x86_64 GMP, Nettle, libtasn1, GnuTLS, FreeType; arm64 FreeType for Wine's sfnt2fon
./build-wine.sh           # native arm64 Wine tools, then the x86_64 cross build with --with-wine-tools
./package.sh              # dist/stage: layout, lib/ext, licences, strip, sign
./archive.sh              # dist/archive: tar.xz, sha256, manifests; dist/testkit for the Intel Mac
./verify.sh [--archive]   # the proofs in section 4; evidence/verify*.txt
./cleanup.sh [--all]      # delete build trees (and with --all the outputs, sources, toolchain)
```

- Cross compiling: every configure gets `--build=aarch64-apple-darwin --host=x86_64-apple-darwin`; C code is
  `clang -arch x86_64 -mmacosx-version-min=12.3` (`tools/x86-cc`); PE code is llvm-mingw 20260922 (universal binaries,
  they run as arm64). Wine's build tools (makedep, winebuild, winegcc, widl, wrc, wmc, sfnt2fon) come from a native
  arm64 configure of the same patched tree (`work/build/wine-tools`, `make __tooldeps__`); the generators GMP, Nettle
  and FreeType run at build time are compiled with the native `CC_FOR_BUILD`. `build-deps.sh` and `build-wine.sh`
  check that every tool that ran is arm64.
- Clean paths: prefix `/nonexistent/adp-windows-engine` (cannot exist: the root volume is sealed), installs go to
  `DESTDIR` in `work/`, `-ffile-prefix-map=<work>/=adp-build/` on every compile. Wine's `dlopen` names for FreeType
  and GnuTLS become `@loader_path/../../ext/<file>`, CUPS `/usr/lib/libcups.2.dylib`, ODBC a file the engine does not
  ship, so nothing is looked up in `/usr/local/lib` and no `DYLD_*` variable is needed. GnuTLS has no trust-store
  file, priority file, PKCS #11 or locale folder compiled in (cross builds skip its trust-store autodetection; on
  macOS it uses the Keychain).
- Host tools from Homebrew (never shipped, never on the compiler's search paths): bison 3 (macOS has 2.3) and
  pkg-config (it reads only our own `.pc` files).

### Nothing newer than macOS 12.3 called without a check

The SDK is macOS 27's; the deployment target is 12.3. Wine's configure finds functions by linking against the SDK,
so it also finds ones that old Macs lack, and the compiler then weak-links them: on an older Mac the call goes to
address 0. The first clean build had one: `pipe2` (macOS 27.0+), which ntdll's `server_pipe()` calls as every Wine
process connects to wineserver. `wine --version` would have passed on an Intel Mac and everything after it crashed;
`minos 12.3` alone does not show this, and no Intel Mac can run macOS 27. Now:

- `build-wine.sh` configures with `ac_cv_func_pipe2=no` (Wine falls back to `pipe` + `FD_CLOEXEC`), refuses a
  `config.h` with `HAVE_PIPE2`, and fails on any `-Wunguarded-availability` warning except winemac.drv's two
  macOS 14 activation methods, which Wine sends only after `instancesRespondToSelector:` says they exist.
- `verify.sh` lists every weak import in every Mach-O and fails on any not reviewed as checked at run time. The
  reviewed ones: `__availability_version_check` (behind `__builtin_available`), ntdll's three `os_sync_*` calls
  (behind `__builtin_available(macOS 14.4)`, with a `__ulock` fallback) and six OpenCL 1.1 functions (weak because
  deprecated; present on 12.3). Run against the first build it failed on exactly `_pipe2`.
- A one-off scan of all 1520 symbols the engine imports strongly against the SDK headers' availability annotations
  found none introduced after 12.3. Only a run on macOS 12 proves it (section 5).

### No x86_64 code on the build Mac

Three layers (`env.sh`): configure always knows it is cross compiling; every cross configure, make and install runs
under `sandbox-exec` with `process-exec` denied inside the x86_64 build and install trees, and `tools/x86-cc` clears
the execute bit of every x86_64 executable it links; `tools/rosetta-watch` lists the process table 100 times a second
and fails the step if anything translated appears (`evidence/rosetta-guard.tsv`, one line per step).

**Rosetta incident (first run, before the barrier existed):** gnulib's locale probes in the libtasn1 and GnuTLS
configure scripts start `./conftest` even in a cross build. 24 of them (3 libtasn1, 21 GnuTLS) started under
Rosetta. The guard saw and killed each one, but a probe like that runs for milliseconds, so some may have finished
first (`evidence/rosetta-incident-first-build-deps.log`); Rosetta's `oahd` showed no extra CPU time. That broke the
no-Rosetta rule once. Nothing from that run is in the engine: those trees were deleted, the exec barrier and `x86-cc`
were added, and the engine was rebuilt from clean (the final build: 0 translated processes in every step). Under the barrier the same probes are refused and answer "none"
(`evidence/barrier-probes.txt`; the one that says `ja_JP.eucJP` comes from a file test, not from running anything).
They only feed gnulib's own test suite, which is not built.

## 3. Layout, manifests and identity

```
engine-x86_64-11.18-1/
  bin/wine -> ../lib/wine/x86_64-unix/wine     the loader (one entitled binary; child processes start from it)
  bin/wineserver                              no entitlements, never runs Windows code
  lib/wine/x86_64-unix/                       the loader, ntdll.so and Wine's other unix modules
  lib/wine/x86_64-windows/  lib/wine/i386-windows/   PE DLLs and programs (WoW64)
  lib/ext/                                    FreeType, GnuTLS, Nettle, Hogweed, GMP, libtasn1 (@loader_path)
  share/wine/   licenses/   ENGINE-NAME
```

- `dist/archive/engine-x86_64-11.18-1.app-manifest.json` is exactly ADP Monitor's `WindowsEngineManifest`
  (`Sources/FleetCore/WindowsApps/WindowsEngine.swift`): `archiveRoot engine-x86_64-11.18-1`, `wine bin/wine`,
  `wineserver bin/wineserver`, `nativeBinaries` the loader, `ntdll.so` and both `bin/` entries. `tools/check-manifest`
  compiles the app's own FleetCore code and checks it decodes, is valid, is chosen for Intel and refused for Apple
  chips, and that `MachOArchs` reads every native binary as x86_64 only. The URL is a placeholder
  (`ENGINE_URL=... ./archive.sh` sets the real one when the engine is hosted).
- `engine-x86_64-11.18-1.manifest.json` is the release manifest in the arm64 engine's format, with the app manifest
  inside (`engine-manifest.example.json` is a copy).
- Signing: all 36 Mach-O files with "Developer ID Application: Alex Parkin (2F2FVY326V)", hardened runtime, secure
  timestamp. Identifier `com.alexparkin.adpmonitor.winehost` for the loader, `com.alexparkin.adpmonitor.winehost.<file>`
  for everything else. No provisioning profile (Intel runs x86 Windows code natively, so the cross-architecture
  entitlement does not apply), no `keychain-access-groups`, no application identifier.
- ADP Monitor's root helper accepts only `identifier "com.alexparkin.adpmonitor"` and its signer clause
  (`Sources/ADPHelper/main.swift`). `verify.sh` evaluates that exact requirement against every Mach-O: all 36 fail
  it, all 36 pass the signer clause with their own identifier, and the same requirement accepts `ADP Monitor.app`
  (so the refusal is real). TCC grants are per identifier, so the engine shares none of ADP Monitor's.

### Entitlements (the loader only, `entitlements/loader.plist`)

- `com.apple.security.cs.allow-unsigned-executable-memory`: Windows programs and Wine itself need writable and
  executable memory at addresses Windows chooses (relocated PE images, `PAGE_EXECUTE_READWRITE` for JITs, packers,
  .NET). Wine uses plain `mmap`/`mprotect` for that, not `MAP_JIT`, so `allow-jit` is not enough; under the hardened
  runtime the kernel refuses those pages without this entitlement.
- `com.apple.security.cs.disable-library-validation`: Wine maps `.dll` and `.exe` files executable straight from
  disk; they have no Mach-O signature, and library validation refuses executable mappings of files not signed by
  Apple or our team (the arm64 matrix saw exactly this). It also lets a user replace `lib/ext`'s LGPL libraries with
  their own builds, as the LGPL expects.
- Not used: `allow-jit`, `allow-dyld-environment-variables` (library paths are `@loader_path`), `disable-executable-
  page-protection`, any device or keychain entitlement. `wineserver` and every library have no entitlements.
- Confirmed on an Intel Mac (section 5.1): without `disable-library-validation`, without
  `allow-unsigned-executable-memory`, or without both, `cmd /c ver`, `hello64.exe` and `hello32.exe` fail; with both
  they pass; adding `disable-executable-page-protection` changes nothing, so it stays out.

## 4. Proofs on the build Mac (`evidence/verify-archive.txt`, from the unpacked archive)

Archive `engine-x86_64-11.18-1.tar.xz`, 59,976,376 bytes, SHA-256
`bb512d1e1433926305707bed0ff24a10c481fc3d1a217abdee7a296f09788e87` (re-packing the same stage gives the same bytes).
Every line PASS:

| Check | Result |
|---|---|
| Architectures (`lipo -archs`, `file`) | 36 Mach-O files, all x86_64 only (34 libraries, 2 executables); 1637 PE files, all i386 or x86-64; `x86_64-unix` only, no `i386-unix` |
| Minimum macOS (`vtool -show-build`) | all 36: `platform MACOS minos 12.3 sdk 27.0` |
| Newer symbols | weak imports only the 10 reviewed ones (`pipe2` gone; `config.h` has no `HAVE_PIPE2`) |
| Linked libraries (`otool -L`, `LC_RPATH`) | only `/usr/lib`, `/System/Library`, `@loader_path`, `@rpath`; rpaths inside the engine |
| Path scan, all 1843 files, binary-safe | no `/Users/`, user name, build folder, `/opt/homebrew`, `/usr/local` (only in the text of our patches 0002/0003, which remove such paths), `/opt/local`, `/opt/X11`, `/sw/`. Left on purpose: the neutral prefix (3 files), `adp-build/` (mapped assert paths in GMP and GnuTLS), Wine's `/tmp/.wine-%u` server folder |
| Signatures (`codesign --verify --strict`, `-dvvv`) | all 36 valid, Developer ID Team 2F2FVY326V, hardened runtime, secure timestamp, identifiers under `com.alexparkin.adpmonitor.winehost`, none `com.alexparkin.adpmonitor`; entitlements only on the loader (the two above); no provisioning profile; the loader's Info.plist says `com.alexparkin.adpmonitor.winehost` |
| Root helper | its requirement accepts `ADP Monitor.app` and none of the 36 |
| App manifest | ADP Monitor's own `WindowsEngineManifest` code: decodes, `isValid`, offered to Intel, refused for Apple chips, `MachOArchs` x86_64 for all 4 native binaries |
| Licences | every text and notice on `verify.sh`'s list present (section 8), FreeType credit in `licenses/README.md` |
| No Rosetta | `evidence/rosetta-guard.tsv`: every step of the final clean build, 0 translated processes |

The same checks were repeated by hand outside `verify.sh` on a fresh unpack (lipo, file, vtool, codesign, the helper
requirement, a grep for 19 path patterns, `dyld_info -imports`), with the same results. The test kit's programs and
loaders carry no build paths either (`archive.sh` checks).

## 5. What must be tested on an Intel Mac

`dist/testkit/engine-x86_64-11.18-1-intel-test.tar` holds the archive, its SHA-256, `test-on-intel.sh`, `hello32.exe`,
`hello64.exe` (`tools/hello.c`) and the loader signed four other ways. On the Intel Mac: unpack it anywhere, then
`./test-on-intel.sh`. It needs only macOS (no Xcode, no Command Line Tools), no sudo, no network, opens no window,
removes everything it made (temporary folder, prefix, wineserver's `/tmp/.wine-<uid>` socket folder), and writes
`test-on-intel-<host>-<time>.log` next to itself. Exit 0 = every required check passed. Not on the venue iMac while
the venue is open (CLAUDE.md).

Required checks, in order (the script refuses to start on Apple silicon or under Rosetta):

1. Archive SHA-256, unpack, every Mach-O x86_64 only with a valid signature; Gatekeeper's verdict on the loader is
   logged (the engine is not notarised yet).
2. `wine --version` prints `wine-11.18` (the signed, hardened loader starts on a real Intel Mac; it does not need
   wineserver yet).
3. `wineboot -u` makes a new prefix (HOME and WINEPREFIX are temporary folders): ntdll, wineserver, the PE side.
   Then `wineserver -w` waits for wineserver to exit (Wine writes `system.reg` and `user.reg` only then; after 60 s
   the script stops it with `-k` and waits again) and the prefix must have `system.reg`.
4. `cmd /c ver` (64-bit).
5. `C:\windows\syswow64\cmd.exe /c ver` (32-bit through WoW64).
6. `hello64.exe` and `hello32.exe` (WoW64, must report `wow64=1`): executable memory written and called,
   SuspendThread + GetThreadContext (wineserver's Mach calls under the hardened runtime), schannel credentials
   (GnuTLS loaded from `lib/ext`), Tahoma found and measured (FreeType loaded from `lib/ext`).

Informational: the entitlement matrix (which entitlements are really needed), and with `--mac-driver` the Mac driver
starting on a logged-in desktop.

### 5.1 First run: the venue iMac, 21 Oct 2026

Log: `evidence/test-on-intel-<host>-20261021-162048.log` (ADP Monitor's repository; not published). iMac (Intel Core i7-10700K, 3.8 GHz), macOS 26.7.1
(25G241), run from the test kit with the default options (matrix on, no Mac driver). The engine is the archive
above (SHA-256 `bb512d1e...788e87`). Result line: `FAIL (1 of 10 required checks failed)`.

| Check | Result |
|---|---|
| Archive SHA-256 | PASS |
| Unpack | PASS: 1843 files, 418 MB, 4.0 s |
| Mach-O arch and signatures | PASS: 36 files, all x86_64 only, all valid; the loader `com.alexparkin.adpmonitor.winehost`, team 2F2FVY326V, its two entitlements. Gatekeeper (informational): `rejected source=Unnotarized Developer ID`, as expected before notarisation; the script removes quarantine as ADP Monitor does |
| `wine --version` | PASS: `wine-11.18`, 0.5 s |
| `wineboot -u` (new prefix) | PASS: 16.8 s. Only the usual headless `err:` lines (no graphics driver, which the script switches off; winegstreamer not built; winebth cannot start) |
| Prefix has `system.reg` | FAIL, a test-script bug: the old script looked straight after `wineboot -u` returned, while wineserver was still running, and Wine writes the registry files only when wineserver exits. The prefix itself worked: every step after this one ran in it. The script now waits for wineserver first (step 3 above); the copy in the test kit is updated |
| `cmd /c ver` (64-bit) | PASS: `Microsoft Windows 10.0.19045`, 0.4 s |
| `C:\windows\syswow64\cmd.exe /c ver` (32-bit, WoW64) | PASS: `Microsoft Windows 10.0.19045`, 0.4 s |
| `hello64.exe` | PASS, 2.0 s: x86_64 code, `wow64=0`; executable memory written and called; SuspendThread + GetThreadContext; schannel credentials (GnuTLS loaded from `lib/ext`); 870 font families, Tahoma measured (FreeType from `lib/ext`) |
| `hello32.exe` (WoW64) | PASS, 0.4 s: i386 code, `wow64=1`, process machine 0x014c; the same four checks pass |

Entitlement matrix (the loader swapped for one signed another way, same prefix):

| Loader | `--version` | `cmd /c ver` | `hello64` | `hello32` |
|---|---|---|---|---|
| without `disable-library-validation` | pass | FAIL (exit 1) | FAIL | FAIL |
| without `allow-unsigned-executable-memory` | pass | FAIL (exit 137, killed) | FAIL | FAIL |
| neither | pass | FAIL (exit 1) | FAIL | FAIL |
| both plus `disable-executable-page-protection` (diagnostic) | pass | pass | pass | pass |

Without library validation disabled, Wine cannot map its PE files executable (`failed to set 60000020 protection on
...ntdll.dll section .text`); without unsigned executable memory the process is killed (SIGKILL, exit 137). So the shipped pair is
exactly what the engine needs on Intel, and the stronger page-protection exception is not needed.

Next: rerun the fixed `test-on-intel.sh` on an Intel Mac (all ten required checks should pass), then the hand checks
below.

Still not covered by the script, to do by hand on an Intel Mac before the engine replaces Gcenx's in
`WindowsEngineCatalog`:

- The oldest supported system (macOS 12.3 or the oldest 12.x available): the deployment target is only proven by the
  load commands; no API newer than 12.3 is known to be called, but only a run proves it. The first run (5.1) was on
  macOS 26.7.1.
- ADP Monitor's own flow with this manifest (download, hash, unpack, `wine --version` through `DisclaimedSpawn`,
  golden bottle, app shims) instead of the script's.
- Real programs with windows: PuTTY 64 and 32, the 7-Zip installer and File Manager, Notepad++ (the arm64 engine's
  set), text rendering, the Dock name per program (patch 0022), display-mode emulation (0033).
- An HTTPS connection from a Windows program (GnuTLS handshake, certificates from the Keychain via crypt32, patch 0003).
- A quarantined copy (as a browser leaves it) once the engine is notarised.

## 6. Not done here

- Not notarised (`notarized: false` in the release manifest); not hosted (placeholder URL); `WindowsEngineCatalog`
  and the design brief still name Gcenx wine-stable 11.0_1 for Intel Macs. Those change after the Intel test passes
  in full (the first run, 5.1, failed one check because of the script's timing bug).
- The source archive for LGPL compliance (Wine tree, patches, library tarballs) is pinned and reproducible from
  `sources.tsv`, but not packed as a downloadable source bundle yet (`spikes/windows-engine-release` does that).
