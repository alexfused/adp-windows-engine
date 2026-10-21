# SPDX-License-Identifier: MIT
"""How much of a prefix is byte-identical to files in the engine? Those could be APFS clones of
the engine's files (cp -c) instead of copies, so a golden prefix costs little real disk.
Read-only: prints a report, changes nothing.
Usage: python3 -I tools/prefix-dedup.py <engine root> <prefix>"""
import hashlib
import os
import sys

engine, prefix = sys.argv[1], sys.argv[2]


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


by_size = {}
for root, _, files in os.walk(engine):
    for name in files:
        p = os.path.join(root, name)
        if os.path.isfile(p) and not os.path.islink(p):
            by_size.setdefault(os.path.getsize(p), []).append(p)
known = {}
total = same = nfiles = nsame = 0
for root, _, files in os.walk(prefix):
    for name in files:
        p = os.path.join(root, name)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        size = os.path.getsize(p)
        total += size
        nfiles += 1
        candidates = by_size.get(size)
        if not candidates or size == 0:
            continue
        d = digest(p)
        for c in candidates:
            if c not in known:
                known[c] = digest(c)
            if known[c] == d:
                same += size
                nsame += 1
                break
mb = 1024 * 1024
print(f"prefix files: {nfiles}, {total / mb:.0f} MB; identical to an engine file: {nsame} files, {same / mb:.0f} MB "
      f"({100 * same / max(total, 1):.0f}%); the rest: {(total - same) / mb:.0f} MB")
