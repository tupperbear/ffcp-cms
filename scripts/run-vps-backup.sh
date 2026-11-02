#!/usr/bin/env bash
# Back up the old production CMS on the VPS (read-only; one sudo prompt there).
# Usage (from the cms repo, run by the owner): scripts/run-vps-backup.sh
# Prints "BACKUP DIR: ~/<VPS_BACKUP_DIR>/<name>"; pass <name> to migrate.sh.
set -euo pipefail
CMS=$(cd "$(dirname "$0")/.." && pwd)
. "$CMS/migration.env"

REMOTE=vps-backup-$FLY_APP.sh
scp -q "$CMS/scripts/vps-backup.sh" "$VPS_SSH:$REMOTE"
ssh -t "$VPS_SSH" "PG_SERVICE=$VPS_PG_SERVICE DB_NAME=$VPS_DB VOLUME_PREFIX=$VPS_VOLUME_PREFIX BACKUP_DIR=$VPS_BACKUP_DIR bash $REMOTE"
