#!/usr/bin/env python3 -I
# SPDX-License-Identifier: MIT
"""Check that two folders hold the same files: names, content (SHA-256), executable bit and symlink targets.

  dircmp.py A B [--ignore PATH ...]

--ignore skips a path (relative to each folder) and everything under it, in both folders: for example .git,
or a FEX submodule the release leaves out. Folders themselves are not compared, only what they hold.
Prints up to 20 differences of each kind and a summary line; exit 0 when the folders match.
Reads files only; runs nothing.
"""
import hashlib, os, sys


def walk(root, ignore):
    out = {}
    for dirpath, dirs, names in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        for d in list(dirs):
            rel = os.path.normpath(os.path.join(rel_dir, d))
            if any(rel == i or rel.startswith(i + "/") for i in ignore):
                dirs.remove(d)
            elif os.path.islink(os.path.join(dirpath, d)):
                out[rel] = ("link", os.readlink(os.path.join(dirpath, d)))
                dirs.remove(d)
        for n in names:
            rel = os.path.normpath(os.path.join(rel_dir, n))
            if any(rel == i or rel.startswith(i + "/") for i in ignore):
                continue
            p = os.path.join(dirpath, n)
            if os.path.islink(p):
                out[rel] = ("link", os.readlink(p))
                continue
            h = hashlib.sha256()
            with open(p, "rb") as f:
                for block in iter(lambda: f.read(1 << 20), b""):
                    h.update(block)
            out[rel] = ("x" if os.stat(p).st_mode & 0o111 else "-", h.hexdigest())
    return out


def main(argv):
    ignore, paths, i = [], [], 0
    while i < len(argv):
        if argv[i] == "--ignore":
            ignore.append(argv[i + 1].rstrip("/")); i += 2
        else:
            paths.append(argv[i]); i += 1
    if len(paths) != 2:
        sys.exit(__doc__)
    a, b = (walk(p, ignore) for p in paths)
    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    differ = sorted(p for p in set(a) & set(b) if a[p] != b[p])
    for label, items in ((f"only in {paths[0]}", only_a), (f"only in {paths[1]}", only_b), ("different", differ)):
        for p in items[:20]:
            print(f"{label}: {p}")
        if len(items) > 20:
            print(f"{label}: ... and {len(items) - 20} more")
    ok = not (only_a or only_b or differ)
    print(f"{len(a)} entries in {paths[0]}, {len(b)} in {paths[1]}: {'SAME' if ok else 'DIFFERENT'}"
          + (f" (ignoring {', '.join(ignore)})" if ignore else ""))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
