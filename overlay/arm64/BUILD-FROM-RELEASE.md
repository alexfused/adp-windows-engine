# Rebuilding engine-arm64-11.18-2 from the release

This folder is the release asset `adp-engine-arm64-11.18-2-build.tar.xz`: the scripts that built the Apple silicon
engine (`SOURCES.md` and `RESULTS.md` describe it), the Hadron patches they applied (`hadron/`), and
`unpack-sources.sh`, which prepares a build from the release's source files instead of from the network.
`IMPORTED.md` says how this copy differs from the one in ADP Monitor's repository.

Needs an Apple silicon Mac with macOS 27 or later, Xcode 27 (Apple clang 21), and Homebrew's `llvm lld bison flex
cmake ninja pkgconf` as build tools (nothing from Homebrew is linked into the engine). No Rosetta: `env.sh` refuses
to run translated.

```sh
gh release download engines-2026-10-21b -R alexfused/adp-windows-engine -D src \
    -p 'wine-6880117*' -p 'fex-0df84d38*' -p 'adp-engine-arm64-*' \
    -p 'gmp-*' -p 'nettle-*' -p 'libtasn1-*' -p 'libunistring-*' -p 'libidn2-*' \
    -p 'gnutls-*' -p 'libpng-*' -p 'freetype-2.14.3*'
shasum -a 256 -c SHA256SUMS --ignore-missing     # after downloading SHA256SUMS too
tar -xf src/adp-engine-arm64-11.18-2-build.tar.xz
cd adp-engine-arm64-11.18-2-build
./unpack-sources.sh ../src     # Wine and FEX patched as in the build; lib/ext tarballs; llvm-mingw
./build-ext.sh                 # GMP, Nettle, libtasn1, libunistring, libidn2, GnuTLS, libpng, FreeType
./build-wine.sh
./build-fex.sh
./package.sh                   # signs: needs an identity and a provisioning profile, see below
./archive.sh
```

`unpack-sources.sh` applies the patches `patches.conf` marks `apply` with `git am --3way`; the trees it makes are
the same files the engine was built from (the release's `tools/verify.sh` checks this).

## Signing

`package.sh` signs with `IDENTITY` in `env.sh` and embeds the provisioning profile `ADP_PROFILE`, which must grant
`com.apple.developer.cross-architecture-support` to the App ID `ADP_BUNDLE_ID` (ours is
`com.alexparkin.adpmonitor.winehost`). Apple restricts that entitlement, so without such a profile you cannot
reproduce this step exactly; everything before `package.sh` builds without it.

## Replacing a library

The LGPL libraries are separate files in `lib/ext/` (loaded through `@loader_path`), Wine's unix modules are
`lib/wine/aarch64-unix/*.so` and its Windows DLLs `lib/wine/aarch64-windows/` and `lib/wine/i386-windows/`.
`WineHost.app` is signed with `com.apple.security.cs.disable-library-validation`, so a replacement `.dylib` or
`.so` signed ad hoc (`codesign --force --sign - FILE`) is loaded. Replacing the loader itself means re-signing
`WineHost.app`, which drops the cross-architecture entitlement unless your profile grants it.
