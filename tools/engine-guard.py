#!/usr/bin/env python3 -I
# SPDX-License-Identifier: MIT
"""Refuse an engine that would run as ADP Monitor, or that names build or personal paths.

  engine-guard.py archives REPORT_DIR ARCHIVE...   check engine archives (.tar.xz), one report each
  engine-guard.py personal PATH...                 look for personal paths in files, folders and tarballs

archives: each archive is unpacked into a new scratch folder (downloads/work/guard/, removed afterwards) and
  1. identity: `codesign -dv` reads the signature of every Mach-O file and every .app bundle. Refused: an
     identifier equal to ADP_MONITOR_BUNDLE_ID (release.conf), an unsigned file, a signature that fails
     `codesign --verify --strict`, a signature without the hardened runtime.
  2. root helper: `codesign --verify -R=<HELPER_REQUIREMENT>` on each of them must FAIL. The requirement is
     ADP Monitor's root-helper caller requirement; when ADP Monitor's source is there (ADP_MONITOR_SOURCE) it is
     read again from Sources/ADPHelper/main.swift and Sources/SMCKit/HelperProtocol.swift and must equal
     release.conf's. HELPER_CONTROL (ADP Monitor.app) must PASS it, or the check proves nothing.
  3. build paths: every Mach-O and PE file is read like `strings -a` (ASCII and UTF-16LE runs) for
     /opt/homebrew, /usr/local, /opt/local, /Users/, /tmp, /private/tmp, /var/folders, /private/var/folders.
     A hit passes only if tools/path-scan.allow names that engine, file and string, with a reason.
  4. personal paths: every file, as in `personal` below.
personal: the home folder and user name of whoever runs this, Claude Code work folders and agent ids, macOS
  per-user temporary folders, and "<user name>@". Tarballs are read member by member. No allowances.

Exit 1 if anything is refused. Writes REPORT_DIR/<engine>.guard.txt and .path-hits.tsv. Runs only codesign,
tar and this file's own code; nothing from an archive is executed.
"""
import fnmatch, getpass, os, re, shutil, subprocess, sys, tarfile, tempfile

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREFIXES = ["/opt/homebrew", "/usr/local", "/opt/local", "/Users/", "/tmp", "/private/tmp",
            "/var/folders", "/private/var/folders"]
PRINTABLE = rb"[\x20-\x7e\t]"
ASCII_RUN = re.compile(PRINTABLE + rb"{4,}")
WIDE_RUN = re.compile(rb"(?:" + PRINTABLE + rb"\x00){4,}")
NEEDLE = re.compile("|".join(re.escape(p) for p in PREFIXES))
MACHO_THIN = {b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe"}
MACHO_FAT = {b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}


def conf(*keys):
    script = f'source "{KIT}/release.conf"; ' + "; ".join(f'printf "%s\\0" "${k}"' for k in keys)
    out = subprocess.run(["bash", "-c", script], capture_output=True, check=True).stdout.decode()
    return dict(zip(keys, out.split("\0")))


# ------------------------------------------------------------------ personal paths
class Personal:
    """Markers of the machine and person that built the release. Computed when it runs: this file names none."""

    def __init__(self):
        home = os.path.realpath(os.path.expanduser("~"))
        user = getpass.getuser()
        pats = [re.escape(home), "/" + re.escape(user) + "/", re.escape(user) + "@",
                r"\.claude/(?:worktrees)", r"wf_[0-9a-f]{8}-[0-9a-f]{3}-[0-9]", r"agent-a[0-9a-f]{16}",
                r"/var/folders/[A-Za-z0-9_+-]{2}/", r"/tmp/claude-[0-9]+"]
        self.rx = re.compile("|".join(pats).encode())
        literals = [home, "/" + user + "/", user + "@", ".claude/", "wf_", "agent-a", "/var/folders/", "/tmp/claude-"]
        self.wide = [l.encode("utf-16-le") for l in literals]

    def hits(self, data):
        found = set()
        for m in self.rx.finditer(data):
            s = data[max(0, m.start() - 30):m.end() + 30].decode("latin-1")
            found.add(re.sub(r"[^\x20-\x7e]", ".", s))
        if any(w in data for w in self.wide):   # wide strings in Windows code
            for m in WIDE_RUN.finditer(data):
                s = m.group().decode("utf-16-le")
                if self.rx.search(s.encode("ascii", "replace")):
                    found.add(s[:160])
        return sorted(found)


_PERSONAL = None


def personal_hits(data):
    global _PERSONAL
    if _PERSONAL is None:
        _PERSONAL = Personal()
    return _PERSONAL.hits(data)


def scan_personal(path, label=None):
    """[(where, excerpt)] for a file, a folder (recursively) or a tarball (member by member)."""
    label = label or path
    out = []
    if os.path.isdir(path):
        for dirpath, dirs, names in os.walk(path):
            dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
            for n in names:
                p = os.path.join(dirpath, n)
                if not os.path.islink(p):
                    out += scan_personal(p, os.path.join(label, os.path.relpath(p, path)))
        return out
    if re.search(r"\.tar(\.(xz|gz|bz2))?$|\.tgz$", path):
        try:
            with tarfile.open(path, "r|*") as t:
                for m in t:
                    for s in personal_hits(m.name.encode()):
                        out.append((f"{label}:{m.name} (name)", s))
                    if m.issym() or m.islnk():
                        for s in personal_hits(m.linkname.encode()):
                            out.append((f"{label}:{m.name} (link)", s))
                    if m.isfile():
                        for s in personal_hits(t.extractfile(m).read()):
                            out.append((f"{label}:{m.name}", s))
            return out
        except tarfile.TarError as e:
            return [(label, f"cannot read as a tarball: {e}")]
    with open(path, "rb") as f:
        data = f.read()
    return [(label, s) for s in personal_hits(data)]


def cmd_personal(paths):
    hits = []
    for p in paths:
        hits += scan_personal(p)
    for where, s in hits:
        print(f"PERSONAL  {where}: {s!r}")
    print(f"personal paths: {len(hits)} hit(s) in {len(paths)} path(s) checked")
    return 1 if hits else 0


# ------------------------------------------------------------------ engines
def kind(path):
    try:
        with open(path, "rb") as f:
            head = f.read(64)
            if head[:4] in MACHO_THIN:
                return "macho"
            if head[:4] in MACHO_FAT and int.from_bytes(head[4:8], "big") < 20:
                return "macho"
            if head[:2] == b"MZ" and len(head) >= 64:
                f.seek(int.from_bytes(head[60:64], "little"))
                if f.read(4) == b"PE\x00\x00":
                    return "pe"
    except OSError:
        pass
    return None


def path_hits(data):
    if any(p.encode() in data for p in PREFIXES):
        for m in ASCII_RUN.finditer(data):
            s = m.group().decode("ascii")
            if NEEDLE.search(s):
                yield "ascii", s
    if any(p.encode("utf-16-le") in data for p in PREFIXES):
        for m in WIDE_RUN.finditer(data):
            s = m.group().decode("utf-16-le")
            if NEEDLE.search(s):
                yield "utf16", s


def load_allow():
    rules = []
    for line in open(os.path.join(KIT, "tools", "path-scan.allow"), encoding="utf-8"):
        line = line.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        engine, glob, regex, reason = line.split("\t", 3)
        rules.append((engine, glob, re.compile(regex), reason))
    return rules


def requirement_from_source(src):
    main = os.path.join(src, "Sources", "ADPHelper", "main.swift")
    proto = os.path.join(src, "Sources", "SMCKit", "HelperProtocol.swift")
    if not (os.path.isfile(main) and os.path.isfile(proto)):
        return None
    m = re.search(r'static let callerRequirement = #"(identifier "[^"]*") and "# \+ HelperProtocol\.trustedSignerClause',
                  open(main, encoding="utf-8").read())
    c = re.search(r'static let trustedSignerClause =\s*\n\s*#"(.*)"#\s*$', open(proto, encoding="utf-8").read(), re.M)
    if not (m and c):
        sys.exit("could not read the caller requirement from ADP Monitor's helper source")
    return f"{m.group(1)} and {c.group(1)}"


def codesign_info(path):
    r = subprocess.run(["codesign", "-dv", "--verbose=2", path], capture_output=True, text=True)
    info = {"signed": r.returncode == 0}
    for line in r.stderr.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            info.setdefault(k.strip(), v.strip())
    flags = re.search(r"flags=(0x[0-9a-f]+)\(([^)]*)\)", r.stderr)
    info["flags"] = flags.group(2) if flags else ""
    return info


def satisfies(path, req):
    r = subprocess.run(["codesign", "--verify", "-R=" + req, path], capture_output=True, text=True)
    return r.returncode, (r.stderr.strip().splitlines() or [""])[-1]


def safe_extract(archive, dest):
    """bsdtar into DEST after checking every member stays inside one top folder."""
    tops = set()
    with tarfile.open(archive, "r|*") as t:
        for m in t:
            parts = m.name.split("/")
            if m.name.startswith("/") or ".." in parts or not (m.isfile() or m.isdir() or m.issym()):
                sys.exit(f"{archive}: unsafe member {m.name!r}")
            if m.issym():
                target = os.path.normpath(os.path.join(os.path.dirname(m.name), m.linkname))
                if m.linkname.startswith("/") or target.startswith(".."):
                    sys.exit(f"{archive}: symlink {m.name} points outside the archive ({m.linkname})")
            tops.add(parts[0])
    if len(tops) != 1:
        sys.exit(f"{archive}: expected one top folder, found {sorted(tops)}")
    subprocess.run(["tar", "-xf", archive, "-C", dest], check=True)
    return os.path.join(dest, tops.pop())


def check_archive(archive, req, forbidden, rules, report_dir):
    name = re.sub(r"\.tar\.(xz|gz)$", "", os.path.basename(archive))
    work = os.path.join(KIT, "downloads", "work", "guard")
    os.makedirs(work, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=name + ".", dir=work)
    lines, refusals, hits_rows, used = [], 0, [], set()
    try:
        root = safe_extract(archive, tmp)
        machos, apps, pes, others = [], [], [], []
        for dirpath, dirs, names in os.walk(root):
            for d in dirs:
                if d.endswith(".app"):
                    apps.append(os.path.join(dirpath, d))
            for n in names:
                p = os.path.join(dirpath, n)
                if os.path.islink(p):
                    continue
                k = kind(p)
                (machos if k == "macho" else pes if k == "pe" else others).append(p)
        lines.append(f"# Engine guard: {name}")
        lines.append(f"archive: {os.path.basename(archive)}")
        lines.append(f"files: {len(machos)} Mach-O, {len(apps)} .app, {len(pes)} PE, {len(others)} other")
        lines.append("")
        lines.append("## 1-2. Signatures and ADP Monitor's root helper (codesign -dv; codesign --verify -R)")
        lines.append(f"requirement: {req}")
        lines.append(f"forbidden identifier: {forbidden}")
        for p in sorted(apps) + sorted(machos):
            rel = os.path.relpath(p, root)
            info = codesign_info(p)
            ident, team = info.get("Identifier", "-"), info.get("TeamIdentifier", "-")
            strict = subprocess.run(["codesign", "--verify", "--strict", p], capture_output=True).returncode
            rc, msg = satisfies(p, req)
            problems = []
            if not info["signed"]:
                problems.append("not signed")
            if ident == forbidden:
                problems.append(f"identifier is {forbidden}")
            if strict != 0:
                problems.append("codesign --verify --strict fails")
            if info["signed"] and "runtime" not in info["flags"].split(","):
                problems.append("no hardened runtime")
            if rc == 0:
                problems.append("the root helper's requirement ACCEPTS it")
            verdict = "REFUSED: " + "; ".join(problems) if problems else "ok"
            refusals += bool(problems)
            lines.append(f"{verdict:8} {rel}: identifier {ident}, team {team}, flags {info['flags'] or '-'}, "
                         f"helper requirement rc={rc} ({'accepted' if rc == 0 else 'refused'})")
        lines.append("")
        lines.append("## 3. Build paths in Mach-O and PE files (" + " ".join(PREFIXES) + ")")
        for p in sorted(machos + pes):
            rel = os.path.relpath(p, root)
            with open(p, "rb") as f:
                data = f.read()
            for enc, s in path_hits(data):
                verdict = "NOT ALLOWED"
                for i, (eng, glob, rx, reason) in enumerate(rules):
                    if eng == name and fnmatch.fnmatch(rel, glob) and rx.search(s):
                        verdict = "allowed: " + reason
                        used.add(i)
                        break
                hits_rows.append((rel, enc, s, verdict))
        distinct = {}
        for rel, enc, s, verdict in hits_rows:
            distinct.setdefault((s, verdict), set()).add(rel)
        bad_paths = sum(1 for r in hits_rows if r[3] == "NOT ALLOWED")
        refusals += bad_paths
        lines.append(f"hits: {len(hits_rows)} in {len({r[0] for r in hits_rows})} files; not allowed: {bad_paths}")
        for (s, verdict), files in sorted(distinct.items(), key=lambda kv: (kv[0][1] != "NOT ALLOWED", kv[0][0])):
            v = "NOT ALLOWED" if verdict == "NOT ALLOWED" else "allowed"
            lines.append(f"  [{v}] {s!r} in {len(files)} file(s), e.g. {sorted(files)[0]}")
        for i, (eng, glob, rx, reason) in enumerate(rules):
            if eng == name and i not in used:
                lines.append(f"  (allowance not needed by this engine: {glob} {rx.pattern})")
        lines.append("")
        lines.append("## 4. Personal paths in any file")
        ph = scan_personal(root, name)
        refusals += len(ph)
        for where, s in ph:
            lines.append(f"  REFUSED {where}: {s!r}")
        lines.append(f"hits: {len(ph)} in {len(machos) + len(pes) + len(others)} files")
        lines.append("")
        lines.append(f"RESULT: {'pass' if refusals == 0 else f'REFUSED ({refusals} problem(s))'}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(report_dir, exist_ok=True)
    with open(os.path.join(report_dir, f"{name}.guard.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(report_dir, f"{name}.path-hits.tsv"), "w") as f:
        f.write("file\tencoding\tstring\tverdict\n")
        for r in hits_rows:
            f.write("\t".join(x.replace("\t", " ") for x in r) + "\n")
    print(f"== {name}")
    shown = {}
    for l in lines:
        if l.startswith(("files:", "hits:", "RESULT")):
            print("   " + l)
            continue
        kind_ = next((k for k in ("REFUSED", "  [NOT", "  REFUSED") if l.startswith(k)), None)
        if kind_:
            shown[kind_] = shown.get(kind_, 0) + 1
            if shown[kind_] <= 8:
                print("   " + l[:220])
            elif shown[kind_] == 9:
                print(f"   ... more in {os.path.join(report_dir, name + '.guard.txt')}")
    return refusals


def cmd_archives(report_dir, archives):
    c = conf("ADP_MONITOR_BUNDLE_ID", "HELPER_REQUIREMENT", "ADP_MONITOR_SOURCE", "HELPER_CONTROL")
    req, forbidden = c["HELPER_REQUIREMENT"], c["ADP_MONITOR_BUNDLE_ID"]
    if not req or not forbidden:
        sys.exit("release.conf: HELPER_REQUIREMENT and ADP_MONITOR_BUNDLE_ID must be set")
    src_req = requirement_from_source(c["ADP_MONITOR_SOURCE"])
    if src_req is None:
        if os.environ.get("ADP_GUARD_NEED_SOURCE"):
            sys.exit(f"ADP Monitor's helper source is not at {c['ADP_MONITOR_SOURCE']} (ADP_MONITOR_SOURCE): "
                     "cannot confirm the requirement")
        print("note: ADP Monitor's helper source not found; using release.conf's requirement as written")
    elif src_req != req:
        sys.exit(f"release.conf's HELPER_REQUIREMENT differs from the helper's source:\n  conf:   {req}\n  source: {src_req}")
    else:
        print("requirement: release.conf matches ADP Monitor's helper source")
    control = c["HELPER_CONTROL"]
    if not os.path.exists(control):
        sys.exit(f"HELPER_CONTROL {control} is not there: without a file the requirement accepts, the check proves nothing")
    rc, msg = satisfies(control, req)
    if rc != 0:
        sys.exit(f"the requirement refuses the control {control} ({msg}): the check would prove nothing")
    print(f"control: the requirement accepts {control} (identifier {codesign_info(control).get('Identifier')})")
    rules = load_allow()
    total = 0
    for a in archives:
        total += check_archive(a, req, forbidden, rules, report_dir)
    print(f"engine guard: {'pass' if total == 0 else f'REFUSED, {total} problem(s)'} ({len(archives)} archive(s))")
    return 1 if total else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) >= 3 and args[0] == "archives":
        sys.exit(cmd_archives(args[1], args[2:]))
    if len(args) >= 2 and args[0] == "personal":
        sys.exit(cmd_personal(args[1:]))
    sys.exit(__doc__)
