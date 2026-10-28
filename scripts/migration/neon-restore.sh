#!/usr/bin/env bash
# Restore a prod dump into Neon and prepare it for the new CMS.
# Runs inside a postgres:18 container (pg_restore must match Neon's major version).
#
#   docker run --rm --env-file .env.fly.prod \
#     -v <backup-dir>:/b:ro -v <dir with backfill.sql>:/s:ro -v "$PWD/scripts/migration:/scripts:ro" \
#     -e KEEP_FLOWS=0 postgres:18 /scripts/neon-restore.sh
#
# KEEP_FLOWS=1 at cutover (flows stay active); 0 for rehearsals (deactivated, so
# nothing can trigger a real Netlify build).
set -euo pipefail
: "${DB_CONNECTION_STRING:?}"
DB=$DB_CONNECTION_STRING

echo "target endpoint: $(echo "$DB" | sed -E 's#.*@([^.]+)\..*#\1#')"

psql "$DB" -q -v ON_ERROR_STOP=1 -c 'drop schema public cascade' -c 'create schema public' 2>/dev/null
echo "schema emptied"

pg_restore -d "$DB" --no-owner --no-acl --exit-on-error /b/directus.dump
echo "dump restored"

if [ -f /s/backfill.sql ]; then
	psql "$DB" -q -v ON_ERROR_STOP=1 -f /s/backfill.sql
	echo "sort fix applied ($(grep -c '^update' /s/backfill.sql) rows)"
else
	echo "no /s/backfill.sql: sort fix not applied (apply it separately)"
fi

psql "$DB" -q -v ON_ERROR_STOP=1 <<'SQL'
-- Extensions are baked into the image now
delete from directus_extensions where source = 'registry';
-- Files move from the VPS volume to R2
update directus_files set storage = 'r2' where storage = 'local';
SQL
echo "registry rows removed, file storage set to r2"

if [ "${KEEP_FLOWS:-0}" != "1" ]; then
	psql "$DB" -At -v ON_ERROR_STOP=1 -c "update directus_flows set status = 'inactive' where status = 'active' returning 'flow deactivated: ' || name"
fi

psql "$DB" -At <<'SQL'
select 'tables: ' || count(*) from information_schema.tables where table_schema = 'public';
select 'files: ' || count(*) || ' (storage ' || string_agg(distinct storage, ',') || ')' from directus_files;
select 'users: ' || count(*) from directus_users;
select 'flows: ' || string_agg(name || '=' || status, ', ') from directus_flows;
SQL
