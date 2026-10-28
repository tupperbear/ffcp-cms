#!/usr/bin/env bash
# Read-only backup of the current production CMS on the VPS (Dokploy).
# Run from the cms repo:
#   scp scripts/vps-backup.sh netcup:ffcp-vps-backup.sh && ssh -t netcup 'bash ffcp-vps-backup.sh'
#
# Writes ~/ffcp-backup/<date-time>/{directus.dump,volumes.tar,SHA256SUMS} on the
# VPS (private to the user). Doesn't stop or change Directus or Postgres.
set -euo pipefail
umask 077

PG_SERVICE=ffcp-cms-postgres-qylwxv
VOLUME_PREFIX=ffcp-cms-directus-qrsqmy
B=~/ffcp-backup/$(date +%Y%m%d-%H%M)

sudo -v
C=$(sudo docker ps -q -f "name=$PG_SERVICE")
[ -n "$C" ] || { echo "Postgres container $PG_SERVICE not found" >&2; exit 1; }
mkdir -p "$B"

echo "== Dumping database"
sudo docker exec "$C" sh -c 'pg_dump -U "$POSTGRES_USER" -d directus -Fc' >"$B/directus.dump"

echo "== Archiving uploads, extensions and templates"
sudo tar -C /var/lib/docker/volumes -cf - \
	"${VOLUME_PREFIX}_directus_uploads/_data" \
	"${VOLUME_PREFIX}_directus_extensions/_data" \
	"${VOLUME_PREFIX}_directus_templates/_data" >"$B/volumes.tar"

cd "$B" && sha256sum directus.dump volumes.tar >SHA256SUMS
ls -la "$B"
echo "BACKUP DIR: $B"
