# ADP Monitor Windows engines

ADP Monitor is a free Mac app that monitors and controls venue Macs. To run Windows programs it uses Wine, which it
downloads separately from the app. This repository publishes those Wine builds (the "engines"), their licence
texts, their complete source code and the scripts that built them. The files are attached to the releases; the
repository holds the scripts, manifests and licence texts.

## The engines

Both engines are built from source by the scripts in this repository, from the same Wine tree.

| Engine | For | What it is | Archive |
|---|---|---|---|
| `engine-arm64-11.18-2` | Apple silicon Macs, macOS 27 or later | Wine 11.18 development snapshot with 30 of Hadron's patches, and FEX inside Wine to run x86 and x86-64 Windows code. It does not use Rosetta. Notarised by Apple. | `engine-arm64-11.18-2.tar.xz`, 85,920,516 bytes; 1,822 files (1,010,637,269 bytes) unpacked |
| `engine-x86_64-11.18-1` | Intel Macs, macOS 12.3 or later | The same Wine tree with 16 of Hadron's patches and 3 of ours, running x86 and x86-64 Windows code natively. Cross-compiled on Apple silicon. Notarised by Apple on 22 October 2026, after the release. | `engine-x86_64-11.18-1.tar.xz`, 59,976,376 bytes; 1,843 files (438,046,967 bytes) unpacked |

SHA-256 of the archives:

```
67cb8cde7299c701a3aae047ba13ae7fff69237904e383eae8536d1f8e8e1c94  engine-arm64-11.18-2.tar.xz
bb512d1e1433926305707bed0ff24a10c481fc3d1a217abdee7a296f09788e87  engine-x86_64-11.18-1.tar.xz
```

**The Intel engine has had one test run, which did not fully pass.** Its build Mac is Apple silicon, and the build
scripts refuse to run x86_64 code there, so it is tested with `test-on-intel.sh` on an Intel Mac
([`x86_64/README.md`](x86_64/README.md), section 5). The first run, on 21 October 2026 on an Intel iMac with macOS
26.7.1, passed 9 of the 10 required checks (`wine --version`, a new prefix, 64-bit and 32-bit `cmd`, and two test
programs that check executable memory, thread contexts, TLS and fonts). The tenth failed because of a timing bug in the
test script, now fixed. Until a run passes every check, ADP Monitor does not offer the Intel engine.

Each engine's libraries for TLS and fonts (GnuTLS with Nettle, GMP and libtasn1, and FreeType; on Apple silicon also
libidn2, libunistring and libpng) are built from their release tarballs into the engine's `lib/ext/`. Nothing in
either engine is a package manager's binary.

## Signing and identity

Every Mach-O file in both engines is signed with Alex Parkin's Developer ID (team 2F2FVY326V), hardened runtime and
a secure timestamp, under the engine's own identifier `com.alexparkin.adpmonitor.winehost` (other files:
`com.alexparkin.adpmonitor.winehost.<file>`). None uses ADP Monitor's own identifier, `com.alexparkin.adpmonitor`, so
an engine gets none of ADP Monitor's privacy permissions and ADP Monitor's root helper refuses it as a caller.
`publish-release.sh` checks this on the files themselves before anything is published (see "Making a release").

The Apple silicon loader, `WineHost.app`, carries a provisioning profile for that App ID with Apple's
cross-architecture entitlement; the Intel loader needs no profile.

Apple notarised both engines. The Apple silicon engine's ticket is stapled to `WineHost.app`. Apple notarised the
Intel engine on 22 October 2026, after this release was published (submission
`9d595ff6-8168-4498-a284-1663f99781f8`, 0 issues). The notary service checked a zip of the files in the published
archive, and its ticket lists the code directory hash of all 36 Mach-O files. The archive and its SHA-256 did not
change. The Intel engine has no app to staple a ticket to, so Gatekeeper fetches the ticket from Apple when it checks a
file. On a copy unpacked from the release and quarantined as a browser download is,
`spctl --assess --type open --context context:primary-signature` accepts each of the 36 files as
`Notarized Developer ID`. The release's `engine-x86_64-11.18-1.manifest.json` was written before notarisation and still
says `"notarized": false`. It stays as published, so every release file still matches `SHA256SUMS`.

## Which version of ADP Monitor uses them

No released version of ADP Monitor uses these engines yet. They are for its Windows programs feature, which is in
development. The first ADP Monitor build that uses an engine will pin it by the URL and SHA-256 in that engine's
manifest, so a new engine is always a deliberate update of ADP Monitor.

## Files in a release

| File | What it is |
|---|---|
| `<engine>.tar.xz` | The engine |
| `<engine>.manifest.json` | Download URL, SHA-256 and size of the archive, its layout (where `wine` and `wineserver` are), a health check (`bin/wine --version`), signing details, and the URL, SHA-256 and size of every source file for that engine. Every `url` in it is a file of the same release; the original address of an upstream file is kept as `upstreamUrl`. The Intel manifest also holds ADP Monitor's own manifest for the engine (`app`). |
| `<engine>.THIRD-PARTY-LICENSES.md` | Every component of that engine with its version and licence, and the full text of every licence and notice. ADP Monitor shows this file with the engine. |
| `SHA256SUMS` | SHA-256 of every file in the release. Check downloads with `shasum -a 256 -c SHA256SUMS --ignore-missing`. |
| everything else | Source code: upstream source tarballs, and our own tarballs listed below |

Source files, by engine:

| Engine | Component | Source file in the release |
|---|---|---|
| both | Wine at commit `6880117619af` (with FFmpeg, FluidSynth, mpg123, vkd3d and the other libraries Wine bundles) | `wine-6880117619afdf62b4ccc40a8c6268c86613131f.tar.gz` (GitLab's archive of that commit) |
| both | GnuTLS 3.8.13 and upstream commit 29c2027c, Nettle 4.0, GMP 6.3.0, libtasn1 4.21.0 | `gnutls-3.8.13.tar.xz`, `gnutls-3.8.13-29c2027c.diff`, `nettle-4.0.tar.gz`, `gmp-6.3.0.tar.xz`, `libtasn1-4.21.0.tar.gz` |
| Apple silicon | FEX at commit `0df84d3844bc`, with the submodules the build compiles | `fex-0df84d3844bcdb87bb7d3f5b8fb0959cd009c038-src.tar.xz` (ours: `git archive` of FEX and of each submodule) |
| Apple silicon | FreeType 2.14.3, libpng 1.6.59, libidn2 2.3.8, libunistring 1.4.2 | `freetype-2.14.3.tar.xz`, `libpng-1.6.59.tar.xz`, `libidn2-2.3.8.tar.gz`, `libunistring-1.4.2.tar.gz` |
| Apple silicon | Build scripts, Hadron's Wine and FEX patches as applied | `adp-engine-arm64-11.18-2-build.tar.xz` (ours: the [`arm64/`](arm64/) folder) |
| Intel | FreeType 2.15.0 | `freetype-2.15.0.tar.xz` |
| Intel | Build scripts, our 3 Wine patches, Hadron's Wine patches as applied | `adp-engine-x86_64-11.18-1-build.tar.xz` (ours: the [`x86_64/`](x86_64/) folder) |

Every upstream tarball comes from its project's own site or an official mirror and has the SHA-256 the engines'
build scripts pin (taken from Homebrew's formulae). The Wine archive has no published hash; `tools/verify.sh` shows
that it, with each engine's patches, gives exactly the tree that engine was built from.
[`tools/sources.tsv`](tools/sources.tsv) lists each URL and where its hash came from.

The FEX tarball leaves out FEX's submodules that the build does not compile (the VIXL library, Zydis, tracy, jemalloc, Catch2,
the Vulkan and DRM headers, and three folders of prebuilt Linux test programs), and the submodule nested inside
range-v3 (its generated HTML documentation). `SUBMODULES-ADP.txt` in the tarball lists every submodule with its
pinned commit and address. FEX's own tree, which the tarball holds in full, does carry a few functions taken from
VIXL (`CodeEmitter/CodeEmitter/VixlUtils.inl`) and some musl routines (`Source/Windows/Common/CRT/Musl/`); both are
compiled into the FEX DLLs and listed with their licences in [`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md).

llvm-mingw 20260922 (`llvm-mingw-20260922-ucrt-macos-universal.tar.xz`, SHA-256 `52e5f5a7...bc1f3`) is the PE
compiler for both builds. It is a build tool, not part of either engine's source, and is not in the release; its
runtime is linked into the FEX DLLs under the Apache-2.0 licence with the LLVM exception.

## Rebuilding

**Apple silicon:** [`arm64/BUILD-FROM-RELEASE.md`](arm64/BUILD-FROM-RELEASE.md). On an Apple silicon Mac with macOS
27 and Xcode: download the source files from the release, unpack the build tarball, run `unpack-sources.sh`, then
`build-ext.sh`, `build-wine.sh`, `build-fex.sh`, `package.sh` and `archive.sh`. Signing needs a provisioning profile
that grants Apple's cross-architecture entitlement; everything before it builds without one.

**Intel:** [`x86_64/BUILD-FROM-RELEASE.md`](x86_64/BUILD-FROM-RELEASE.md). On an Apple silicon Mac with macOS 27 and
Xcode: unpack the build tarball, run `unpack-sources.sh`, then `build-deps.sh`, `build-wine.sh`, `package.sh` and
`archive.sh`.

## Replacing a library

Wine, GnuTLS and the other LGPL libraries in the engines are separate files, so you can replace them with your own
builds: the macOS libraries are in `lib/ext/`, Wine's in `lib/wine/`. Each engine's loader is signed to allow
libraries that are not signed by us (`com.apple.security.cs.disable-library-validation`), so a replacement signed ad
hoc is loaded. The two `BUILD-FROM-RELEASE.md` files have the details and the limits.

## Licences

- The engines are made of third-party software under its own licences. Wine is LGPL-2.1-or-later. The full list,
  with versions, copyright lines and links to every licence text, is [`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md);
  the texts are in [`licenses/`](licenses/).
- This repository's own files (the README and other documents, `tools/`, `overlay/`, the build scripts in `arm64/`
  and `x86_64/`, `publish-release.sh`, `release.conf`, `components.json`, the manifests) are under the MIT licence in
  [`LICENSE`](LICENSE). The third-party files kept here keep their own licences: `licenses/`, `overlay/hadron/`,
  `arm64/hadron/` and `x86_64/hadron/` (Hadron's patches: LGPL-2.1-or-later for Wine, MIT for FEX), and our own Wine
  patches in `x86_64/patches/`, which are LGPL-2.1-or-later like Wine.
- Credits the licences ask for are in [`NOTICE.md`](NOTICE.md).

This project is not affiliated with or endorsed by WineHQ, CodeWeavers, the FEX project or Hadron.

## Making a release

For ADP Monitor's maintainer. The scripts run in ADP Monitor's repository (this folder is its
`spikes/windows-engine-release`), on the Mac that built the engines; none of them is needed to use the engines.
`ARM64_SPIKE` and `X86_64_SPIKE` name the two build folders if they are not next to this one.

| Step | Script |
|---|---|
| Get every upstream file and check its hash (a verified copy on the Mac is cloned instead of downloaded) | `tools/fetch.sh` |
| Copy the build scripts from the ADP Monitor commits that built the engines into `arm64/` and `x86_64/`, make our tarballs, collect licence texts, write the licence files, manifests and `SHA256SUMS` | `tools/build-assets.sh` |
| Check all of it, including that the release's source files rebuild the exact source trees of both engines | `tools/verify.sh` |
| Create the repository, push these files and upload the release, skipping whatever is already there | `publish-release.sh --dry-run`, then `publish-release.sh` |

[`release.conf`](release.conf) names the repository, the tag, the engines, the commit identity and the identity
guard. `publish-release.sh` refuses to publish, with no option to override it, when:

- any Mach-O file or app in an engine archive is signed with ADP Monitor's identifier, is not validly signed, or is
  accepted by ADP Monitor's root-helper requirement (`tools/engine-guard.py` reads the actual signatures with
  `codesign`, and first shows that the requirement accepts ADP Monitor.app);
- a Mach-O or PE file names `/opt/homebrew`, `/usr/local`, `/opt/local`, `/Users/` or `/tmp` and
  [`tools/path-scan.allow`](tools/path-scan.allow) does not explain that exact string in that file of that engine
  (each line there gives the reason, with the Wine or FEX source file to check it against);
- any file of the repository or the release names a personal path of the Mac that built it;
- `tools/verify.sh` fails, or `CONFIRM_SCRIPTS_LICENCE` in `release.conf` is not `yes`.

Commits to this repository use the GitHub account's no-reply address (`PUBLISH_GIT_EMAIL`), checked against the
account before each commit.

## Repository layout

| Folder | What |
|---|---|
| `tools/` | The release scripts (above) and their data: `sources.tsv`, `scrubs.tsv`, `path-scan.allow` |
| `overlay/` | Files this repository adds to the build folders: `unpack-sources.sh` and `BUILD-FROM-RELEASE.md` per engine, and Hadron's patch files (`overlay/hadron/`) |
| `arm64/`, `x86_64/` | Written by `tools/import-build-scripts.py`: the build folder of each engine at the commit that built it, with `overlay/` added and the changes in `tools/scrubs.tsv`. Each one's `IMPORTED.md` says exactly what. These are the two build tarballs. |
| `manifests/`, `licenses/` | Written by `tools/build-assets.sh` |
