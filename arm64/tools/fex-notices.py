#!/usr/bin/env python3 -I
# SPDX-License-Identifier: MIT
"""Fail if FEX's builds compiled third-party code whose notice the engine does not ship.

  fex-notices.py --src FEX_SRC --licenses LICENSES_DIR --table tools/fex-notices.tsv BUILD_DIR...

Reads `ninja -t deps` of each FEX build folder (every source and header the compiler read), keeps the files
below FEX_SRC, and flags each one that has a copyright line, an SPDX-FileCopyrightText line, a public-domain
statement, or an SPDX-License-Identifier other than MIT (FEX's own files carry only "SPDX-License-Identifier:
MIT"). Every flagged file must match a line of the table, and every licenses/ file that line names must exist.
Prints a report (paths relative to FEX's tree) and exits 1 on any unexplained file or missing text.
Reads only; runs nothing but ninja's dependency listing.
"""
import argparse, fnmatch, os, re, subprocess, sys

FLAG = re.compile(rb"copyright|SPDX-FileCopyrightText|public[ -]domain", re.I)
SPDX = re.compile(rb"SPDX-License-Identifier:\s*(\S[^\r\n*]*)")

ap = argparse.ArgumentParser()
ap.add_argument("--src", required=True)
ap.add_argument("--licenses", required=True)
ap.add_argument("--table", required=True)
ap.add_argument("builds", nargs="+")
a = ap.parse_args()
src = os.path.realpath(a.src) + os.sep

table = []
for line in open(a.table, encoding="utf-8"):
    if not line.strip() or line.startswith("#"):
        continue
    pattern, texts, why = line.rstrip("\n").split("\t")
    table.append((pattern, [] if texts == "-" else texts.split(","), why))

inputs = set()
for b in a.builds:
    out = subprocess.run(["ninja", "-C", b, "-t", "deps"], capture_output=True, text=True)
    if out.returncode:
        sys.exit(f"ninja -t deps failed in {b}: {out.stderr.strip()}")
    deps = [l.strip() for l in out.stdout.splitlines() if l.startswith((" ", "\t")) and l.strip()]
    if not deps:
        sys.exit(f"{b}: ninja recorded no dependencies (was FEX built there?)")
    for d in deps:
        p = os.path.realpath(d if os.path.isabs(d) else os.path.join(b, d))
        if p.startswith(src):
            inputs.add(p[len(src):])

flagged, why_flagged = [], {}
for rel in sorted(inputs):
    data = open(src + rel, "rb").read()
    reasons = []
    if FLAG.search(data):
        reasons.append("copyright or public-domain text")
    for m in SPDX.finditer(data):
        lic = m.group(1).strip().decode("utf-8", "replace")
        if lic != "MIT":
            reasons.append(f"SPDX {lic}")
    if reasons:
        flagged.append(rel)
        why_flagged[rel] = "; ".join(sorted(set(reasons)))

covered = {i: [] for i in range(len(table))}
unexplained = []
for rel in flagged:
    hit = next((i for i, (pat, _, _) in enumerate(table) if fnmatch.fnmatchcase(rel, pat)), None)
    if hit is None:
        unexplained.append(rel)
    else:
        covered[hit].append(rel)

missing = [(pat, t) for i, (pat, texts, _) in enumerate(table) if covered[i] for t in texts
           if not os.path.isfile(os.path.join(a.licenses, t))]

print(f"FEX notices: {len(inputs)} files below FEX's tree read by {len(a.builds)} builds; {len(flagged)} carry "
      f"third-party copyright, public-domain or non-MIT licence text")
for i, (pat, texts, why) in enumerate(table):
    n = len(covered[i])
    print(f"  {n:4d}  {pat}  ->  {', '.join(texts) or 'no notice needed'}  ({why})" if n else
          f"     0  {pat}  (matched nothing in this build)")
for rel in unexplained:
    print(f"  UNEXPLAINED  {rel}: {why_flagged[rel]}")
for pat, t in missing:
    print(f"  MISSING  licenses/{t} (for {pat})")
if unexplained or missing:
    print("FEX notices: FAIL (add the notice to licenses/ in package.sh and a line to tools/fex-notices.tsv)")
    sys.exit(1)
print("FEX notices: every third-party file the FEX builds read has its notice in licenses/")
