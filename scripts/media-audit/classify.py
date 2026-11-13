#!/usr/bin/env python3
"""Media audit, step 3: classify every CMS file as live (in the site build),
referenced only by hidden content (draft/archived items, or blocks on no page or
post: with the reason), or unreferenced. Needs the scratch audit DB (container
ffcp-audit-db) with audit_refs and audit_build from find-refs.sql.
Writes audit.json next to this script (move it to .migration/).

FFCP: pages_blocks is the only M2A junction; seo rows belong to pages (pages.seo);
text_with_files_block_files rows (file links) belong to their block; directus_fields
(Studio help images in super-header options) counts as system.

Per CMS, check: the M2A junctions (pages_blocks here), the nested
block junctions in `nested`, collections with their own pages (TOP) and system
ones (SYSTEM). Junction rows whose owner id is null (owner deleted) count as
detached. Duplicates (two published items with one slug) show up as "referenced,
shown content": check those by hand."""
import json, subprocess, collections, pathlib

def q(sql):
    out = subprocess.run(["docker", "exec", "ffcp-audit-db", "psql", "-U", "directus", "-At", "-F", "\t", "-c", sql],
                         capture_output=True, text=True, check=True).stdout
    return [line.split("\t") for line in out.splitlines() if line]

status_tables = {r[0] for r in q("select table_name from information_schema.columns where column_name='status' and table_schema='public'")}
status = {}  # (table, id) -> status
def load_status(t):
    if t in status_tables and not any(k[0] == t for k in status):
        for i, s in q(f'select id::text, status from "{t}"'):
            status[(t, i)] = s
    return status

# Parents: (child table, child id) -> [(parent table, parent id)]
parents = collections.defaultdict(list)
for t, owner in (("pages_blocks", "pages"),):
    for oid, coll, item in q(f"select {owner}_id::text, collection, item from {t} where item is not null and {owner}_id is not null"):
        parents[(coll, item)].append((owner, oid))
nested = [  # junction, child fk, child table, parent fk, parent table
    ("carousel_block_carousel_slides", "carousel_slides_id", "carousel_slides", "carousel_block_id", "carousel_block"),
    ("points_with_images_block_point_with_image", "point_with_image_id", "point_with_image", "points_with_images_block_id", "points_with_images_block"),
    # File rows: the junction row itself is the child
    ("text_with_files_block_files", "id", "text_with_files_block_files", "text_with_files_block_id", "text_with_files_block"),
    ("globals_files", "id", "globals_files", "globals_id", "globals"),
]
for j, cfk, ct, pfk, pt in nested:
    for c, p in q(f"select {cfk}::text, {pfk}::text from {j} where {cfk} is not null and {pfk} is not null"):
        parents[(ct, c)].append((pt, p))
for seo, page in q("select seo::text, id::text from pages where seo is not null"):
    parents[("seo", seo)].append(("pages", page))

TOP = {"pages"}  # published ones get their own page
SYSTEM = {"directus_settings", "directus_users", "directus_fields", "globals"}

def why_hidden(t, i, depth=0):
    """None if this row is shown on the live site, else a reason."""
    if t in SYSTEM: return None
    load_status(t)
    s = status.get((t, i))
    if s is not None and s != "published": return f"{t} is {s}"
    if t in TOP: return None
    ps = parents.get((t, i), [])
    if not ps: return f"{t} is not on any page or post"
    reasons = [why_hidden(pt, pi, depth + 1) for pt, pi in ps]
    if any(r is None for r in reasons): return None
    return reasons[0] if len(set(reasons)) == 1 else "; ".join(sorted(set(reasons)))

files = {r[0]: {"id": r[0], "name": r[1], "type": r[2], "size": int(r[3] or 0), "width": r[4] and int(r[4]), "height": r[5] and int(r[5]), "uploaded": r[6][:10], "folder": r[7]}
         for r in q("select f.id::text, f.filename_download, f.type, f.filesize, f.width, f.height, f.uploaded_on::text, coalesce(d.name,'') from directus_files f left join directus_folders d on d.id=f.folder")}
live = {r[0] for r in q("select b.id from audit_build b join directus_files f on f.id::text=b.id")}
refs = collections.defaultdict(list)
for fid, t, c, rid in q("select file_id::text, tbl, col, row_id from audit_refs"):
    refs[fid].append((t, c, rid))

for fid, f in files.items():
    f["refs"] = [f"{t}.{c}#{rid}" for t, c, rid in refs.get(fid, [])]
    if fid in live: f["class"] = "live"
    elif not refs.get(fid): f["class"] = "unreferenced"
    else:
        rs = [why_hidden(t, rid) for t, c, rid in refs[fid]]
        if any(r is None for r in rs):
            f["class"] = "referenced, shown content" ; f["reason"] = "referenced from shown content but not in the build: " + ", ".join(f"{t}.{c}" for (t, c, _), r in zip(refs[fid], rs) if r is None)
            if any(t in SYSTEM for t, _, _ in refs[fid]): f["class"] = "system"
        else:
            f["class"] = "referenced, hidden content"; f["reason"] = "; ".join(sorted(set(rs)))

out = pathlib.Path(__file__).resolve().parents[2] / ".migration" / "audit" / "audit.json"
out.write_text(json.dumps(list(files.values()), indent=1))
by = collections.defaultdict(lambda: [0, 0])
for f in files.values(): by[f["class"]][0] += 1; by[f["class"]][1] += f["size"]
for k, (n, s) in sorted(by.items()): print(f"{k:30} {n:5} files {s/1e9:6.2f} GB")
