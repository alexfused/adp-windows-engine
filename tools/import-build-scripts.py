#!/usr/bin/env python3 -I
# SPDX-License-Identifier: MIT
"""Copy the scripts that built each engine into this kit, from the ADP Monitor commit that built it.

  import-build-scripts.py           rewrite arm64/ and x86_64/
  import-build-scripts.py --check   build both in a scratch folder and compare with arm64/ and x86_64/
                                    (exit 1 if they differ; changes nothing)

For each engine (release.conf: <ENGINE>_SCRIPTS_COMMIT and _SCRIPTS_PATH):
  1. every file of that folder at that commit (git archive of the repository this kit sits in), except
     evidence/ (test logs and screenshots from the build Mac, not needed to build)
  2. the replacements in tools/scrubs.tsv (default paths that named folders on the build Mac)
  3. overlay/<engine>/ (files this kit adds: unpack-sources.sh, BUILD-FROM-RELEASE.md)
  4. hadron/: the Hadron files that build applied, from overlay/hadron/, checked against the build's
     patches.conf (and, for x86_64, against the SHA-256 list patches.sha256)
  5. IMPORTED.md, which lists all of the above
The result is what goes into adp-<engine>-build.tar.xz. Reads git; writes only arm64/ and x86_64/.
"""
import hashlib, io, os, re, shutil, subprocess, sys, tarfile, tempfile

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OVERLAY = os.path.join(KIT, "overlay")
HADRON = os.path.join(OVERLAY, "hadron")


def conf(*keys):
    script = f'source "{KIT}/release.conf"; ' + "; ".join(f'printf "%s\\0" "${k}"' for k in keys)
    out = subprocess.run(["bash", "-c", script], capture_output=True, check=True).stdout.decode()
    return dict(zip(keys, out.split("\0")))


C = conf("ARM64_ENGINE", "ARM64_SCRIPTS_COMMIT", "ARM64_SCRIPTS_PATH", "X86_64_ENGINE", "X86_64_SCRIPTS_COMMIT",
         "X86_64_SCRIPTS_PATH", "HADRON_COMMIT")
ENGINES = {
    "arm64": (C["ARM64_ENGINE"], C["ARM64_SCRIPTS_COMMIT"], C["ARM64_SCRIPTS_PATH"]),
    "x86_64": (C["X86_64_ENGINE"], C["X86_64_SCRIPTS_COMMIT"], C["X86_64_SCRIPTS_PATH"]),
}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git(*args):
    # From the top of the repository: git archive run in a subfolder keeps only that subfolder's paths.
    top = subprocess.run(["git", "-C", KIT, "rev-parse", "--show-toplevel"], capture_output=True, check=True,
                         text=True).stdout.strip()
    return subprocess.run(["git", "-C", top, *args], capture_output=True, check=True).stdout


def spike_files(commit, path):
    """{relative path: (bytes, mode)} of PATH at COMMIT, without evidence/."""
    data = git("archive", "--format=tar", f"{commit}:{path}")
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data)) as t:
        for m in t.getmembers():
            if not m.isfile():
                if m.issym():
                    sys.exit(f"{path}: symlink {m.name} (not expected in a build folder)")
                continue
            rel = os.path.normpath(m.name)
            if rel.startswith("evidence/") or rel.startswith(".."):
                continue
            files[rel] = (t.extractfile(m).read(), 0o755 if m.mode & 0o111 else 0o644)
    return files


def scrubs(engine):
    rows = []
    for line in open(os.path.join(KIT, "tools", "scrubs.tsv"), encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        eng, f, count, old, new, reason = line.split("\t")
        if eng == engine:
            rows.append((f, int(count), old, new, reason))
    return rows


def hadron_files(engine, files):
    """The Hadron files the build applied: {path under hadron/: bytes}."""
    out = {}
    for f in ("LICENSE", "LICENSE.hadron", "sources.conf"):
        out[f] = open(os.path.join(HADRON, f), "rb").read()
    conf_text = files["patches.conf"][0].decode()
    if engine == "arm64":   # "<component> <number> apply|skip <reason>"
        wanted = [(c, n) for c, n, what in re.findall(r"^(wine|fex) (\d{4}) (apply|skip)", conf_text, re.M)
                  if what == "apply"]
        comps = ("wine", "fex")
    else:                   # "<number> apply|skip <reason>", Wine only
        wanted = [("wine", n) for n, what in re.findall(r"^(\d{4}) (apply|skip)", conf_text, re.M) if what == "apply"]
        comps = ("wine",)
    for comp in comps:
        d = os.path.join(HADRON, "patches", comp)
        for extra in ("LICENSE", "COPYING.LIB"):
            if os.path.exists(os.path.join(d, extra)):
                out[f"patches/{comp}/{extra}"] = open(os.path.join(d, extra), "rb").read()
    for comp, n in wanted:
        d = os.path.join(HADRON, "patches", comp)
        match = [f for f in os.listdir(d) if f.startswith(n + "-") and f.endswith(".patch")]
        if len(match) != 1:
            sys.exit(f"{engine}: Hadron {comp} patch {n} is marked apply, overlay/hadron has {match}")
        out[f"patches/{comp}/{match[0]}"] = open(os.path.join(d, match[0]), "rb").read()
    if "patches.sha256" in files:   # x86_64 pins every Hadron file it uses
        for line in files["patches.sha256"][0].decode().splitlines():
            want, name = line.split("  ", 1)
            got = out.get(f"patches/wine/{name}")
            if got is None or sha256(got) != want:
                sys.exit(f"{engine}: overlay/hadron/patches/wine/{name} is not the file patches.sha256 pins")
        pinned = {f"patches/wine/{l.split('  ', 1)[1]}" for l in files["patches.sha256"][0].decode().splitlines()}
        extra = {p for p in out if p.startswith("patches/") and p not in pinned}
        if extra:
            sys.exit(f"{engine}: Hadron files not pinned by patches.sha256: {sorted(extra)}")
    return out, wanted


def build(engine, dest):
    name, commit, path = ENGINES[engine]
    files = spike_files(commit, path)
    notes = []
    for f, count, pattern, new, reason in scrubs(engine):
        data, mode = files[f]
        text, n = re.subn(pattern, lambda m: new, data.decode())
        if n != count:
            sys.exit(f"{engine}: tools/scrubs.tsv expects {count} match(es) of {pattern!r} in {f}, found {n}")
        files[f] = (text.encode(), mode)
        notes.append(f"- `{f}`: {reason}. New text: `` {new} ``")
    added = []
    od = os.path.join(OVERLAY, engine)
    for root, dirs, names in os.walk(od):
        for n in sorted(names):
            if n == ".DS_Store":
                continue
            p = os.path.join(root, n)
            rel = os.path.relpath(p, od)
            if rel in files:
                sys.exit(f"{engine}: overlay/{engine}/{rel} would replace a file of the build folder")
            files[rel] = (open(p, "rb").read(), 0o755 if os.stat(p).st_mode & 0o111 else 0o644)
            added.append(rel)
    hadron, wanted = hadron_files(engine, files)
    for rel, data in hadron.items():
        if f"hadron/{rel}" in files:
            sys.exit(f"{engine}: hadron/{rel} already exists in the build folder")
        files[f"hadron/{rel}"] = (data, 0o644)
    by_comp = {}
    for comp, n in wanted:
        by_comp.setdefault(comp, []).append(n)
    lines = [
        f"# How this folder was made",
        "",
        f"These are the scripts that built `{name}`, as ADP Monitor's repository holds them at commit `{commit}`",
        f"(folder `{path}`), with the changes below. `tools/import-build-scripts.py` in the release repository",
        "writes this folder; the same files are the release asset `adp-" + name + "-build.tar.xz`.",
        "",
        "Left out: `evidence/` (test logs and screenshots from the build Mac; not needed to build).",
        "",
        "## Changed",
        "",
        "Default paths that named folders on the build Mac now point relative to the script's own folder. Each can",
        "still be set from the environment, and none changes what the scripts build.",
        "",
    ] + (notes or ["- nothing"]) + [
        "",
        "## Added",
        "",
    ] + [f"- `{a}`: from this release repository's `overlay/{engine}/`." for a in added] + [
        f"- `hadron/`: from Hadron (https://github.com/Broyojo/hadron) at `{C['HADRON_COMMIT']}`: its licences, "
        "`sources.conf` (the upstream pins) and the patches this engine applied, byte for byte: "
        + "; ".join(f"{comp} {' '.join(ns)}" for comp, ns in by_comp.items()) + ". Hadron's Wine patches are "
        "LGPL-2.1-or-later (`hadron/patches/wine/LICENSE`, `COPYING.LIB`), its FEX patches MIT "
        "(`hadron/patches/fex/LICENSE`).",
        "",
    ]
    files["IMPORTED.md"] = ("\n".join(lines).encode(), 0o644)
    if os.path.exists(dest):
        shutil.rmtree(dest)
    for rel, (data, mode) in sorted(files.items()):
        p = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)
        os.chmod(p, mode)
    return len(files)


def tree(root):
    out = {}
    for dirpath, dirs, names in os.walk(root):
        for n in names:
            if n == ".DS_Store":
                continue
            p = os.path.join(dirpath, n)
            out[os.path.relpath(p, root)] = (sha256(open(p, "rb").read()), bool(os.stat(p).st_mode & 0o111))
    return out


def main():
    check = "--check" in sys.argv[1:]
    bad = 0
    with tempfile.TemporaryDirectory(dir=os.path.join(KIT, "downloads") if os.path.isdir(os.path.join(KIT, "downloads")) else None) as tmp:
        for engine in ENGINES:
            dest = os.path.join(tmp if check else KIT, engine)
            n = build(engine, dest)
            if check:
                a, b = tree(dest), tree(os.path.join(KIT, engine))
                diff = sorted(set(a) ^ set(b)) + sorted(p for p in set(a) & set(b) if a[p] != b[p])
                for p in diff[:20]:
                    print(f"  {engine}/{p} differs from a fresh import")
                bad += len(diff)
                print(f"{engine}/: {n} files, {'matches' if not diff else 'DIFFERS FROM'} a fresh import of "
                      f"{ENGINES[engine][1][:12]}")
            else:
                print(f"{engine}/: {n} files from {ENGINES[engine][2]} at {ENGINES[engine][1][:12]}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
