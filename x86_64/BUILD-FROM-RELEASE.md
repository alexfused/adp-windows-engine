# Rebuilding engine-x86_64-11.18-1 from the release

This folder is the release asset `adp-engine-x86_64-11.18-1-build.tar.xz`: the scripts that built the Intel engine
(`README.md` and `SOURCES.md` describe it), our three Wine patches (`patches/`), the Hadron patches they applied
(`hadron/patches/wine/`, pinned in `patches.sha256`), and `unpack-sources.sh`, which prepares a build from the
release's source files instead of from the network. `IMPORTED.md` says how this copy differs from the one in ADP
Monitor's repository.

The engine is cross-compiled on an Apple silicon Mac (macOS 27, Xcode 27) and never run there: the scripts refuse
Rosetta and run every x86_64 build step under an exec barrier (`env.sh`). Homebrew's `bison` and `pkg-config` are
build tools only. The result is tested on an Intel Mac with `test-on-intel.sh` (`README.md`, section 5).

```sh
gh release download engines-2026-10-21b -R alexfused/adp-windows-engine -D src \
    -p 'wine-6880117*' -p 'adp-engine-x86_64-*' -p 'gmp-6.3.0.tar.xz' -p 'nettle-*' \
    -p 'libtasn1-*' -p 'gnutls-*' -p 'freetype-2.15.0*'
tar -xf src/adp-engine-x86_64-11.18-1-build.tar.xz
cd adp-engine-x86_64-11.18-1-build
./unpack-sources.sh ../src     # stages the files, then fetch.sh checks every hash and patches the trees
./build-deps.sh
./build-wine.sh
./package.sh                   # signs with a Developer ID identity (ADP_ENGINE_IDENTITY)
./archive.sh
```

## Replacing a library

The LGPL libraries are separate files in `lib/ext/` (loaded through `@loader_path`); Wine's unix modules are
`lib/wine/x86_64-unix/*.so` and its Windows DLLs `lib/wine/x86_64-windows/` and `lib/wine/i386-windows/`. The
loader is signed with `com.apple.security.cs.disable-library-validation`, so a replacement signed ad hoc
(`codesign --force --sign - FILE`) is loaded.
