-- Media audit, step 1: every reference to a CMS file, from any text, JSON or UUID column.
-- Run against a scratch restore of a production dump (never production itself):
--   docker run -d --name ffcp-audit-db -e POSTGRES_PASSWORD=audit -e POSTGRES_USER=directus \
--     -e POSTGRES_DB=directus -v "$PWD/<backup>/directus.dump:/dump/directus.dump:ro" postgres:15.19
--   docker exec ffcp-audit-db pg_restore -U directus -d directus --no-owner --no-acl /dump/directus.dump
--   docker exec -i ffcp-audit-db psql -U directus < scripts/media-audit/find-refs.sql
-- Covers file fields (FKs), rich text, Markdown, the SEO field ("<id>.jpg"), video blocks
-- (id as a string), button links. History tables are left out.
drop table if exists audit_refs;
create table audit_refs (file_id uuid, tbl text, col text, row_id text);
do $$
declare r record; pk text;
begin
  for r in
    select c.table_name, c.column_name from information_schema.columns c
    join information_schema.tables t on t.table_name=c.table_name and t.table_schema=c.table_schema and t.table_type='BASE TABLE'
    where c.table_schema='public'
      and c.data_type in ('text','character varying','json','jsonb','uuid')
      and c.table_name not in ('directus_files','directus_revisions','directus_activity','directus_versions',
                               'directus_sessions','directus_migrations','audit_refs','audit_build')
  loop
    select a.attname into pk from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum=any(i.indkey)
      where i.indrelid=('public.'||quote_ident(r.table_name))::regclass and i.indisprimary limit 1;
    execute format($q$
      insert into audit_refs
      select distinct m[1]::uuid, %L, %L, %s::text
      from %I t, regexp_matches(t.%I::text, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', 'gi') m
      where m[1]::uuid in (select id from directus_files)$q$,
      r.table_name, r.column_name, coalesce(quote_ident(pk), 'null'), r.table_name, r.column_name);
  end loop;
end $$;
select tbl, col, count(distinct file_id) files from audit_refs group by 1,2 order by 3 desc;

-- Step 2: the file ids in a static site build (ground truth for "live"). From the repo root:
--   B=.migration/baselines/<build>; { ls $B/_astro | grep -oE '^[0-9a-f-]{36}'; ls $B/downloads;
--     grep -rhoE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' $B --include='*.html'; } | sort -u > build-ids.txt
--   docker cp build-ids.txt ffcp-audit-db:/tmp/build-ids.txt
-- then in psql:
--   drop table if exists audit_build; create table audit_build (id text);
--   \copy audit_build from '/tmp/build-ids.txt'
-- Step 3: scripts/media-audit/classify.py (follows each reference to its page or post).
