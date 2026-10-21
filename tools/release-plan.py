#!/usr/bin/env python3 -I
"""Decide, for each release file, what publish-release.sh must do with the assets GitHub already has.

  release-plan.py RELEASE_DIR ASSETS_JSON

RELEASE_DIR holds the files and SHA256SUMS (downloads/release). ASSETS_JSON is the output of
`gh api repos/O/R/releases/ID/assets --paginate --slurp` (a list of pages, or one list), or "-" for none.
Prints one line per file, tab-separated:
  skip     NAME                  already uploaded with the same SHA-256 (GitHub's digest)
  upload   NAME                  not there yet
  replace  NAME  ASSET_ID        there, but the upload never finished (state is not "uploaded"): delete it, upload again
  conflict NAME  REASON          there with other content, or with no digest and another size: stop, change nothing
and "extra NAME" for assets on GitHub that are not in SHA256SUMS (left alone). SHA256SUMS itself is planned
like any other file. Exit status 3 when any conflict is found, so the caller uploads nothing.
"""
import hashlib, json, os, sys


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def plan(release_dir, assets):
    files = {}
    for line in open(os.path.join(release_dir, "SHA256SUMS")):
        if line.strip():
            digest, name = line.rstrip("\n").split("  ", 1)
            files[name] = digest
    files["SHA256SUMS"] = sha256(os.path.join(release_dir, "SHA256SUMS"))
    by_name = {a["name"]: a for a in assets}
    out, conflicts = [], 0
    for name in sorted(files):
        want = files[name]
        size = os.path.getsize(os.path.join(release_dir, name))
        a = by_name.get(name)
        if a is None:
            out.append(("upload", name))
        elif a.get("state") != "uploaded":
            out.append(("replace", name, str(a["id"])))
        elif a.get("digest"):
            if a["digest"] == f"sha256:{want}":
                out.append(("skip", name))
            else:
                out.append(("conflict", name, f"GitHub has {a['digest']}, local file is sha256:{want}"))
                conflicts += 1
        elif a.get("size") == size:
            out.append(("skip", name))
        else:
            out.append(("conflict", name, f"GitHub has {a.get('size')} bytes and no digest, local file is {size} bytes"))
            conflicts += 1
    for name in sorted(set(by_name) - set(files)):
        out.append(("extra", name))
    return out, conflicts


def load_assets(arg):
    if arg == "-":
        return []
    data = json.load(open(arg))
    if data and isinstance(data[0], list):   # --slurp: a list of pages
        data = [a for page in data for a in page]
    return data


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    rows, conflicts = plan(sys.argv[1], load_assets(sys.argv[2]))
    for r in rows:
        print("\t".join(r))
    sys.exit(3 if conflicts else 0)
