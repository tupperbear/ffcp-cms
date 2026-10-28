#!/usr/bin/env python3
"""Write explicit sort values that freeze the order the site currently shows.

Many junction/O2M rows have a null `sort`, so their order is whatever Postgres
returns for the exact query, which depends on how rows sit on disk. It differs
between Directus versions and even between restores of the same dump. So the
order is read from the **production CMS's API** (the source of truth, and what
the live site shows): this replays the site's own API requests there, walks the
responses, and writes each list's position into its sort field. Apply the SQL to
the restored copy of the same production data.

Usage:
  DIRECTUS_TOKEN=<site static token> scripts/migration/backfill-sort.py \
      https://cms.familyforestcarbon.org <relations.json> <requests.txt> > backfill.sql

  relations.json  rows of directus_relations (many_collection, many_field,
                  one_collection, one_field, one_allowed_collections,
                  junction_field, sort_field) as a JSON array
  requests.txt    one request path per line, e.g. "/items/pages?fields=..."
                  (copied from the Directus request log during a site build)

It only reads from Directus. Rows the site doesn't receive (drafts) are left as is.
"""
import json
import os
import sys
import urllib.request


def get(base, token, path):
    req = urllib.request.Request(base + path, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req) as res:
        return json.load(res)["data"]


def sql_literal(v):
    return str(v) if isinstance(v, int) else "'" + str(v).replace("'", "''") + "'"


def key_of(v):
    return v.get("id") if isinstance(v, dict) else v


class Walker:
    def __init__(self, relations):
        self.o2m = {(r["one_collection"], r["one_field"]): r for r in relations if r["one_collection"] and r["one_field"]}
        self.m2o = {(r["many_collection"], r["many_field"]): r for r in relations}
        self.updates = {}  # (table, where) -> (sort_field, position)

    def walk(self, item, collection):
        if not isinstance(item, dict) or not collection:
            return
        for field, value in item.items():
            if isinstance(value, list) and (collection, field) in self.o2m:
                self.walk_list(item.get("id"), value, self.o2m[(collection, field)])
            elif isinstance(value, dict) and (collection, field) in self.m2o:
                rel = self.m2o[(collection, field)]
                if rel["one_collection"]:
                    self.walk(value, rel["one_collection"])
                elif rel["one_allowed_collections"]:  # M2A "item"
                    self.walk(value, item.get(rel["one_collection_field"] or "collection"))

    def walk_list(self, parent_id, rows, rel):
        table, parent_fk, sort_field, junction_fk = rel["many_collection"], rel["many_field"], rel["sort_field"], rel["junction_field"]
        for pos, row in enumerate(rows, start=1):
            if sort_field and parent_id is not None and isinstance(row, dict):
                if row.get("id") is not None:
                    where = (("id", row["id"]), (parent_fk, parent_id))
                elif junction_fk and key_of(row.get(junction_fk)) is not None:
                    where = ((parent_fk, parent_id), (junction_fk, key_of(row[junction_fk])))
                else:
                    where = None
                if where:
                    self.updates[(table, where)] = (sort_field, pos)
            self.walk(row, table)

    def sql(self):
        out = ["begin;"]
        for (table, where), (sort_field, pos) in sorted(self.updates.items(), key=lambda kv: (kv[0][0], str(kv[0][1]))):
            cond = " and ".join(f'"{c}" = {sql_literal(v)}' for c, v in where)
            out.append(f'update "{table}" set "{sort_field}" = {pos} where {cond};')
        out.append("commit;")
        return "\n".join(out)


def main(base, relations_file, requests_file):
    token = os.environ["DIRECTUS_TOKEN"]
    relations = json.load(open(relations_file))
    walker = Walker(relations)
    for path in filter(None, (line.strip() for line in open(requests_file))):
        collection = path.split("?")[0].removeprefix("/items/")
        data = get(base, token, path)
        for item in data if isinstance(data, list) else [data]:
            walker.walk(item, collection)
    counts = {}
    for table, _ in walker.updates:
        counts[table] = counts.get(table, 0) + 1
    for table, n in sorted(counts.items()):
        print(f"-- {table}: {n} rows", file=sys.stderr)
    print(walker.sql())


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
