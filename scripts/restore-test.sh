#!/usr/bin/env bash
# Restore test for the nightly backups: newest <env>/db/daily/ dump + <env>/files/
# from the snapshots bucket -> local Postgres 18 + this repo's Directus image ->
# site build -> compare with a baseline.
# Usage: scripts/restore-test.sh <baseline-name> [test|prod]
#   <baseline-name>  a build in .migration/baselines/ to compare with (e.g. the
#                    latest rehearsal's <backup>-production build)
#
# Needs .env.fly (R2 endpoint) and .env.backup (BACKUP_R2_* token). Read-only on
# the buckets; nothing touches Neon or Fly. The files go to .migration/restore-test/
# and are deleted at the end (KEEP=1 keeps them and the containers for inspection).
# Backups hold no cached thumbnails, so the restored CMS makes them all on first
# request, and that first build can drop images and even pages (AFF: 18 image
# errors, 1 page missing). So the site is built twice and only the second build
# is compared. The baseline must come from the same site code.
set -euo pipefail

BASELINE=${1:?usage: scripts/restore-test.sh <baseline-name> [test|prod]}
ENV=${2:-test}
CMS=$(cd "$(dirname "$0")/.." && pwd)
cd "$CMS"
. ./migration.env
W=$CMS/.migration/restore-test
IMAGE=$FLY_APP-directus:restore-test
[ -d ".migration/baselines/$BASELINE" ] || { echo "no baseline .migration/baselines/$BASELINE" >&2; exit 1; }
for f in .env.fly .env.backup; do [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }; done
if lsof -nP -iTCP:8055 -sTCP:LISTEN >/dev/null 2>&1; then
	echo "port 8055 is in use (stop the local dev Directus first)" >&2; exit 1
fi
mkdir -p "$W" && chmod 700 "$CMS/.migration"

R2E=$(grep -E '^STORAGE_R2_ENDPOINT=' .env.fly | cut -d= -f2-)
BUCKET=$(grep -E '^BACKUP_R2_BUCKET=' .env.backup | cut -d= -f2-)
rcl() {
	docker run --rm --env-file .env.backup -e "R2_ENDPOINT=$R2E" -v "$W:/w" --entrypoint sh rclone/rclone:1.68 -c '
		export RCLONE_CONFIG_B_TYPE=s3 RCLONE_CONFIG_B_PROVIDER=Cloudflare RCLONE_CONFIG_B_NO_CHECK_BUCKET=true
		export RCLONE_CONFIG_B_ENDPOINT=$R2_ENDPOINT RCLONE_CONFIG_B_ACCESS_KEY_ID=$BACKUP_R2_KEY RCLONE_CONFIG_B_SECRET_ACCESS_KEY=$BACKUP_R2_SECRET
		'"$1" 2> >(grep -v 'Config file' >&2)
}
cleanup() {
	[ "${KEEP:-0}" = 1 ] && { echo "KEEP=1: containers restore-db/restore-directus and $W left in place"; return; }
	docker rm -f restore-directus restore-db >/dev/null 2>&1 || true
	docker network rm restore-net >/dev/null 2>&1 || true
	rm -rf "$W/files" "$W/directus.dump"
}
trap cleanup EXIT
T0=$(date +%s); t() { echo "[$(( $(date +%s) - T0 ))s] $*"; }

t "== image"
docker build -q -t "$IMAGE" . >/dev/null

t "== download newest $ENV/db/daily dump + $ENV/files"
DUMP=$(rcl "rclone lsf b:$BUCKET/$ENV/db/daily -q" | sort | tail -1)
[ -n "$DUMP" ] || { echo "no dump in $BUCKET/$ENV/db/daily" >&2; exit 1; }
echo "dump: $DUMP"
rcl "rclone copyto b:$BUCKET/$ENV/db/daily/$DUMP /w/directus.dump -q"
rcl "rclone copy b:$BUCKET/$ENV/files /w/files --transfers 16 -q"
echo "files: $(find "$W/files" -type f | wc -l | tr -d ' ')"

t "== restore into Postgres 18"
docker rm -f restore-directus restore-db >/dev/null 2>&1 || true
docker network create restore-net >/dev/null 2>&1 || true
docker run -d --name restore-db --network restore-net -e POSTGRES_PASSWORD=x -e POSTGRES_DB=directus -v "$W:/w:ro" postgres:18 >/dev/null
until docker exec restore-db pg_isready -U postgres -q; do sleep 1; done; sleep 2
docker exec restore-db pg_restore -U postgres -d directus --no-owner --no-acl --exit-on-error /w/directus.dump
docker exec restore-db psql -U postgres -d directus -Atc "select 'tables: '||count(*) from information_schema.tables where table_schema='public'; select 'files: '||count(*)||' (storage '||string_agg(distinct storage, ',')||')' from directus_files"

t "== start Directus on the restored data"
# The files' storage location is "r2"; point it at the downloaded files instead.
docker run -d --name restore-directus --network restore-net -p 127.0.0.1:8055:8055 \
	-e SECRET=restore-test-only-secret-0123456789abcdef -e PUBLIC_URL=http://localhost:8055 \
	-e DB_CLIENT=pg -e DB_CONNECTION_STRING=postgres://postgres:x@restore-db:5432/directus \
	-e STORAGE_LOCATIONS=r2 -e STORAGE_R2_DRIVER=local -e STORAGE_R2_ROOT=/directus/restored \
	-e CACHE_ENABLED=true -e CACHE_STORE=memory -e TELEMETRY=false -e ASSETS_TRANSFORM_IMAGE_MAX_DIMENSION=12000 \
	-v "$W/files:/directus/restored" "$IMAGE" >/dev/null
for _ in $(seq 1 90); do curl -sf http://localhost:8055/server/ping >/dev/null && break; sleep 2; done
curl -sf http://localhost:8055/server/ping >/dev/null || { echo "Directus didn't start: docker logs restore-directus" >&2; KEEP=1; exit 1; }

t "== warm-up build (makes the thumbnails the backup doesn't hold)"
scripts/build-site.sh restore-test-warmup >"$W/build-warmup.log" 2>&1 || { echo "build failed: $W/build-warmup.log" >&2; exit 1; }
echo "warm-up image failures: $(grep -c 'getRemoteImageUrl failed' "$W/build-warmup.log" || true)"
rm -rf "$CMS/.migration/baselines/restore-test-warmup"

t "== build the site + compare with $BASELINE"
scripts/build-site.sh restore-test >"$W/build.log" 2>&1 || { echo "build failed: $W/build.log" >&2; exit 1; }
tail -1 "$W/build.log"
echo "image failures: $(grep -c 'getRemoteImageUrl failed' "$W/build.log" || true)"
OK=1
python3 -I scripts/compare-site.py ".migration/baselines/$BASELINE" .migration/baselines/restore-test >"$W/compare.txt" || OK=0
tail -1 "$W/compare.txt"
t "== done"
[ "$OK" = 1 ] || { echo "!! differences: see $W/compare.txt" >&2; exit 1; }
