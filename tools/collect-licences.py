#!/usr/bin/env python3 -I
# SPDX-License-Identifier: MIT
"""Copy every licence and notice text the two engines need into licenses/<engine>/<component>/.

Reads only verified inputs: the upstream tarballs tools/fetch.sh checked (downloads/fetch/), our FEX source tarball
(downloads/own/), Hadron's licence files (overlay/hadron/), and llvm-mingw's licence as the arm64 engine archive
ships it (its runtime is inside the FEX DLLs). Writes licenses/INDEX.tsv with
each file's SHA-256 and where it came from. Rerunnable: licenses/ is rebuilt from scratch each time.
Usage: python3 -I tools/collect-licences.py
"""
import hashlib, os, re, shutil, subprocess, sys, tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FETCH = os.path.join(ROOT, "downloads", "fetch")
OWN = os.path.join(ROOT, "downloads", "own")
OUT = os.path.join(ROOT, "licenses")
HADRON = os.path.join(ROOT, "overlay", "hadron")


def conf(*keys):
    script = f'source "{ROOT}/release.conf"; ' + "; ".join(f'printf "%s\\0" "${k}"' for k in keys)
    out = subprocess.run(["bash", "-c", script], capture_output=True, check=True).stdout.decode()
    return dict(zip(keys, out.split("\0")))


C = conf("FEX_COMMIT", "ARM64_ARCHIVE", "ARM64_ENGINE")
index = []
_tars = {}
# Source files whose leading comment is the licence notice we need (read by header_from_tar).
HEADER_FILES = {"External/SoftFloat-3e/src/extF80_add.c", "src/gzip/zlib.h", "src/autofit/ft-hb-ft.c",
                "lib/accelerated/aarch64/macosx/ghash-aarch64.s", "CodeEmitter/CodeEmitter/VixlUtils.inl"}
LICENCE_NAME = re.compile(r"(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|README|AUTHORS|FTL|GPLv2|UNLICENSE|\.md$)", re.I)


def fetched(id_):
    d = os.path.join(FETCH, id_)
    names = [n for n in os.listdir(d) if not n.endswith(".sha256") and n != "SOURCE-URL"]
    if len(names) != 1:
        sys.exit(f"{d}: expected one file, found {names}")
    return os.path.join(d, names[0])


def members(tarpath):
    """{path below the archive's top folder: bytes} of its licence-like files and HEADER_FILES. The archive is
    read once, as a stream, so a large compressed archive is decompressed only once."""
    files = _tars.get(tarpath)
    if files is None:
        files, links = {}, {}
        with tarfile.open(tarpath, "r|*") as t:
            for info in t:
                parts = info.name.split("/", 1)
                if len(parts) < 2:
                    continue
                rel = parts[1].rstrip("/")
                if info.isfile() and info.size < 2_000_000 and (LICENCE_NAME.search(os.path.basename(rel))
                                                                 or rel in HEADER_FILES):
                    files[rel] = t.extractfile(info).read()
                elif info.issym():
                    links[rel] = os.path.normpath(os.path.join(os.path.dirname(rel), info.linkname))
        for rel, target in links.items():
            if target in files:
                files[rel] = files[target]
        _tars[tarpath] = files
    return files


def put(dest, data, origin):
    path = os.path.join(OUT, dest)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    index.append((dest, hashlib.sha256(data).hexdigest(), origin))


def from_tar(dest, id_or_path, name, required=True):
    tarpath = id_or_path if os.path.isabs(id_or_path) else fetched(id_or_path)
    data = members(tarpath).get(name)
    if data is None:
        if required:
            sys.exit(f"missing {name} in {tarpath}")
        return False
    put(dest, data, f"{os.path.basename(tarpath)}:{name}")
    return True


def from_file(dest, path, origin):
    with open(path, "rb") as f:
        put(dest, f.read(), origin)


def leading_comment(data):
    """The first comment block of a C, C++ or assembly file (its licence header)."""
    text = data.decode("utf-8", "replace")
    if text.lstrip().startswith("/*"):
        start = text.index("/*")
        return text[start:text.index("*/", start) + 2].encode() + b"\n"
    if text.lstrip().startswith("//"):   # C++ line comments: up to the first line that is not one
        lines = []
        for line in text.lstrip().splitlines():
            if not line.startswith("//"):
                break
            lines.append(line)
        return ("\n".join(lines) + "\n").encode()
    lines = []
    for line in text.splitlines():
        if line.startswith("#") and not line.startswith("# 0 ") and not line.startswith("# 1 "):
            lines.append(line)
        elif lines:
            break
    return ("\n".join(lines) + "\n").encode()


def header_from_tar(dest, id_or_path, name, required=True):
    tarpath = id_or_path if os.path.isabs(id_or_path) else fetched(id_or_path)
    data = members(tarpath).get(name)
    if data is None:
        if required:
            sys.exit(f"missing {name} in {tarpath}")
        return
    put(dest, leading_comment(data), f"{os.path.basename(tarpath)}:{name} (licence header)")


def wine(eng):
    """Wine 6880117619af (both engines): its licence, authors and notices, and the licence files of every
    third-party library it builds in (libs/<lib>/)."""
    w = "wine-6880117"
    for n in ("LICENSE", "COPYING.LIB", "AUTHORS", "NOTICES.md"):
        from_tar(f"{eng}/wine/{n}", w, n)
    pat = re.compile(r"^libs/([^/]+)/((licen[cs]e|copying|copyright|authors|notice)[^/]*)$", re.I)
    found = sorted(k for k in members(fetched(w)) if pat.match(k))
    for k in found:
        lib, n = pat.match(k).group(1, 2)
        from_tar(f"{eng}/wine/libs-{lib}-{n}", w, k)
    return found


def hadron(eng, comps):
    from_file(f"{eng}/hadron/LICENSE", os.path.join(HADRON, "LICENSE"), "Hadron d523fe6b LICENSE")
    from_file(f"{eng}/hadron/LICENSE.hadron", os.path.join(HADRON, "LICENSE.hadron"), "Hadron d523fe6b LICENSE.hadron")
    from_file(f"{eng}/hadron/patches-wine-LICENSE", os.path.join(HADRON, "patches/wine/LICENSE"),
              "Hadron d523fe6b patches/wine/LICENSE")
    from_file(f"{eng}/hadron/patches-wine-COPYING.LIB", os.path.join(HADRON, "patches/wine/COPYING.LIB"),
              "Hadron d523fe6b patches/wine/COPYING.LIB")
    if "fex" in comps:
        from_file(f"{eng}/hadron/patches-fex-LICENSE", os.path.join(HADRON, "patches/fex/LICENSE"),
                  "Hadron d523fe6b patches/fex/LICENSE")


def freetype(eng, id_):
    for n in ("LICENSE.TXT", "docs/FTL.TXT", "docs/GPLv2.TXT", "src/bdf/README", "src/pcf/README"):
        from_tar(f"{eng}/freetype/{n.replace('/', '-')}", id_, n)
    header_from_tar(f"{eng}/freetype/src-gzip-zlib.h-NOTICE", id_, "src/gzip/zlib.h")
    header_from_tar(f"{eng}/freetype/src-autofit-ft-hb-ft.c-NOTICE", id_, "src/autofit/ft-hb-ft.c", required=False)


def gnutls(eng, accelerated):
    g = "gnutls-3.8.13"
    for n in ("COPYING", "COPYING.LESSERv2", "README.md", "AUTHORS"):
        from_tar(f"{eng}/gnutls/{n}", g, n)
    from_tar(f"{eng}/gnutls/lib-inih-LICENSE.txt", g, "lib/inih/LICENSE.txt")
    from_tar(f"{eng}/gnutls/lib-crau-LICENSE", g, "lib/crau/LICENSE")
    from_tar(f"{eng}/gnutls/lib-crau-UNLICENSE", g, "lib/crau/UNLICENSE")
    from_tar(f"{eng}/gnutls/lib-accelerated-x86-license.txt", g, "lib/accelerated/x86/license.txt")
    if accelerated == "aarch64":
        header_from_tar(f"{eng}/gnutls/lib-accelerated-aarch64-CRYPTOGAMS-NOTICE", g,
                        "lib/accelerated/aarch64/macosx/ghash-aarch64.s")


def lgpl_libs(eng):
    for n in ("COPYING.LESSERv3", "COPYINGv3", "COPYINGv2"):
        from_tar(f"{eng}/nettle/{n}", "nettle-4.0", n)
        from_tar(f"{eng}/gmp/{n}", "gmp-6.3.0", n)
    from_tar(f"{eng}/libtasn1/COPYING.LESSERv2", "libtasn1-4.21.0", "COPYING.LESSERv2")


shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(OUT)

# ---------------------------------------------------------------- Apple silicon engine
A = "arm64"
wine_libs = wine(A)
hadron(A, ("wine", "fex"))
fex = os.path.join(OWN, f"fex-{C['FEX_COMMIT']}-src.tar.xz")
from_tar(f"{A}/fex/LICENSE", fex, "LICENSE")
header_from_tar(f"{A}/fex/SoftFloat-3e-NOTICE", fex, "External/SoftFloat-3e/src/extF80_add.c")
for sub, lic in (("External/cephes", "LICENSE"), ("External/fmt", "LICENSE"), ("External/xxhash", "LICENSE"),
                 ("External/tiny-json", "LICENSE"), ("External/unordered_dense", "LICENSE"),
                 ("External/rpmalloc", "LICENSE"), ("External/range-v3", "LICENSE.txt"),
                 ("Source/Common/cpp-optparse", "LICENSE")):
    from_tar(f"{A}/fex/{os.path.basename(sub)}-{lic}", fex, f"{sub}/{lic}")
# Third-party code in FEX's own tree (the engine's tools/fex-notices.tsv): functions taken from VIXL in the code
# emitter (the licence is that file's leading comment), and musl routines in FEX's Windows runtime, whose files
# carry only SPDX lines, so the text is musl's own COPYRIGHT file from the copy of musl in Wine's tree.
header_from_tar(f"{A}/fex/VIXL-NOTICE", fex, "CodeEmitter/CodeEmitter/VixlUtils.inl")
from_tar(f"{A}/fex/Musl-COPYRIGHT", "wine-6880117", "libs/musl/COPYRIGHT")
# llvm-mingw's runtime (libc++, libc++abi, libunwind, compiler-rt) is linked into the FEX DLLs; its licence as
# the engine itself ships it.
llvm = subprocess.run(["tar", "-xOf", C["ARM64_ARCHIVE"], f"{C['ARM64_ENGINE']}/licenses/llvm-mingw/LICENSE.TXT"],
                      capture_output=True)
if llvm.returncode or not llvm.stdout:
    sys.exit(f"no licenses/llvm-mingw/LICENSE.TXT in {C['ARM64_ARCHIVE']}")
put(f"{A}/llvm-mingw/LICENSE.TXT", llvm.stdout, f"{C['ARM64_ENGINE']}.tar.xz:licenses/llvm-mingw/LICENSE.TXT")
freetype(A, "freetype-2.14.3")
from_tar(f"{A}/libpng/LICENSE", "libpng-1.6.59", "LICENSE")
gnutls(A, "aarch64")
lgpl_libs(A)
for n in ("COPYING.LESSERv3", "COPYING", "COPYINGv2", "COPYING.unicode"):
    from_tar(f"{A}/libidn2/{n}", "libidn2-2.3.8", n)
for n in ("COPYING.LIB", "COPYING"):
    from_tar(f"{A}/libunistring/{n}", "libunistring-1.4.2", n)

# ---------------------------------------------------------------- Intel engine
X = "x86_64"
wine(X)
hadron(X, ("wine",))
freetype(X, "freetype-2.15.0")
gnutls(X, "x86")
# GnuTLS's own copies of libunistring and gnulib code (--with-included-unistring) are "LGPLv3+ or GPLv2+": the
# LGPL-3.0 text comes from Nettle's tarball, the GPL-3.0 text is GnuTLS's COPYING.
from_tar(f"{X}/gnutls/COPYING.LESSERv3-from-nettle-4.0", "nettle-4.0", "COPYING.LESSERv3")
lgpl_libs(X)

with open(os.path.join(OUT, "INDEX.tsv"), "w") as f:
    f.write("# path\tsha256\tfrom\n")
    for row in sorted(index):
        f.write("\t".join(row) + "\n")
print(f"licenses/: {len(index)} files; Wine's bundled-library licence files: "
      + ", ".join(sorted({re.match(r'libs/([^/]+)/', k).group(1) for k in wine_libs})))
