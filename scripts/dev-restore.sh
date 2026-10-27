#!/usr/bin/env bash
# Restore a production backup (directus.dump + volumes.tar) into the local dev stack.
# Usage: scripts/dev-restore.sh <backup-dir>
#
# Wipes the local dev database and .dev/ files. All flows are set to inactive
# before Directus starts, so the local copy can't trigger real webhooks or builds.
set -euo pipefail

BACKUP_DIR=${1:?usage: scripts/dev-restore.sh <backup-dir>}
cd "$(dirname "$0")/.."
COMPOSE=(docker compose -f docker-compose.dev.yml)

[[ -f "$BACKUP_DIR/directus.dump" && -f "$BACKUP_DIR/volumes.tar" ]] || {
	echo "Expected directus.dump and volumes.tar in $BACKUP_DIR" >&2
	exit 1
}

echo "== Stopping Directus"
"${COMPOSE[@]}" stop directus 2>/dev/null || true

echo "== Restoring files into .dev/"
rm -rf .dev/uploads .dev/extensions .dev/templates
mkdir -p .dev/uploads .dev/extensions .dev/templates
for vol in uploads extensions templates; do
	tar -xf "$BACKUP_DIR/volumes.tar" -C ".dev/$vol" --strip-components=2 "*_directus_${vol}/_data"
done

echo "== Restoring database"
"${COMPOSE[@]}" up -d --wait database
"${COMPOSE[@]}" exec -T database dropdb -U directus --if-exists --force directus
"${COMPOSE[@]}" exec -T database createdb -U directus directus
"${COMPOSE[@]}" exec -T database pg_restore -U directus -d directus --no-owner --role=directus --exit-on-error <"$BACKUP_DIR/directus.dump"

echo "== Deactivating flows"
"${COMPOSE[@]}" exec -T database psql -U directus -d directus -c \
	"update directus_flows set status = 'inactive' where status = 'active' returning name, trigger;"

echo "== Removing Marketplace extension entries (extensions are baked into the image)"
"${COMPOSE[@]}" exec -T database psql -U directus -d directus -c \
	"delete from directus_extensions where source = 'registry' returning folder;"

echo "== Done. Start Directus with: docker compose -f docker-compose.dev.yml up -d directus"
