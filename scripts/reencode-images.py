#!/usr/bin/env python3
"""Bring CMS images down to the media baseline (longest side 2000 px) by replacing
each file's content in place: same id, so every reference keeps working.

Usage:
  scripts/reencode-images.py plan <plan.csv>                  # list the files, from the live CMS
  scripts/reencode-images.py run <plan.csv> --originals DIR [--env FILE] [--only ID,...] [--limit N] [--apply]

Rules (AFF rules 2026-11-11, FFCP max 2000 / q80):
  - JPEG/TIFF/AVIF/WebP over 2000 px, and those within 2000 px but over 1 MB:
    re-uploaded so the CMS's upload resizer makes them (WebP q80, max 2000 px),
    as it does for new uploads. Over 2000 px they're first shrunk to 2000 px as a
    near-lossless JPEG, so the upload is small.
  - PNG over 2000 px: shrunk to 2000 px as WebP q85 here, uploaded marked
    "optimized" so the resizer leaves it. PNGs within 2000 px are left alone.
  - A file is skipped unless the result is at least 20% smaller.
Originals come from DIR/<filename_disk> and must match the CMS's filesize.
Without --apply nothing is uploaded (dry run, with size estimates).
The env file (default .env.cleanup) has DIRECTUS_URL and DIRECTUS_ADMIN_TOKEN.
Replaced originals stay in the backups bucket (prod/files/<old filename_disk>).
"""
import argparse, csv, json, pathlib, subprocess, sys, tempfile, time, urllib.parse, urllib.request, urllib.error

ROOT = pathlib.Path(__file__).resolve().parents[1]
PREP = ROOT / "scripts" / "prepare-image.mjs"
MAX, MIN_SAVING = 2000, 0.2

def load_env(path):
    vals = {}
    for line in pathlib.Path(path).read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1); vals[k.strip()] = v.strip().strip('"')
    return vals["DIRECTUS_URL"].rstrip("/"), vals["DIRECTUS_ADMIN_TOKEN"]

class Api:
    def __init__(self, url, token): self.url, self.token = url, token
    def __call__(self, method, path, params=None, body=None):
        url = f"{self.url}{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
        req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, method=method,
                                     headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json", "User-Agent": "ffcp-cms-reencode"})
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    raw = r.read(); return json.loads(raw)["data"] if raw else None
            except urllib.error.HTTPError as e:
                if e.code in (429, 502, 503, 504) and attempt < 4: time.sleep(5 * (attempt + 1)); continue
                raise RuntimeError(f"{method} {path}: HTTP {e.code} {e.read()[:300]!r}")

    def upload(self, fid, path, mime, filename, optimized):
        # curl handles the multipart upload; the filename is quoted (names contain commas)
        safe = filename.replace('"', "'").replace("\\", "")
        cmd = ["curl", "-sS", "-X", "PATCH", "-H", f"Authorization: Bearer {self.token}", "-w", "\n%{http_code}"]
        if optimized: cmd += ["-F", "optimized=true"]
        cmd += ["-F", f'file=@{path};type={mime};filename="{safe}"', f"{self.url}/files/{fid}"]
        out = subprocess.run(cmd, capture_output=True, text=True).stdout.rsplit("\n", 1)
        if len(out) != 2 or out[1] != "200": raise RuntimeError(f"upload {fid}: HTTP {out[-1]} {out[0][:300]}")

FIELDS = "id,type,filesize,width,height,filename_disk,filename_download"

def rule(f):
    t, size = f["type"] or "", int(f["filesize"] or 0)
    side = max(f["width"] or 0, f["height"] or 0)
    if t == "image/png": return "webp85" if side > MAX else None
    if t in ("image/jpeg", "image/tiff", "image/avif", "image/webp"):
        return "resizer" if side > MAX or size > 1_000_000 else None
    return None

def stem(name): return name.rsplit(".", 1)[0] if "." in name else name

def prep(mode, src, out=None):
    r = subprocess.run(["node", str(PREP), mode, str(src)] + ([str(out)] if out else []), capture_output=True, text=True)
    if r.returncode: raise RuntimeError(f"prepare {mode} {src}: {r.stderr.strip()[:300]}")
    return json.loads(r.stdout)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["plan", "run"]); ap.add_argument("plan")
    ap.add_argument("--env", default=str(ROOT / ".env.cleanup")); ap.add_argument("--originals")
    ap.add_argument("--only"); ap.add_argument("--limit", type=int); ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    api = Api(*load_env(a.env))

    if a.cmd == "plan":
        files = api("GET", "/files", {"fields": FIELDS, "limit": -1})
        rows = [dict(f, mode=rule(f)) for f in files if rule(f)]
        rows.sort(key=lambda f: -int(f["filesize"]))
        with open(a.plan, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=["mode"] + FIELDS.split(",")); w.writeheader()
            w.writerows({k: r[k] for k in w.fieldnames} for r in rows)
        by = {}
        for r in rows: by.setdefault(r["mode"], [0, 0]); by[r["mode"]][0] += 1; by[r["mode"]][1] += int(r["filesize"])
        print(f"{len(rows)} files: " + ", ".join(f"{m} {n} ({s/1e6:,.0f} MB)" for m, (n, s) in by.items()))
        return

    rows = list(csv.DictReader(open(a.plan)))
    if a.only: rows = [r for r in rows if r["id"] in set(a.only.split(","))]
    if a.limit: rows = rows[:a.limit]
    originals = pathlib.Path(a.originals)
    log = ROOT / ".migration" / f"reencode-{time.strftime('%Y%m%d-%H%M%S')}{'' if a.apply else '-dryrun'}.jsonl"
    totals = {"before": 0, "after": 0, "done": 0, "skipped": 0, "failed": 0}
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="reencode-"))
    for n, r in enumerate(rows, 1):
        fid, mode = r["id"], r["mode"]
        entry = {"id": fid, "mode": mode, "before": {k: r[k] for k in FIELDS.split(",")}}
        try:
            cur = api("GET", f"/files/{fid}", {"fields": FIELDS})
            if cur["filename_disk"] != r["filename_disk"] or cur["filesize"] != r["filesize"]:
                raise RuntimeError("changed since the plan")
            src = originals / r["filename_disk"]
            if not src.exists() or src.stat().st_size != int(r["filesize"]):
                raise RuntimeError(f"no matching original in {originals}")
            before = int(r["filesize"])
            if mode == "webp85":
                out = tmp / f"{fid}.webp"; p = prep("webp85", src, out); expected = p["bytes"]
                mime, optimized = "image/webp", True
            else:
                expected = prep("estimate", src)["bytes"]
                out = tmp / f"{fid}.prep"; p = prep("resizer", src, out); mime, optimized = p["type"], False
            entry["expected"] = expected
            if expected > before * (1 - MIN_SAVING):
                entry["result"] = "skipped: under 20% smaller"; totals["skipped"] += 1
            elif not a.apply:
                entry["result"] = "dry run"; totals["before"] += before; totals["after"] += expected
            else:
                name = stem(r["filename_download"]) + ".webp"
                api.upload(fid, out, mime, name, optimized)
                # The resizer runs after the upload and sets the type before the size: wait
                # until the file is WebP, no longer the uploaded size (resizer mode), and
                # the same on two reads in a row
                uploaded, last = out.stat().st_size, None
                for _ in range(90):
                    after = api("GET", f"/files/{fid}", {"fields": FIELDS})
                    size = int(after["filesize"] or 0)
                    ready = after["type"] == "image/webp" and size < before and (optimized or size != uploaded)
                    if ready and after == last: break
                    last = after if ready else None
                    time.sleep(2)
                else:
                    raise RuntimeError(f"not converted after upload: {after}")
                if after["filename_download"] != name:
                    api("PATCH", f"/files/{fid}", body={"filename_download": name})
                    after["filename_download"] = name
                w0, h0, w1, h1 = int(r["width"]), int(r["height"]), after["width"], after["height"]
                if max(w1, h1) > MAX or abs(w1 / h1 - w0 / h0) > 0.01 * (w0 / h0) + 2 / h1:
                    raise RuntimeError(f"unexpected size {w1}x{h1} (was {w0}x{h0})")
                entry["after"] = after; entry["result"] = "done"
                totals["done"] += 1; totals["before"] += before; totals["after"] += int(after["filesize"])
        except Exception as e:
            entry["result"] = f"FAILED: {e}"; totals["failed"] += 1
        finally:
            for f in tmp.glob(f"{fid}.*"): f.unlink()
        with open(log, "a") as fh: fh.write(json.dumps(entry) + "\n")
        print(f"[{n}/{len(rows)}] {fid[:8]} {mode:7} {int(r['filesize'])/1e6:7.2f} MB -> "
              f"{(entry.get('after') or {}).get('filesize') and int(entry['after']['filesize'])/1e6 or entry.get('expected', 0)/1e6:6.2f} MB  {entry['result']}", flush=True)
    print(f"\n{totals['done']} replaced, {totals['skipped']} skipped, {totals['failed']} failed; "
          f"{totals['before']/1e6:,.0f} MB -> {totals['after']/1e6:,.0f} MB{' (estimated)' if not a.apply else ''}; log {log}")
    if totals["failed"]: sys.exit(1)

if __name__ == "__main__":
    main()
