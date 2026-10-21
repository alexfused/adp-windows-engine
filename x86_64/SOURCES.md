# Sources of the Intel engine (engine-x86_64-11.18-1)

Every input is pinned by SHA-256 (`sources.tsv`, `patches.sha256`); `fetch.sh` refuses anything else. Change a pin
here and in those files together. The engine itself carries a generated copy of this information
(`licenses/SOURCES.md`, with the configure options actually used).

| Component | Version | Licence | Source | SHA-256 | Where the hash comes from |
|---|---|---|---|---|---|
| Wine | 11.18, commit `6880117619afdf62b4ccc40a8c6268c86613131f` (Hadron's pin, the arm64 engine's tree) | LGPL-2.1-or-later | GitLab archive of that commit | `4dbd908aaf6207da5a540ee4681c79f8a3523240c12a80989a6e075c86ae893f` | none published; recorded by `spikes/windows-engine-release`, whose `verify.sh` checks the content equals git tree 6880117619af |
| Hadron's Wine patches | `Broyojo/hadron` at `d523fe6b8fa0d8632911d49d02980769f2d4261c`, 16 of 39 (`patches.conf`) | LGPL-2.1-or-later | `patches/wine/` at that commit | per file in `patches.sha256` | the files the arm64 engine applied |
| Our Wine patches | `patches/0001-0003` in this folder | LGPL-2.1-or-later | this repository | (in git) | |
| GMP | 6.3.0 | LGPL-3.0-or-later or GPL-2.0-or-later | gmplib.org | `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898` | Homebrew formula gmp 6.3.0 |
| Nettle (with Hogweed) | 4.0 | LGPL-3.0-or-later or GPL-2.0-or-later | ftp.gnu.org | `3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094` | Homebrew formula nettle 4.0 |
| libtasn1 | 4.21.0 | LGPL-2.1-or-later | ftp.gnu.org | `1d8a444a223cc5464240777346e125de51d8e6abf0b8bac742ac84609167dc87` | Homebrew formula libtasn1 4.21.0 |
| GnuTLS | 3.8.13 | LGPL-2.1-or-later (parts LGPL-3.0+/GPL-2.0+, BSD-3-Clause, MIT) | gnupg.org | `ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e` | Homebrew formula gnutls 3.8.13_2 |
| GnuTLS fix | upstream commit `29c2027c` (clang build fix for `lib/crau/crau.h`) | LGPL-2.1-or-later | gitlab.com/gnutls | `c0bfc0164ff131c9d2e1c4d0367430f8b767b64c9c21e0f408bd634d21fb0302` | Homebrew formula gnutls 3.8.13_2 (patch block) |
| FreeType | 2.15.0 | FTL (chosen of FTL / GPL-2.0) | sourceforge / savannah | `93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5` | Homebrew formula freetype 2.15.0 (current on 21 Oct 2026) |
| llvm-mingw (PE compiler, not shipped) | 20260922, ucrt, macOS universal | Apache-2.0 with LLVM exception and others | GitHub release | `52e5f5a7b131021d0c39a37a38fa380a1da7885cd04bd61afd0cd4ecfb8bc1f3` | the arm64 engine's pin (Hadron's `setup-toolchain.sh`) |

Versions are the current releases on 21 Oct 2026 (GnuTLS 3.8.13 is the newest on gnupg.org; FreeType 2.15.0 is
Homebrew's current pin). libtasn1 is built separately rather than GnuTLS's bundled copy, which is 4.20.0.

Not in the engine, and why: libidn2 and libunistring (GnuTLS uses its own copy of the few libunistring functions it
needs, `--with-included-unistring`; IDNA is off), gettext (no translations: `--disable-nls`), p11-kit (no PKCS #11),
zlib/brotli/zstd in GnuTLS (no certificate compression), FreeType's HVF driver (experimental, macOS 15.4+ only),
Wine Mono and Gecko (as in the arm64 engine).

Build host tools (run on the Mac that builds, never shipped): Xcode clang and the macOS SDK (`xcrun`), Homebrew's
bison 3.8 (macOS has 2.3; it generates C parsers) and pkg-config (it reads only our own `.pc` files), macOS's flex,
m4, make, perl.
