#!/usr/bin/env python3 -I
"""Write a reproducible .tar.xz: sorted members, owner 0:0, no extended attributes, fixed or given times.

  dettar.py OUT.tar.xz --dir SRC PREFIX [--mtime EPOCH]
      every file, folder and symlink under SRC, stored as PREFIX/<path>. Times are set to --mtime
      (default 0) so the archive depends only on content, names and modes.
  dettar.py OUT.tar.xz --tar IN.tar PREFIX [--tar IN2.tar PREFIX2 ...]
      members of existing tar files (for example `git archive` output) under a new prefix, keeping
      their times and modes. Later inputs may add files inside folders of earlier ones.

The same inputs always give the same bytes (xz preset 9, single thread), so a rerun does not change
the hash a release has already published.
"""
import io, lzma, os, sys, tarfile


def norm(info, name):
    info.name = name
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.pax_headers = {}
    if info.isdir():
        info.mode = 0o755
    elif info.isfile():
        info.mode = 0o755 if info.mode & 0o111 else 0o644
    return info


def from_dir(src, prefix, mtime):
    members = []
    for root, dirs, files in os.walk(src):
        dirs.sort()
        rel_root = os.path.relpath(root, src)
        for name in sorted(dirs + files):
            path = os.path.join(root, name)
            rel = os.path.normpath(os.path.join(rel_root, name))
            if name in (".DS_Store",) or name.startswith("._"):
                continue
            info = tarfile.TarInfo()
            st = os.lstat(path)
            if os.path.islink(path):
                info.type = tarfile.SYMTYPE
                info.linkname = os.readlink(path)
                data = None
            elif os.path.isdir(path):
                info.type = tarfile.DIRTYPE
                data = None
            else:
                info.type = tarfile.REGTYPE
                info.size = st.st_size
                info.mode = st.st_mode & 0o777
                data = path
            info.mtime = mtime
            members.append((prefix + "/" + rel, info, data))
    members.sort(key=lambda m: m[0])
    return members


def from_tar(path, prefix):
    members = []
    with tarfile.open(path) as t:
        for info in t.getmembers():
            if info.type == tarfile.XGLTYPE or info.name == "pax_global_header":
                continue
            name = info.name.rstrip("/")
            data = t.extractfile(info).read() if info.isfile() else None
            members.append((prefix + ("/" + name if name not in ("", ".") else ""), info, data))
    return members


def main(argv):
    out = argv[0]
    args = argv[1:]
    mtime = 0
    if "--mtime" in args:
        i = args.index("--mtime")
        mtime = int(args[i + 1])
        del args[i:i + 2]
    entries = {}
    while args:
        kind, src, prefix = args[0], args[1], args[2].rstrip("/")
        args = args[3:]
        got = from_dir(src, prefix, mtime) if kind == "--dir" else from_tar(src, prefix)
        for name, info, data in got:
            entries[name] = (info, data)
    tmp = out + ".partial"
    with lzma.open(tmp, "wb", preset=9) as xz:
        with tarfile.open(fileobj=xz, mode="w", format=tarfile.GNU_FORMAT) as t:
            for name in sorted(entries):
                info, data = entries[name]
                info = norm(info, name)
                if info.isfile():
                    if isinstance(data, str):
                        with open(data, "rb") as f:
                            data = f.read()
                    info.size = len(data)
                    t.addfile(info, io.BytesIO(data))
                else:
                    t.addfile(info)
    os.replace(tmp, out)
    print(f"{out}: {len(entries)} entries")


if __name__ == "__main__":
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    main(sys.argv[1:])
