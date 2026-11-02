#!/usr/bin/env bash
# Record the list requests a site build makes to the old CMS, for backfill-sort.py.
# Usage (from the cms repo): scripts/migration/capture-site-requests.sh [out-file]
#   default out-file: scripts/migration/site-requests.txt
#
# Builds the site through a localhost proxy to the old CMS (pinned to VPS_IP, so
# it works before and after the DNS switch) with an access log, then keeps each
# distinct GET /items/<collection>?... path. Read-only on the CMS. Re-run it
# whenever the site's queries change (a new block type, new fields).
set -euo pipefail
CMS=$(cd "$(dirname "$0")/../.." && pwd)
. "$CMS/migration.env"
OUT=${1:-$CMS/scripts/migration/site-requests.txt}

if lsof -nP -iTCP:8055 -sTCP:LISTEN >/dev/null 2>&1; then
	echo "port 8055 is in use (stop the local dev Directus first)" >&2; exit 1
fi
docker rm -f capture-proxy >/dev/null 2>&1 || true
trap 'docker rm -f capture-proxy >/dev/null 2>&1 || true' EXIT
docker run -d --name capture-proxy -p 127.0.0.1:8055:8055 --add-host "$PROD_DOMAIN:$VPS_IP" caddy:2 \
	caddy reverse-proxy --from :8055 --to "https://$PROD_DOMAIN" --change-host-header --access-log >/dev/null
for _ in $(seq 1 30); do curl -sf http://localhost:8055/server/ping >/dev/null && break; sleep 1; done

"$CMS/scripts/build-site.sh" capture-requests >"$CMS/.migration/capture-requests-build.log" 2>&1 ||
	{ echo "build failed: $CMS/.migration/capture-requests-build.log" >&2; exit 1; }

docker logs capture-proxy 2>&1 | python3 -I -c '
import json, re, sys
seen = []
for line in sys.stdin:
    try:
        req = json.loads(line).get("request") or {}
    except ValueError:
        continue
    uri = req.get("uri", "")
    # list requests only: /items/<collection> with a query, not /items/<collection>/<id>
    if req.get("method") == "GET" and re.match(r"^/items/[^/?]+\?", uri) and uri not in seen:
        seen.append(uri)
print("\n".join(seen))
' >"$OUT.tmp"
[ -s "$OUT.tmp" ] || { rm -f "$OUT.tmp"; echo "no /items requests captured" >&2; exit 1; }
mv "$OUT.tmp" "$OUT"
echo "$(wc -l <"$OUT" | tr -d ' ') requests -> $OUT"
