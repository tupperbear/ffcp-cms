#!/usr/bin/env bash
# Runbook: migrate the production CMS (VPS, Directus 11.5.1) to Fly + Neon + R2.
#
# Usage (from the cms repo): scripts/migration/migrate.sh <backup-name> [rehearsal|cutover]
#   <backup-name>  folder name printed by the VPS backup, e.g. 20261028-1740.
#                  Make it first (owner, one sudo prompt):
#                  scp scripts/vps-backup.sh netcup:ffcp-vps-backup.sh && ssh -t netcup 'bash ffcp-vps-backup.sh'
#   rehearsal      flows deactivated; PUBLIC_URL stays https://ffcp-cms.fly.dev (default)
#   cutover        flows kept; PUBLIC_URL=https://cms.familyforestcarbon.org
#
# Wipes and replaces the Neon database used by the ffcp-cms app; asks before
# that and before deploying (CONFIRM=0 to skip the prompts). Only reads from the
# production CMS (the site's own API requests). Working files and timings go to
# .migration/ (gitignored); the site repo must be checked out next to this one (../site).
set -euo pipefail

BACKUP=${1:?usage: scripts/migration/migrate.sh <backup-name> [rehearsal|cutover]}
MODE=${2:-rehearsal}
[[ $MODE == rehearsal || $MODE == cutover ]] || { echo "mode must be rehearsal or cutover" >&2; exit 1; }

CMS=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPTS=$CMS/scripts
SITE=$CMS/../site
M=$CMS/.migration
B=$M/backups/$BACKUP
W=$M/rehearsal/$BACKUP
LOG=$M/rehearsal/$BACKUP.log
PROD_CMS=https://cms.familyforestcarbon.org
APP=ffcp-cms
APP_URL=https://$APP.fly.dev
mkdir -p "$W" && chmod 700 "$M"

STEP_T=$(date +%s)
step() {
	local now; now=$(date +%s)
	[ -n "${STEP_NAME:-}" ] && echo "$STEP_NAME: $((now - STEP_T))s" | tee -a "$LOG"
	STEP_NAME=$1; STEP_T=$now
	echo; echo "=== $1"
}
confirm() {
	[ "${CONFIRM:-1}" = 0 ] && return
	read -r -p "$1 [y/N] " a; [[ $a == y ]] || { echo "Stopped."; exit 1; }
}
site_token() { grep -E '^DIRECTUS_STATIC_TOKEN=' "$SITE/.env" | cut -d= -f2- | tr -d "\"' "; }
psql_neon() { docker run --rm -i --env-file "$CMS/.env.fly.prod" -v "$W:/s" postgres:18 sh -c "psql \"\$DB_CONNECTION_STRING\" $*"; }
rclone_r2() {
	docker run --rm --env-file "$CMS/.env.fly.prod" -v "$W:/w" --entrypoint sh rclone/rclone:1.68 -c '
		export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
		export RCLONE_CONFIG_R2_ENDPOINT=$STORAGE_R2_ENDPOINT RCLONE_CONFIG_R2_ACCESS_KEY_ID=$STORAGE_R2_KEY RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$STORAGE_R2_SECRET
		'"$1"
}
# Build the site against a CMS through a localhost proxy, so image handling is
# the same as for local builds (image.domains allows localhost).
build_via() {
	docker rm -f migrate-proxy >/dev/null 2>&1 || true
	docker run -d --rm --name migrate-proxy -p 127.0.0.1:8055:8055 caddy:2 \
		caddy reverse-proxy --from :8055 --to "$1" --change-host-header >/dev/null
	for _ in $(seq 1 30); do curl -sf http://localhost:8055/server/ping >/dev/null && break; sleep 1; done
	"$SCRIPTS/build-site.sh" "$2" >"$W/build-$2.log" 2>&1 || { docker rm -f migrate-proxy >/dev/null; echo "build failed: $W/build-$2.log" >&2; exit 1; }
	docker rm -f migrate-proxy >/dev/null
}

echo "migrate $BACKUP ($MODE) started $(date -u +%FT%TZ)" | tee -a "$LOG"

step "0 preflight"
for f in "$CMS/.env.fly.prod" "$CMS/fly.prod.toml" "$SITE/.env"; do [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }; done
[ -n "$(site_token)" ] || { echo "no DIRECTUS_STATIC_TOKEN in $SITE/.env" >&2; exit 1; }
flyctl status -a "$APP" >/dev/null || { echo "Fly app $APP not found / not logged in" >&2; exit 1; }
if lsof -nP -iTCP:8055 -sTCP:LISTEN >/dev/null 2>&1; then
	echo "port 8055 is in use (stop the local dev Directus: docker compose -f $CMS/docker-compose.dev.yml stop directus)" >&2; exit 1
fi
echo "ok"

step "1 download + verify backup"
rsync -a "netcup:ffcp-backup/$BACKUP/" "$B/"
(cd "$B" && shasum -a 256 -c SHA256SUMS)

step "2 extract uploads"
rm -rf "$W/uploads" && mkdir -p "$W/uploads"
tar -xf "$B/volumes.tar" -C "$W/uploads" --strip-components=2 '*_directus_uploads/_data'
echo "$(find "$W/uploads" -type f -not -path '*/extensions/*' | wc -l | tr -d ' ') files"

step "3 reference build from the production CMS"
build_via "$PROD_CMS" "$BACKUP-production"

step "4 restore into Neon"
confirm "Wipe the Neon database used by $APP and restore $BACKUP into it?"
rm -f "$W/backfill.sql"
docker run --rm --env-file "$CMS/.env.fly.prod" -v "$B:/b:ro" -v "$W:/s:ro" -v "$SCRIPTS/migration:/scripts:ro" \
	-e KEEP_FLOWS="$([ "$MODE" = cutover ] && echo 1 || echo 0)" postgres:18 /scripts/neon-restore.sh

step "5 sort fix from the production API"
psql_neon "-Atc \"select json_agg(json_build_object('many_collection',many_collection,'many_field',many_field,'one_collection',one_collection,'one_field',one_field,'one_allowed_collections',one_allowed_collections,'one_collection_field',one_collection_field,'junction_field',junction_field,'sort_field',sort_field)) from directus_relations\"" >"$W/relations.json"
DIRECTUS_TOKEN=$(site_token) python3 -I "$SCRIPTS/migration/backfill-sort.py" "$PROD_CMS" "$W/relations.json" "$SCRIPTS/migration/site-requests.txt" >"$W/backfill.sql"
psql_neon "-q -v ON_ERROR_STOP=1 -f /s/backfill.sql"
echo "applied $(grep -c '^update' "$W/backfill.sql") rows"

step "6 sync files to R2"
psql_neon "-Atc 'select filename_disk from directus_files order by 1'" >"$W/r2-files.txt"
rclone_r2 'rclone copy /w/uploads r2:$STORAGE_R2_BUCKET --files-from /w/r2-files.txt --transfers 16 -q && rclone check /w/uploads r2:$STORAGE_R2_BUCKET --files-from /w/r2-files.txt --one-way 2>&1 | grep -E "differences|matching"'

step "7 deploy $APP"
PUBLIC_URL=$([ "$MODE" = cutover ] && echo "$PROD_CMS" || echo "$APP_URL")
confirm "Deploy $APP with PUBLIC_URL=$PUBLIC_URL?"
(cd "$CMS" && flyctl secrets import --stage -a "$APP" <.env.fly.prod >/dev/null &&
	flyctl deploy -c fly.prod.toml -a "$APP" --ha=false -e PUBLIC_URL="$PUBLIC_URL" 2>&1 | grep -E "good state|rror" | tail -2)
for _ in $(seq 1 40); do curl -sf "$APP_URL/server/ping" >/dev/null && break; sleep 3; done
echo "health: $(curl -s "$APP_URL/server/health")"

step "8 verify: new CMS vs production"
build_via "$APP_URL" "$BACKUP-$APP"
VERIFY_OK=1
python3 -I "$SCRIPTS/compare-site.py" "$M/baselines/$BACKUP-production" "$M/baselines/$BACKUP-$APP" >"$W/compare.txt" || VERIFY_OK=0
tail -1 "$W/compare.txt"
python3 -I "$SCRIPTS/check-live-order.py" "$M/baselines/$BACKUP-$APP" >"$W/live-order.txt" || VERIFY_OK=0
tail -1 "$W/live-order.txt"
[ "$VERIFY_OK" = 1 ] || echo "!! Verification found differences: see $W/compare.txt and $W/live-order.txt"

step "done"
echo "migrate $BACKUP ($MODE) finished $(date -u +%FT%TZ)" | tee -a "$LOG"
if [ "$MODE" = cutover ]; then
	cat <<'EOF'

Next (manual), see docs/migration-plan.md "Cutover":
  - DNS: cms.familyforestcarbon.org -> ffcp-cms; retire assets.familyforestcarbon.org
  - Netlify: DIRECTUS_ASSETS_URL=https://cms.familyforestcarbon.org on the live and preview sites
  - Studio: project owner form; backups workflow BACKUP_ENV=prod; R2 prod/ lifecycle + lock
  - Rebuild the live site
EOF
fi
