#!/usr/bin/env python3
"""Check that a baseline build shows lists in the same order as the live site.

Usage: scripts/check-live-order.py .migration/baselines/<name> [<site url>, default SITE_URL from migration.env]

Items with no sort value come back in whatever order a restore happens to give,
which can differ from production. Run this on the fresh baseline before freezing
the order with backfill-sort.py. For each page it compares the sequence of
headings and accordion labels; same items in a different order means that
restore's order is wrong.
"""
import html
import re
import sys
import urllib.request
from pathlib import Path

ITEM = re.compile(r'<h[1-4][^>]*>(.*?)</h[1-4]>|class="tab__label"[^>]*>(.*?)</label>', re.S)


def items(page):
    out = []
    for m in ITEM.finditer(page):
        raw = m.group(1) if m.group(1) is not None else m.group(2)
        text = html.unescape(re.sub(r"<[^>]+>", "", raw))
        text = re.sub(r"\s+", " ", text).strip()
        if text:
            out.append(text)
    return out


def project_env():
    """KEY=value settings from migration.env at the repo root (comments stripped)."""
    env = {}
    for line in (Path(__file__).resolve().parents[1] / "migration.env").read_text().splitlines():
        line = line.split(" #")[0].strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def main(baseline, site=None):
    site = (site or project_env()["SITE_URL"]).rstrip("/")
    root = Path(baseline)
    reordered, changed = [], []
    pages = sorted(p for p in root.rglob("index.html") if "pagefind" not in p.parts)
    for p in pages:
        path = "/" + str(p.parent.relative_to(root)).replace(".", "").strip("/")
        path = path if path == "/" else path + "/"
        try:
            live = urllib.request.urlopen(site + path, timeout=30).read().decode()
        except Exception as e:  # e.g. a page that only exists in the CMS copy
            print(f"skip {path}: {e}")
            continue
        a, b = items(p.read_text()), items(live)
        if a == b:
            continue
        (reordered if sorted(a) == sorted(b) else changed).append(path)
    for path in reordered:
        print(f"REORDERED {path}")
    for path in changed:
        print(f"content differs {path} (an edit since the backup, or a rendering difference)")
    print(f"\n{len(pages)} pages checked: {len(reordered)} reordered, {len(changed)} with other differences")
    return 1 if reordered else 0


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
