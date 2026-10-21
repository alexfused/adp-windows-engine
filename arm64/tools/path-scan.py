#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Find absolute paths into user-writable or package-manager folders inside an engine tree.

Every Mach-O and PE file under ROOT is read as bytes and searched, like `strings -a`, for
printable runs (ASCII, and UTF-16LE for the wide strings Windows code uses) that contain one of
PREFIXES. Each hit is checked against ALLOW (tools/path-scan.allow): a hit is "allowed" when
the file's path (relative to ROOT) matches the allowance's glob and the string matches its
regular expression; the allowance's reason says why the path is harmless.

  path-scan.py ROOT [--allow FILE] [--tsv OUT]
Prints a summary; exit 0 when there is no hit outside the allow list, 1 otherwise.
Writes every hit (file, kind, encoding, string, verdict) to OUT when --tsv is given.
"""
import fnmatch, os, re, sys

PREFIXES = ["/opt/homebrew", "/usr/local", "/opt/local", "/Users/", "/tmp", "/private/tmp",
            "/var/folders", "/private/var/folders"]
MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xfe\xed\xfa\xcf"}
PRINTABLE = rb"[\x20-\x7e\t]"
ASCII_RUN = re.compile(PRINTABLE + rb"{4,}")
WIDE_RUN = re.compile(rb"(?:" + PRINTABLE + rb"\x00){4,}")
NEEDLE = re.compile("|".join(re.escape(p) for p in PREFIXES))


def kind(path):
    try:
        with open(path, "rb") as f:
            head = f.read(64)
            if head[:4] in MACHO:
                return "macho"
            if head[:2] == b"MZ" and len(head) >= 64:
                off = int.from_bytes(head[60:64], "little")
                f.seek(off)
                if f.read(4) == b"PE\x00\x00":
                    return "pe"
    except OSError:
        pass
    return None


def hits(data):
    # Cheap pre-check on the raw bytes before collecting runs.
    wanted_a = [p.encode() for p in PREFIXES]
    wanted_w = [p.encode("utf-16-le") for p in PREFIXES]
    if any(w in data for w in wanted_a):
        for m in ASCII_RUN.finditer(data):
            s = m.group().decode("ascii")
            if NEEDLE.search(s):
                yield "ascii", s
    if any(w in data for w in wanted_w):
        for m in WIDE_RUN.finditer(data):
            s = m.group().decode("utf-16-le")
            if NEEDLE.search(s):
                yield "utf16", s


def load_allow(path):
    rules = []
    if not path:
        return rules
    for line in open(path):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        glob, regex, reason = line.split("\t", 2)
        rules.append((glob, re.compile(regex), reason))
    return rules


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        sys.exit(__doc__)
    root = os.path.abspath(args[0])
    allow = tsv = None
    i = 1
    while i < len(args):
        if args[i] == "--allow":
            allow = args[i + 1]; i += 2
        elif args[i] == "--tsv":
            tsv = args[i + 1]; i += 2
        else:
            sys.exit(f"unknown option {args[i]}")
    rules = load_allow(allow)
    scanned = {"macho": 0, "pe": 0}
    rows, used = [], set()
    for dirpath, dirnames, filenames in os.walk(root):
        for name in filenames:
            p = os.path.join(dirpath, name)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            k = kind(p)
            if not k:
                continue
            scanned[k] += 1
            rel = os.path.relpath(p, root)
            with open(p, "rb") as f:
                data = f.read()
            for enc, s in hits(data):
                verdict = "NOT ALLOWED"
                for n, (glob, regex, reason) in enumerate(rules):
                    if fnmatch.fnmatch(rel, glob) and regex.search(s):
                        verdict = "allowed: " + reason
                        used.add(n)
                        break
                rows.append((rel, k, enc, s, verdict))
    bad = [r for r in rows if r[4] == "NOT ALLOWED"]
    print(f"scanned {scanned['macho']} Mach-O and {scanned['pe']} PE files under {root}")
    print(f"prefixes: {' '.join(PREFIXES)}")
    print(f"hits: {len(rows)} in {len({r[0] for r in rows})} files; not allowed: {len(bad)} in {len({r[0] for r in bad})} files")
    by_prefix = {}
    for r in rows:
        for p in PREFIXES:
            if p in r[3]:
                by_prefix[p] = by_prefix.get(p, 0) + 1
    for p, n in sorted(by_prefix.items()):
        print(f"  {p}: {n}")
    # Distinct strings, so a reader sees what kinds of path remain.
    distinct = {}
    for r in rows:
        distinct.setdefault((r[3], r[4]), set()).add(r[0])
    for (s, v), files in sorted(distinct.items(), key=lambda kv: (kv[0][1] != "NOT ALLOWED", kv[0][0])):
        ex = sorted(files)[0]
        print(f"  [{v}] {s!r} in {len(files)} file(s), e.g. {ex}")
    for n, (glob, regex, reason) in enumerate(rules):
        if n not in used:
            print(f"  (allowance not needed by this tree: {glob} {regex.pattern})")
    if tsv:
        with open(tsv, "w") as f:
            f.write("file\tkind\tencoding\tstring\tverdict\n")
            for r in rows:
                f.write("\t".join(x.replace("\t", " ") for x in r) + "\n")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
