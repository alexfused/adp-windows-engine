# Notice

The releases of this repository redistribute third-party software. Each engine's
`<engine>.THIRD-PARTY-LICENSES.md` (in the release) and [`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md)
(here) list every component with its version, licence and copyright lines, and reproduce the licence texts.

## Main components

- Wine. Copyright (c) 1993-2026 the Wine project authors. GNU LGPL 2.1 or later. https://www.winehq.org
- FEX (Apple silicon engine). Copyright (c) 2019 Ryan Houdek and the FEX contributors. MIT. https://github.com/FEX-Emu/FEX
- Hadron's Wine and FEX patches. Copyright (c) 2026 David Andrews. LGPL 2.1 or later (Wine patches), MIT (FEX
  patches). https://github.com/Broyojo/hadron
- GnuTLS, Nettle, GMP and libtasn1 (both engines), libidn2 and libunistring (Apple silicon engine): LGPL. FreeType
  (both, under the FreeType Licence) and libpng (Apple silicon engine): permissive. Each built from its release
  tarball for the engine.
- The third-party code Wine builds in (FFmpeg, FluidSynth, mpg123, vkd3d, Capstone, FAudio, MS-ICU, libjpeg, Little
  CMS, OpenLDAP, musl, libpng, SQLite, SymCrypt, LibTIFF, libxml2, libxslt, zlib and others), listed in Wine's
  `NOTICES.md`.
- The third-party code FEX builds in (Apple silicon engine): Berkeley SoftFloat 3e, cephes, {fmt}, xxHash, tiny-json,
  unordered_dense, rpmalloc, range-v3 and cpp-optparse, and two pieces that sit in FEX's own source tree: functions
  taken from VIXL (Copyright 2015, VIXL authors; BSD 3-Clause; licence below) and musl routines (Copyright © 2005-2020
  Rich Felker, et al.; exp2 and log2 Copyright (c) 2018, Arm Limited; MIT). All are in FEX's two DLLs.

## VIXL licence (code in FEX)

FEX's `CodeEmitter/CodeEmitter/VixlUtils.inl` is taken from VIXL and carries this licence:

```text
Copyright 2015, VIXL authors
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.
  * Neither the name of ARM Limited nor the names of its contributors may be
    used to endorse or promote products derived from this software without
    specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Modifications

- `engine-arm64-11.18-2`: Wine (upstream commit 6880117619af) and FEX (upstream commit 0df84d3844bc) are modified by
  Hadron's patches listed in `arm64/patches.conf`. GnuTLS has upstream commit 29c2027c applied. Built on 21 October
  2026.
- `engine-x86_64-11.18-1`: Wine (the same upstream commit) is modified by 16 of Hadron's patches listed in
  `x86_64/patches.conf` and by our 3 patches in `x86_64/patches/`. GnuTLS has upstream commit 29c2027c applied.
  Built on 21 October 2026.
- In both, the libraries in `lib/ext/` have their install names rewritten to `@loader_path` and their local symbols
  stripped, and every Mach-O file is signed with Alex Parkin's Developer ID under the engine's own identifier
  `com.alexparkin.adpmonitor.winehost`.

## Credits

- This software is based in part on the work of the Independent JPEG Group.
- Portions of this software are copyright © 2026 The FreeType Project (https://freetype.org). All rights reserved.
  (Apple silicon engine, FreeType 2.14.3; Intel engine, FreeType 2.15.0)

## Source code

Each release contains the complete corresponding source of every LGPL and GPL component of its engines, the
source of every library built into `lib/ext/`, and the scripts used to build, install and package them. See
"Files in a release" in [`README.md`](README.md).

## Trademarks and endorsement

"Wine" and "WineHQ" belong to their owners. This project is not affiliated with or endorsed by WineHQ, CodeWeavers,
the FEX project or Hadron.
