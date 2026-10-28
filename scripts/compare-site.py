#!/usr/bin/env python3
"""Compare two site builds from scripts/build-site.sh, ignoring per-build noise.

Usage: scripts/compare-site.py .migration/baselines/<a> .migration/baselines/<b>

Ignored:
- pagefind/ (search index; its file names hash the page HTML)
- random UUIDs that components generate per build (element ids, script tokens):
  any UUID not directly after a "/". UUIDs in URL paths, such as Directus
  /assets/<id> links, are still compared.
- which CMS the build used: the local, test and production CMS URLs are
  treated as the same.
"""
import difflib
import re
import sys
from pathlib import Path

UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
NON_URL_UUID = re.compile(r"(?<!/)" + UUID)
CMS_URL = re.compile(
    r"https?://(?:localhost:8055|ffcp-cms-test\.(?:fly|tupp)\.dev|(?:cms|assets)\.familyforestcarbon\.org)"
)
IGNORED_DIRS = {"pagefind"}


def normalize(text):
    return NON_URL_UUID.sub("<uuid>", CMS_URL.sub("<cms>", text))


def files(root):
    return {
        p.relative_to(root)
        for p in root.rglob("*")
        if p.is_file() and p.name != ".DS_Store" and p.relative_to(root).parts[0] not in IGNORED_DIRS
    }


def main(a, b):
    a, b = Path(a), Path(b)
    fa, fb = files(a), files(b)
    problems = 0
    for p in sorted(fa - fb):
        print(f"only in {a.name}: {p}")
        problems += 1
    for p in sorted(fb - fa):
        print(f"only in {b.name}: {p}")
        problems += 1
    for p in sorted(fa & fb):
        da, db = (a / p).read_bytes(), (b / p).read_bytes()
        if da == db:
            continue
        if p.suffix in {".html", ".xml", ".txt", ".js", ".css", ".json"}:
            ta, tb = normalize(da.decode()), normalize(db.decode())
            if ta == tb:
                continue
            print(f"differs: {p}")
            # Split tags onto lines so the diff is readable
            la, lb = ta.replace("><", ">\n<").splitlines(), tb.replace("><", ">\n<").splitlines()
            for line in list(difflib.unified_diff(la, lb, lineterm="", n=0))[2:12]:
                print("   ", line[:200])
        else:
            print(f"differs (binary): {p}")
        problems += 1
    print(f"\n{problems} difference(s) between {a.name} and {b.name}")
    return 1 if problems else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
