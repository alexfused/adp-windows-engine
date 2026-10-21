# Sources (engine-arm64-11.18-2, 21 Oct 2026)

Everything the engine is made of was built on this Mac from the sources below. No prebuilt Wine, FEX, Hadron or
Homebrew library ships in it (11.18-1 carried Homebrew bottles in `lib/ext`; 11.18-2 builds those from upstream
tarballs). `fetch.sh` repeats all of it and refuses a toolchain or tarball whose SHA-256 differs. The engine's own
`licenses/SOURCES.md` (written by `package.sh`) repeats this per component and says exactly how each was changed.

## Built from source

| What | Where | Revision |
|---|---|---|
| Hadron (patch queues and pins only; none of its scripts or binaries ship) | https://github.com/Broyojo/hadron.git | `d523fe6b8fa0d8632911d49d02980769f2d4261c` (main, 20 Oct 2026; VERSION 0.3.1) |
| Wine | https://gitlab.winehq.org/wine/wine.git (Hadron's `sources.conf` pin) | `6880117619afdf62b4ccc40a8c6268c86613131f` (28 Sep 2026, "Wine version 11.18" + 246 commits), plus 30 of Hadron's 39 Wine patches (`patches.conf`); builds as `wine-11.18-276-g8f4bf95c31` |
| FEX | https://github.com/FEX-Emu/FEX.git with submodules (Hadron's pin) | `0df84d3844bcdb87bb7d3f5b8fb0959cd009c038` (28 Sep 2026), plus Hadron's 5 FEX patches (patched HEAD `a5eec1a8ce41`) |

Licences: Wine LGPL 2.1+, FEX MIT, Hadron's own code BSD-3 (none of it is used), Hadron's Wine patches LGPL 2.1+,
its FEX patches MIT (`patches/wine/LICENSE`, `patches/fex/LICENSE` in Hadron). Hadron's FEX patches are AI-written
by its author's account; FEX upstream accepts no AI-written code, so they stay downstream (Hadron's roadmap says the same).

## lib/ext (`ext.conf`, `build-ext.sh`)

Official tarballs, SHA-256 as Homebrew's formulae pin them (the licence review downloaded the same files from these
URLs; `fetch.sh` clones that copy when the hash matches, otherwise downloads). Same versions as 11.18-1.

| Library | Tarball | SHA-256 |
|---|---|---|
| GMP 6.3.0 | https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz | `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898` |
| Nettle 4.0 | https://ftp.gnu.org/gnu/nettle/nettle-4.0.tar.gz | `3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094` |
| libtasn1 4.21.0 | https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.21.0.tar.gz | `1d8a444a223cc5464240777346e125de51d8e6abf0b8bac742ac84609167dc87` |
| libunistring 1.4.2 | https://ftp.gnu.org/gnu/libunistring/libunistring-1.4.2.tar.gz | `e82664b170064e62331962126b259d452d53b227bb4a93ab20040d846fec01d8` |
| libidn2 2.3.8 | https://ftp.gnu.org/gnu/libidn/libidn2-2.3.8.tar.gz | `f557911bf6171621e1f72ff35f5b1825bb35b52ed45325dcdee931e5d3c0787a` |
| GnuTLS 3.8.13 | https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz | `ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e` |
| GnuTLS commit 29c2027c (header build fix, applied) | https://gitlab.com/gnutls/gnutls/-/commit/29c2027c963cf559817d0da37c1fc2efd0c1bd6a.diff | `c0bfc0164ff131c9d2e1c4d0367430f8b767b64c9c21e0f408bd634d21fb0302` |
| libpng 1.6.59 | https://downloads.sourceforge.net/project/libpng/libpng16/1.6.59/libpng-1.6.59.tar.xz | `d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389` |
| FreeType 2.14.3 | https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz | `36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f` |

Dropped: p11-kit (GnuTLS `--without-p11-kit`) and gettext's libintl (GnuTLS and libidn2 `--disable-nls`).
The configure line of each library is in `build-ext.sh` and, as run, in the engine's `licenses/SOURCES.md`.

## Toolchain

| What | Version | Source and hash |
|---|---|---|
| llvm-mingw (PE cross toolchain for FEX's DLLs and the test programs) | 20260922, `llvm-mingw-20260922-ucrt-macos-universal.tar.xz`, 124,289,672 bytes, clang 23.1.2 | https://github.com/mstorsjo/llvm-mingw/releases/download/20260922/llvm-mingw-20260922-ucrt-macos-universal.tar.xz, SHA-256 `52e5f5a7b131021d0c39a37a38fa380a1da7885cd04bd61afd0cd4ecfb8bc1f3`. Universal binary: the arm64 slice runs, natively. Its static C++ runtime goes into the FEX DLLs. |
| Homebrew (arm64 bottles; build tools only, nothing of it is linked or shipped since 11.18-2) | llvm 23.1.3_2 (Wine's PE compiler), lld 23.1.3, bison 3.8.2, flex 2.6.4_2, ninja 1.13.2, cmake 4.4.4, pkgconf 3.0.10 | Homebrew 7.0.9, `brew config`: `Rosetta 2: false` |
| Apple | Xcode clang 21.0.0 (clang-2100.3.34.2), macOS SDK 27.0 | Wine's unix side, lib/ext, the FEX unix helpers, the probe tools |

## Test programs (not downloaded again)

Copied from the Tier 1 spike's `downloads/` (`spikes/windows-apps/downloads` in ADP Monitor)
by `programs.sh`, which checks each against the hash in `spikes/windows-apps/SOURCES.md`:
PuTTY 0.85 64-bit `d01fdb5a...6c87`, PuTTY 0.85 32-bit `4c70267c...fb3b`, 7-Zip 26.04 installer `d54bf805...665d`,
Notepad++ 8.9.8.1 portable x64 zip `beddf554...f414`. `hello-x86_64.exe`, `hello-i686.exe` (`programs.sh`'s ten-line
C source) and `tls-check-x86_64.exe` (`tools/tls-check.c`) are built here with llvm-mingw.

## This folder

The scripts, tools and documents here are MIT-licensed (`LICENSE`).
