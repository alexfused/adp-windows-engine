#!/usr/bin/env python3 -I
# SPDX-License-Identifier: MIT
"""Generate the licence notices, the engine manifests and the release notes from components.json.

  notices.py notices     THIRD-PARTY-LICENSES.md (repository: both engines, links to licenses/) and
                         downloads/own/<engine>.THIRD-PARTY-LICENSES.md (release assets: one engine,
                         every licence text in full)
  notices.py manifests   manifests/<engine>.manifest.json: each engine's own manifest (from its archive.sh) with
                         every "url" pointing at a file of this release (the upstream address kept as
                         "upstreamUrl"), plus the release, the licence file and the source files with their
                         SHA-256 and size. Needs downloads/release-sources/SHA256SUMS and the notices above.
  notices.py notes       RELEASE-NOTES.md for the GitHub release (needs downloads/release/SHA256SUMS)

Inputs are local files only. Output is the same for the same inputs (no dates or times are written).
"""
import copy, hashlib, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIC = os.path.join(ROOT, "licenses")
OWN = os.path.join(ROOT, "downloads", "own")
SRCDIR = os.path.join(ROOT, "downloads", "release-sources")


def conf():
    keys = ["REPO", "TAG", "BASE_URL", "RELEASE_TITLE", "ARM64_ENGINE", "ARM64_ARCHIVE", "ARM64_MANIFEST_IN",
            "X86_64_ENGINE", "X86_64_ARCHIVE", "X86_64_MANIFEST_IN", "WINE_COMMIT", "FEX_COMMIT", "HADRON_COMMIT"]
    script = f'source "{ROOT}/release.conf"; ' + "; ".join(f'printf "%s\\0" "${k}"' for k in keys)
    vals = subprocess.run(["bash", "-c", script], capture_output=True, check=True).stdout.decode().split("\0")
    return dict(zip(keys, vals))


C = conf()
DATA = json.load(open(os.path.join(ROOT, "components.json")))
ARCHIVES = {"arm64": (C["ARM64_ARCHIVE"], C["ARM64_MANIFEST_IN"]),
            "x86_64": (C["X86_64_ARCHIVE"], C["X86_64_MANIFEST_IN"])}
PAGE = f"https://github.com/{C['REPO']}/releases/tag/{C['TAG']}"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def read_sums(path):
    out = {}
    for line in open(path):
        if line.strip():
            digest, name = line.rstrip("\n").split("  ", 1)
            out[name] = digest
    return out


def text_of(rel):
    return open(os.path.join(LIC, rel), "rb").read().decode("utf-8", "replace")


def notices_sections(rel):
    """### sections of a Wine NOTICES.md file: {title: body}."""
    parts = re.split(r"^### (.+)$", text_of(rel), flags=re.M)
    return {parts[i].strip(): parts[i + 1] for i in range(1, len(parts), 2)}


LICENCE_TEXT = re.compile(r"GNU (LESSER |LIBRARY )?GENERAL PUBLIC LICENSE|Apache License|Mozilla Public License", re.I)
COPYRIGHT = [re.compile(r"copyright\s*(\(c\)|©)?\s*[0-9]{4}", re.I),
             re.compile(r"^copyright\s*(\(c\)|©)\s*\S", re.I),
             re.compile(r"^(\(c\)|©)\s*[0-9]{4}", re.I)]


def copyright_lines(comp, limit=4):
    """Copyright lines quoted from the component's own notices (not from the GNU or Apache texts).
    A "copyright" list in components.json replaces the search (for notices inside a licence text)."""
    if comp.get("copyright"):
        return comp["copyright"]
    if comp.get("sections"):
        notices = [t for t in comp["texts"] if t.endswith("NOTICES.md")][0]
        secs = notices_sections(notices)
        missing = [s for s in comp["sections"] if s not in secs]
        if missing:
            sys.exit(f"{comp['name']}: no NOTICES.md section {missing}")
        bodies = [secs[s] for s in comp["sections"]]
    else:
        bodies = [text_of(t) for t in comp["texts"] if not t.endswith("AUTHORS")]
        bodies = [b for b in bodies if not LICENCE_TEXT.search(b[:600])]
    lines = []
    for body in bodies:
        raw = body.splitlines()
        for i, line in enumerate(raw):
            s = line.strip().strip("#*/;").strip()
            if not any(p.search(s) if n == 0 else p.match(s) for n, p in enumerate(COPYRIGHT)):
                continue
            if s.count("(") > s.count(")") and i + 1 < len(raw):
                s += " " + raw[i + 1].strip().strip("#*/;").strip()
            if len(s) < 200 and s not in lines and "<copyright holders>" not in s:
                lines.append(s)
    if len(lines) > limit:
        lines = lines[:limit] + [f"and {len(lines) - limit} more in the licence texts"]
    return lines or ["see the licence text"]


def fence(text):
    longest = max((len(m) for m in re.findall(r"`{3,}|~{3,}", text)), default=0)
    mark = "~" * max(4, longest + 1)
    return f"{mark}text\n{text.rstrip()}\n{mark}\n"


def anchor(rel):
    return "t-" + re.sub(r"[^a-z0-9]+", "-", rel.lower()).strip("-")


def source_assets():
    sums = os.path.join(SRCDIR, "SHA256SUMS")
    return read_sums(sums) if os.path.exists(sums) else {}


def engine_doc(eng, embed):
    e = DATA["engines"][eng]
    comps = [c for c in DATA["components"] if c["engine"] == eng]
    srcs = source_assets()
    out = [f"# Third-party licences: {e['title']}\n", f"{e['summary']}\n",
           f"Release: {PAGE}\n",
           "## Modifications\n", f"{e['modified']}\n",
           "## Source code\n",
           f"{e['sources']} Download them from {C['BASE_URL']}/<file>. The *Source* column below names the files "
           "for each component; SHA256SUMS in the release lists their SHA-256.\n"]
    needed = sorted({s for c in comps for s in c.get("source", [])})
    if needed:
        out.append("| Source file | SHA-256 |\n|---|---|")
        for s in needed:
            out.append(f"| [{s}]({C['BASE_URL']}/{s}) | `{srcs.get(s, 'see SHA256SUMS')}` |")
        out.append("")
    credits = [c for c in comps if c.get("credit")]
    if credits:
        out.append("## Credits the licences require\n")
        for c in credits:
            out.append(f"- {c['credit']} ({c['name']})")
        out.append("")
    out.append("## Components\n")
    out.append("| Component | Version | Licence | Where | Copyright | Licence texts | Source |")
    out.append("|---|---|---|---|---|---|---|")
    for c in comps:
        cr = "<br>".join(copyright_lines(c))
        texts = []
        for t in c["texts"]:
            label = os.path.basename(t)
            if t.endswith("NOTICES.md") and c.get("sections"):
                label += " (" + ", ".join(c["sections"]) + ")"
            texts.append(f"[{label}](#{anchor(t)})" if embed else f"[{label}](licenses/{t})")
        src = ", ".join(c.get("source", [])) or "-"
        note = f" {c['note']}" if c.get("note") else ""
        cells = [c["name"] + ("<br>*" + note.strip() + "*" if note else ""), c["version"], c["licence"],
                 c["where"], cr, "<br>".join(texts) or "-", src]
        out.append("| " + " | ".join(x.replace("|", "\\|").replace("\n", " ") for x in cells) + " |")
    out.append("")
    if embed:
        out.append("## Licence texts\n")
        out.append("Each text appears once; *Applies to* lists the components it covers.\n")
        seen = {}
        for c in comps:
            for t in c["texts"]:
                seen.setdefault(t, []).append(c["name"])
        by_hash = {}
        for t in seen:
            by_hash.setdefault(sha256(os.path.join(LIC, t)), []).append(t)
        done = set()
        for t, users in seen.items():
            h = sha256(os.path.join(LIC, t))
            if h in done:
                continue
            done.add(h)
            same = by_hash[h]
            names = sorted({n for s in same for n in seen[s]})
            for s in same:
                out.append(f'<a id="{anchor(s)}"></a>')
            out.append(f"### {t}\n")
            if len(same) > 1:
                out.append("Identical texts: " + ", ".join(f"`{s}`" for s in same) + "\n")
            out.append("Applies to: " + "; ".join(names) + "\n")
            out.append(fence(text_of(t)))
    return "\n".join(out) + "\n"


def repo_doc():
    out = ["# Third-party licences\n",
           "This repository publishes two Windows engines for ADP Monitor. Each is made of third-party software; "
           "this file lists every component, its version and licence, and where its full licence texts and "
           "source are. The licence texts are in [licenses/](licenses/) (index: [licenses/INDEX.tsv]"
           "(licenses/INDEX.tsv)). Each release also carries one file per engine, "
           "`<engine>.THIRD-PARTY-LICENSES.md`, with every text for that engine reproduced in full; "
           "ADP Monitor shows that file with the engine.\n"]
    for eng in DATA["engines"]:
        doc = engine_doc(eng, embed=False)
        out.append(re.sub(r"^# Third-party licences: ", "## ", doc, count=1).replace("\n## ", "\n### "))
    return "\n".join(out)


def cmd_notices():
    os.makedirs(OWN, exist_ok=True)
    for t in {t for c in DATA["components"] for t in c["texts"]}:
        if not os.path.exists(os.path.join(LIC, t)):
            sys.exit(f"components.json names licenses/{t}, which collect-licences.py did not write")
    with open(os.path.join(ROOT, "THIRD-PARTY-LICENSES.md"), "w") as f:
        f.write(repo_doc())
    for eng, e in DATA["engines"].items():
        path = os.path.join(OWN, f"{e['name']}.THIRD-PARTY-LICENSES.md")
        with open(path, "w") as f:
            f.write(engine_doc(eng, embed=True))
        print(f"{os.path.relpath(path, ROOT)}: {os.path.getsize(path):,} bytes")
    print(f"THIRD-PARTY-LICENSES.md: {os.path.getsize(os.path.join(ROOT, 'THIRD-PARTY-LICENSES.md')):,} bytes")


def asset(name, path):
    return {"name": name, "url": f"{C['BASE_URL']}/{name}", "sha256": sha256(path), "bytes": os.path.getsize(path)}


def point_at_release(node, by_sha, path="sources"):
    """Every "url" under the engine's own "sources": the release's copy of that file (matched by SHA-256) when the
    release has it, else the field becomes "upstreamUrl" (git repositories, the llvm-mingw toolchain)."""
    if isinstance(node, list):
        for i, x in enumerate(node):
            point_at_release(x, by_sha, f"{path}[{i}]")
    elif isinstance(node, dict):
        for k in list(node):
            point_at_release(node[k], by_sha, f"{path}.{k}")
        if "url" in node:
            up = node.pop("url")
            name = by_sha.get(node.get("sha256", ""))
            if name:
                node["url"] = f"{C['BASE_URL']}/{name}"
                if node.get("file") not in (None, name):
                    node["releaseFile"] = name
            node["upstreamUrl"] = up


def cmd_manifests():
    sums = read_sums(os.path.join(SRCDIR, "SHA256SUMS"))
    by_sha = {v: k for k, v in sums.items()}
    os.makedirs(os.path.join(ROOT, "manifests"), exist_ok=True)
    release = {"repo": C["REPO"], "tag": C["TAG"], "page": PAGE, "sha256sums": f"{C['BASE_URL']}/SHA256SUMS"}
    for eng, e in DATA["engines"].items():
        archive, manifest_in = ARCHIVES[eng]
        m = copy.deepcopy(json.load(open(manifest_in)))
        if m["name"] != e["name"] or m["archive"]["sha256"] != sha256(archive) or m["archive"]["bytes"] != os.path.getsize(archive):
            sys.exit(f"{manifest_in} does not describe {archive}")
        url = f"{C['BASE_URL']}/{os.path.basename(archive)}"
        m["archive"]["url"] = url
        point_at_release(m.get("sources", {}), by_sha)
        if "app" in m:   # ADP Monitor's WindowsEngineManifest for this engine
            m["app"]["urls"] = [url]
            if m["app"]["sha256"] != m["archive"]["sha256"] or m["app"]["bytes"] != m["archive"]["bytes"]:
                sys.exit(f"{manifest_in}: app manifest and archive disagree")
            old = re.search(r"Source: \S+ \(commit [0-9a-f]+\)$", m["app"]["licence"])
            if not old:
                sys.exit(f"{manifest_in}: app licence text does not end with its source as expected")
            m["app"]["licence"] = m["app"]["licence"][:old.start()] + f"Source of every part: {PAGE}"
        m["release"] = release
        m["notices"] = asset(f"{e['name']}.THIRD-PARTY-LICENSES.md", os.path.join(OWN, f"{e['name']}.THIRD-PARTY-LICENSES.md"))
        names = sorted({s for c in DATA["components"] if c["engine"] == eng for s in c.get("source", [])})
        missing = [n for n in names if n not in sums]
        if missing:
            sys.exit(f"{eng}: source files not in release-sources: {missing}")
        m["sourceFiles"] = [asset(n, os.path.join(SRCDIR, n)) for n in names]
        path = os.path.join(ROOT, "manifests", f"{e['name']}.manifest.json")
        with open(path, "w") as f:
            json.dump(m, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print(f"manifests/{e['name']}.manifest.json: archive {url}")


def cmd_notes():
    sums = read_sums(os.path.join(ROOT, "downloads", "release", "SHA256SUMS"))
    rows = []
    for eng, e in DATA["engines"].items():
        tar = os.path.basename(ARCHIVES[eng][0])
        rows.append(f"| `{e['name']}` | {e['for']} | `{tar}` | `{sums.get(tar, '?')}` |")
    lines = [
        "Two Windows engines for ADP Monitor, both built from source by ADP Monitor's scripts. Each engine has a "
        "manifest (`*.manifest.json`: download URL, SHA-256, size, layout, health check, signing, and every source "
        "file) and a licence file (`*.THIRD-PARTY-LICENSES.md`). The other files are the corresponding source.",
        "",
        "| Engine | For | Archive | SHA-256 |",
        "|---|---|---|---|",
    ] + rows + [
        "",
        f"Both are Wine 11.18 (a development snapshot, upstream commit {C['WINE_COMMIT'][:12]}) with some of "
        f"Hadron's Wine patches ({C['HADRON_COMMIT'][:12]}), and GnuTLS, Nettle, GMP, libtasn1 and FreeType "
        "built from their release tarballs into `lib/ext`.",
        "",
        f"**`{DATA['engines']['arm64']['name']}`** adds FEX {C['FEX_COMMIT'][:12]} with Hadron's 5 FEX patches, "
        "so x86 and x86-64 Windows programs run on Apple silicon without Rosetta. Signed with Alex Parkin's "
        "Developer ID under the engine's own identifier `com.alexparkin.adpmonitor.winehost` and notarised by Apple.",
        "",
        f"**`{DATA['engines']['x86_64']['name']}`** runs x86 and x86-64 Windows programs natively on Intel Macs "
        "(macOS 12.3 or later). It was cross-compiled on Apple silicon. Its first test run on an Intel Mac passed 9 of "
        "10 required checks; the tenth failed because of a bug in the test script, since fixed, and a full rerun is "
        "still to come. It is signed under the same identifier and not yet notarised.",
        "",
        "Check a download: `shasum -a 256 -c SHA256SUMS --ignore-missing`.",
        "",
        "Licences: Wine is LGPL-2.1-or-later; the other components and their licences are listed in "
        "THIRD-PARTY-LICENSES.md and in each engine's licence file. This repository's own scripts are MIT.",
    ]
    with open(os.path.join(ROOT, "RELEASE-NOTES.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("RELEASE-NOTES.md written")


if __name__ == "__main__":
    {"notices": cmd_notices, "manifests": cmd_manifests, "notes": cmd_notes}.get(
        sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
