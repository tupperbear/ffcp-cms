#!/usr/bin/env bash
# Nightly backup of the Directus database and files into the snapshots bucket.
# Needs pg_dump/pg_restore (matching the Neon major version) and rclone.
#
# Layout in $BACKUP_R2_BUCKET:
#   <env>/db/daily/directus-<timestamp>.dump     (lifecycle: 35 days)
#   <env>/db/monthly/directus-<timestamp>.dump   (1st of the month; 365 days)
#   <env>/files/<filename_disk>                  (copy only: never deletes)
#   <env>/replaced/<date>/<filename_disk>        (versions overwritten in files/)
#
# Env: BACKUP_ENV (test|prod), DB_CONNECTION_STRING, R2_ENDPOINT,
#      ASSETS_R2_KEY/SECRET (read-only on the assets bucket), ASSETS_R2_BUCKET,
#      BACKUP_R2_KEY/SECRET (read/write on the snapshots bucket), BACKUP_R2_BUCKET
set -euo pipefail

: "${BACKUP_ENV:?}" "${DB_CONNECTION_STRING:?}" "${R2_ENDPOINT:?}"
: "${ASSETS_R2_KEY:?}" "${ASSETS_R2_SECRET:?}" "${ASSETS_R2_BUCKET:?}"
: "${BACKUP_R2_KEY:?}" "${BACKUP_R2_SECRET:?}" "${BACKUP_R2_BUCKET:?}"

# Two rclone remotes, one per token
export RCLONE_CONFIG_ASSETS_TYPE=s3 RCLONE_CONFIG_ASSETS_PROVIDER=Cloudflare
export RCLONE_CONFIG_ASSETS_ENDPOINT=$R2_ENDPOINT RCLONE_CONFIG_ASSETS_NO_CHECK_BUCKET=true
export RCLONE_CONFIG_ASSETS_ACCESS_KEY_ID=$ASSETS_R2_KEY RCLONE_CONFIG_ASSETS_SECRET_ACCESS_KEY=$ASSETS_R2_SECRET
export RCLONE_CONFIG_BACKUP_TYPE=s3 RCLONE_CONFIG_BACKUP_PROVIDER=Cloudflare
export RCLONE_CONFIG_BACKUP_ENDPOINT=$R2_ENDPOINT RCLONE_CONFIG_BACKUP_NO_CHECK_BUCKET=true
export RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID=$BACKUP_R2_KEY RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY=$BACKUP_R2_SECRET

STAMP=$(date -u +%Y-%m-%dT%H%MZ)
TODAY=$(date -u +%Y-%m-%d)
DEST="BACKUP:$BACKUP_R2_BUCKET/$BACKUP_ENV"
DUMP=$(mktemp -d)/directus-$STAMP.dump

echo "== Dumping database"
pg_dump "$DB_CONNECTION_STRING" -Fc --no-owner --no-acl -f "$DUMP"
TABLES=$(pg_restore --list "$DUMP" | grep -c ' TABLE DATA ')
echo "dump: $(du -h "$DUMP" | cut -f1), $TABLES tables with data"
[ "$TABLES" -gt 0 ] || { echo "Dump has no table data" >&2; exit 1; }

echo "== Uploading dump"
rclone copyto "$DUMP" "$DEST/db/daily/$(basename "$DUMP")"
if [ "$(date -u +%d)" = "01" ]; then
	rclone copyto "$DUMP" "$DEST/db/monthly/$(basename "$DUMP")"
	echo "monthly copy uploaded"
fi

echo "== Copying files (cached thumbnails skipped; nothing is deleted)"
rclone copy "ASSETS:$ASSETS_R2_BUCKET" "$DEST/files" \
	--exclude '*__*' \
	--backup-dir "$DEST/replaced/$TODAY" \
	--transfers 16 --stats-one-line --stats-log-level NOTICE --stats 0

echo "== Done: $(rclone size "$DEST/files" | tr '\n' ' ')"
