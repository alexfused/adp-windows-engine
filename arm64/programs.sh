#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copy the Tier 1 spike's test programs into downloads/programs/<name>/ (one folder each) and
# check each against the SHA-256 pinned in spikes/windows-apps/SOURCES.md. Nothing is downloaded.
# Also builds two tiny console test programs (x86_64 and i386) with llvm-mingw, for headless
# checks of FEX's two paths, and tools/tls-check.c (Wine's crypto on the engine's GnuTLS). Idempotent.
# Usage: programs.sh [source downloads folder]

source "$(dirname "$0")/env.sh"
from="${1:-$SPIKE/../windows-apps/downloads}"
P="$DOWNLOADS/programs"

check() {  # name file sha256
    local dir="$P/$1" f="$2" want="$3" got
    mkdir -p "$dir"
    [[ -f "$dir/$f" ]] || cp -p "$from/$1/$f" "$dir/$f"
    got=$(shasum -a 256 "$dir/$f" | cut -d' ' -f1)
    [[ "$got" == "$want" ]] || die "$1/$f: SHA-256 $got, expected $want"
    echo "ok  $1/$f"
}
check putty64  putty.exe                       d01fdb5aae8f112526040a39b0bfb9e27d813003178645e65f8d1cfdb2a26c87
check putty32  putty.exe                       4c70267ca03a00ea761ec358498b990a7221decb36eace9b7dbe6a751be0fb3b
check sevenzip 7z2604-x64.exe                  d54bf805f9f3704d1e8db2fa3498ae7ef2df0312b40b558e7c71c734430a665d
check npp      npp.8.9.8.1.portable.x64.zip    beddf5548e75c97930d1575ba1c7d113e6e2b33d0a200310e734ca08e225f414

# Notepad++ is a portable zip: unpack once beside it.
[[ -f "$P/npp/unpacked/notepad++.exe" ]] || { mkdir -p "$P/npp/unpacked"; ditto -x -k "$P/npp/npp.8.9.8.1.portable.x64.zip" "$P/npp/unpacked"; }
[[ -f "$P/npp/unpacked/notepad++.exe" ]] || die "notepad++.exe not in the zip"

# Our own console programs: print the architecture Windows reports, then exit 0.
mkdir -p "$P/hello"
cat > "$P/hello/hello.c" <<'EOF'
#include <windows.h>
#include <stdio.h>
int main(void) {
    SYSTEM_INFO si; GetNativeSystemInfo(&si);
    BOOL wow = FALSE; IsWow64Process(GetCurrentProcess(), &wow);
    printf("hello from %s code, native arch %u, wow64=%d\n", sizeof(void *) == 8 ? "x86_64" : "i386",
           si.wProcessorArchitecture, wow);
    return 0;
}
EOF
for t in x86_64 i686; do
    out="$P/hello/hello-$t.exe"
    [[ -f "$out" ]] || "$MINGW/$t-w64-mingw32-clang" -O2 "$P/hello/hello.c" -o "$out"
    echo "ok  hello/$(basename "$out") ($(file -b "$out" | cut -d, -f1-2))"
done
# The crypto check (tools/tls-check.c): bcrypt and schannel on the engine's GnuTLS, x86_64 through FEX.
out="$P/hello/tls-check-x86_64.exe"
if [[ ! -f "$out" || "$SPIKE/tools/tls-check.c" -nt "$out" ]]; then
    "$MINGW/x86_64-w64-mingw32-clang" -O2 "$SPIKE/tools/tls-check.c" -lbcrypt -lsecur32 -o "$out"
fi
echo "ok  hello/$(basename "$out") ($(file -b "$out" | cut -d, -f1-2))"
