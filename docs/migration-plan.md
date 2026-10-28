# FFCP CMS Migration Plan

Migrate the FFCP Directus CMS off the self-managed VPS (Dokploy) onto **Fly.io + Neon Postgres + Cloudflare R2**, upgrading from Directus **11.5.1** to the latest release along the way.

> **Where things live** (moved here from a separate `cms-migration` folder on 2026-10-28): paths below are relative to this repo, and `../site` is the website repo checked out next to it. Scripts kept after the migration are in `scripts/`; one-time migration scripts are in `scripts/migration/` (delete them after decommissioning the VPS). Working files (production backups, site builds, rehearsal logs) are in **`.migration/`**, which is gitignored and private: it contains production dumps, so never commit it.

**Goals**

1. Set up a local development copy of the CMS.
2. Use it to upgrade to the latest Directus version, working through the issues that blocked past attempts.
3. Stand up a test version on Fly.io / Neon / R2.
4. Migrate all production data into the new, fully upgraded environment and cut over.

_Created 2026-10-24._

---

## Current state (findings)

### Production CMS (this repo)

- Directus **11.5.1** on Dokploy (`docker-compose.yml`), joined to the external `dokploy-network`.
- **Postgres 15**, on the same VPS, managed by Dokploy, connected via `DATABASE_URL`.
- Files and extensions on **local Docker volumes** (`directus_uploads`, `directus_extensions`, `directus_templates`). R2 for files was tried several times and is currently commented out.
- `CACHE_STORE: memory`, `WEBSOCKETS_ENABLED: true`, `ASSETS_TRANSFORM_IMAGE_MAX_DIMENSION: 12000`, SMTP via Proton.
- CSP allows the Netlify preview site, YouTube/Vimeo and Plyr. CORS allows `http://localhost:4321`.
- `schema/schema.json` is a 11.5.1 snapshot (Postgres vendor).
- The local clone was 2 commits behind `origin/main` (fast-forwarded 2026-10-27). Those commits added `FILES_MAX_UPLOAD_SIZE: 50mb` and `EXTENSIONS_REDUCE_ON_UPLOAD_QUALITY: 80` / `_MAXSIZE: 2000`. These belong to `directus-extension-image-upload-resizer` (see table).
- All secrets in both compose files are `${...}` env references. The one exception, a literal `ADMIN_PASSWORD` in `docker-compose.local.yml`, was replaced with an env reference on 2026-10-27, but it **remains in git history**.

### Extensions (from the March 2025 backup in `../rsync-backup/extensions/.registry`)

| Extension | Version | Declared host | Notes |
|---|---|---|---|
| `@directus-labs/super-header-interface` | 1.1.1 | `^10.0.0 \|\| ^11.0.0` | Used by 28 fields |
| `directus-extension-sane-image-size` | 1.1.9 | `^10.10.0` | Hook. In the March 2025 backup, but **not in prod's current list**. Probably replaced by the image-upload-resizer |
| `directus-extension-generate-types` | 0.6.1 | `^9.0.0-rc.95` | Installed but **disabled** on prod. Drop it |
| `@directus-labs/video-player-interface` | ? | ? | On prod, not in the March 2025 backup |
| `directus-extension-image-upload-resizer` | ? | ? | On prod. Configured by the `EXTENSIONS_REDUCE_ON_UPLOAD_*` env vars (Apr 2026). It already resizes on the server, so it covers part of Phase 5's goal |

All installed from the Marketplace at runtime (`MARKETPLACE_TRUST: all`). Production's extension list was confirmed by the owner on 2026-10-27.

**Prod inventory (2026-10-27).** Directus `ffcp-cms-directus-qrsqmy-directus-1`; Postgres 15.19 `ffcp-cms-postgres-qylwxv` (Swarm service), DB `directus` 28 MB. Uploads: 722 MB, 747 files. The server is aarch64. Two other CMSes (`aff-cms`, `atfs-cms`) share the server; touch only `ffcp-cms-*`. The `ffcp-cms-testpg-qwowty-data` volume is unused.

- ⚠️ **Collation version mismatch** (glibc 2.36 → 2.41) on the `directus` and `postgres` DBs. This risks text-index corruption. A logical dump/restore into Neon resolves it.
- **Where extensions really live (solved).** `EXTENSIONS_LOCATION=local` names the **storage location** `local`, which is `/directus/uploads`, not the extensions folder. Directus keeps extensions under `uploads/extensions/.registry/` and syncs them into `/directus/node_modules/.directus/extensions/` on startup. Video-player (`b3e8260a…`) and image-upload-resizer (`fb3357c0…`) are there, so they are included in the uploads volume backup. `/directus/extensions/.registry/c10c01cd…` (super-header) is a leftover from before this setting. This split setup is a likely cause of past upgrade trouble.
  - **Implications:** when syncing uploads to R2, **exclude `extensions/`**. On Fly, bake extensions into the image and **unset `EXTENSIONS_LOCATION`**.
- **Installed versions** (from the backup): super-header 1.1.1, video-player 1.0.1, **image-upload-resizer 1.2.1 (declares `<=11.12.0`), so it must be upgraded to 2.x for 12**, generate-types 0.6.1 (disabled).
- Latest registry versions and their declared host versions: super-header 1.2.0 `^10 || ^11` (**not 12**); video-player 1.0.1 `^10.10.0`; image-upload-resizer 2.3.0 `>=9 <=12.3`.

**Past upgrade failures** were most likely caused by an extension conflict or error (exact versions not recorded). Phase 2 should therefore upgrade with **all extensions removed first**, then add them back one at a time.

### Schema

55 collections, 522 fields, 127 relations. One M2A field (blocks), no geometry fields. Should migrate cleanly.

### Website (`../site`)

- Astro 5 on Netlify; static build, plus an SSR preview build (`IS_PREVIEW`) shown in the Directus live-preview iframe.
- `@directus/sdk` v19 with a static token (`DIRECTUS_STATIC_TOKEN`).
- Redirects are loaded from the CMS `redirects` collection at build time.
- Assets served from `DIRECTUS_ASSETS_URL/assets/<id>`.
- Image domains include `ffcp-cms.tupp.dev`, `cdn.tupp.dev`, `cms.familyforestcarbon.org`, `assets.familyforestcarbon.org`.

### Earlier attempts and backups (sibling folders)

- `../cms-fly` — Fly with SQLite on a volume, `directus:latest`.
- `../cms-dokku`, `../cms-old` — earlier hosting attempts.
- `../r2-clone` (2.3 GB) and `../rsync-backup` (1.3 GB uploads) — copies from March 2025, **out of date**.
- `../import` — Contentful → Directus import tool.

### ⚠️ Security

`docker-compose.local.yml` had a plaintext `ADMIN_PASSWORD` (for `admin@example.com`) committed in the initial commit `3a5f12d` (2025-03-20). It was removed from the file on 2026-10-27, but it remains in git history. The repo is private. Directus only uses this value to create the first admin on an empty database, and prod never used it. **This matters only if the same password is reused elsewhere** (prod admin account, other CMSes, other services).

### Directus versions

Latest is **12.5.1** (as of 2026-10-27, 46 releases ahead of 11.5.1). Upgrading means going through 11.6–11.16 and the 12.0 major release. Directus does not follow semver, so any release may contain breaking changes.

---

## Phase 0 – Inventory and fresh backups (read-only on prod)

- [x] On the VPS, take a fresh `pg_dump -Fc` of production. Done 2026-10-27, stored in `.migration/backups/20261027-1418/` (checksums verified locally; also kept on the server in `~/ffcp-backup/`).
- [ ] Take a schema snapshot from the restored local copy in Phase 1, not from prod.
- [x] Copy the uploads, extensions and templates volumes. Done as `volumes.tar`: 734 upload files plus 4 extensions under `uploads/extensions/.registry/`.
- [x] Check the dump with `pg_restore --list`: 80 tables (27 `directus_*`, 53 content), 503 TOC entries, pg_dump 15.19.
- [ ] Record what prod really runs:
  - [ ] Extensions in the `directus_extensions` table and on the volume (owner list received; confirm versions)
  - [x] Postgres major version: 15
  - [ ] Database size
  - [ ] Flows / webhooks (e.g. Netlify build hooks)
  - [ ] Roles / policies
  - [ ] The static token's user
  - [ ] Full env var list
- [ ] Tidy the repo:
  - [x] Pull the 2 missing commits
  - [x] Add `.env.example`; README points to it
  - [x] Remove the hard-coded admin password from `docker-compose.local.yml`
  - [x] Old local admin password isn't reused anywhere (owner confirmed 2026-10-27). No change needed
  - [ ] Add a `scripts/` folder (dump, restore, reset, file sync)
  - [ ] Archive `cms-fly`, `cms-dokku`, `cms-old` once nothing in them is needed

## Phase 1 – Local copy that matches prod exactly (11.5.1)

- [x] Add `docker-compose.dev.yml` with:
  - Postgres on the same major version as prod
  - `directus/directus:11.5.1`, pinned
  - Optionally MinIO, to test the S3/R2 driver locally before touching real R2
- [x] Restore the dump and files with `scripts/dev-restore.sh <backup-dir>`. It deactivates all flows before Directus starts; the only flow is "Deploy Website" (manual trigger). The restore works: 4 extensions loaded, 283 files, all present on disk, and image transforms work. There is also an orphan empty registry folder `8b19392b…` (a failed install from Mar 2025), harmless.
- [x] Check: admin UI, editing, uploads, extensions (owner confirmed 2026-10-27); image transforms (automated). Live preview not yet tested.
- [x] **Baseline for comparison:** `.migration/baselines/site-11.5.1/` (54 pages, 59 optimized images, built 2026-10-27 from the local CMS only).
  - Build: `scripts/build-site.sh <name>`. It points the site at `localhost:8055` via a temporary `.env.production.local`, because `astro.config` merges `.env` over the shell env. The Netlify adapter always writes to `../site/dist`, which gets replaced.
  - Compare: `python3 -I scripts/compare-site.py .migration/baselines/site-11.5.1 .migration/baselines/<name>`. It ignores `pagefind/` and per-build random UUIDs (breadcrumbs, video sections), but still compares `/assets/<id>` links. Two identical builds show 0 differences.
- [x] Save a "known-good 11.5.1" dump: `.migration/backups/local-11.5.1-baseline.dump`.

## Phase 2 – Upgrade to the latest version locally

- [x] **Try the jump straight to 12.x first** (2026-10-27): **11.5.1 → 12.5.1 worked first time.**
  - All 27 migrations ran in ~1.5 s with no errors; all 4 extensions loaded; the Studio bundle still has Video and Super Header; image transforms work.
  - **Site build against 12.5.1: 0 differences** from the 11.5.1 baseline (`.migration/baselines/site-12.5.1/`), with `@directus/sdk` v19 unchanged.
  - **`/server/health` now returns 403 without auth.** Use **`/server/ping`** (200 `pong`) for the Fly health check.
  - `SECRET` must be ≥ 32 bytes (warning).
  - Past failures were therefore probably environmental (the split extension locations), not migrations.
- **Decision (2026-10-27): target the last 11.x release, 11.17.4 (2026-04-30), not 12.x.** The owner considers 12.x's licence terms too vague. The local copy has been reset to 11.5.1 from the prod backup.
  - Risk: 11.x has had **no releases since 2026-04-30** (12.0 came out 2026-06-12), so expect no further security fixes. Revisit 12.x (or alternatives) later.
- [x] Trial 11.5.1 → 11.17.4 (2026-10-27):
  - Migrations ran cleanly (Visual Editor through Deployment Webhooks); all 4 extensions loaded; the Studio bundle and image transforms are OK; `/server/health` is still public in 11.x.
  - **No licence key in 11.x**, but there is a one-time **"project owner" form**. Submitting it POSTs the owner email, org name, usage and `project_id` to Directus's `COMPLIANCE_URL` (`/v1/owner`), **even with `TELEMETRY=false`**. It can be pre-filled with the `PROJECT_OWNER` env var.
  - **Ordering bug found (pre-existing data issue):** 14 sortable lists have null or duplicate `sort` values (e.g. 83 page blocks across 17 pages). Their order is whatever Postgres returns for the exact query, and **11.17.4 returned 4 pages' accordions/blocks in a different order**.
  - **Fix: `scripts/migration/backfill-sort.py`.** On 11.5.1 it replays the site's own requests (`scripts/migration/site-requests.txt`) and writes each list's current position into its sort field (437 rows). Result: **0 differences on 11.5.1 and 0 differences on 11.17.4** vs the baseline.
  - `.migration/backups/local-11.5.1-sorted.dump` = baseline with the backfill applied.
- [x] Studio checks on 11.17.4 (owner confirmed 2026-10-27): editing, Super Header, Video, upload resizing, FAQ order. The project-owner form can be dismissed; it was left for the production cutover.
- [x] **Live preview on 11.17.4 works** (owner confirmed 2026-10-27), including the automatic reload on save. The site doesn't use `@directus/visual-editing`, so the 11.16 breaking change doesn't affect it.
  - Locally, set the `pages` preview URL to `http://localhost:4321{{permalink}}/` (Astro dev doesn't redirect a missing trailing slash; Netlify does with a 301), then **restart Directus**, because collection settings are cached in memory.
- [ ] ~~**Licence key (blocker for 12.x).**~~ Not pursued; kept for reference.** On first login, the 12.x Studio asks for a licence key. The free Core tier allows 25 collections, 3 Studio seats and 5 flows; FFCP has **53 collections and 10 Studio users** (plus 1 API-only user, which doesn't count). Over the limit, Directus gives a grace period, then **blocks `/items`, GraphQL and WebSockets, and non-admin logins** (no data is deleted).
  - Owner applies for the **Open Innovation Grant** (free; under $5M revenue and under 50 employees; up to 5 activations): https://directus.com/oig
  - Apply via the `LICENSE_KEY` env var (or Settings → License). Requires an absolute `PUBLIC_URL`. Don't set `LICENSE_TOKEN` as well.
  - **Never cut over to 12.x without the key in place.** The site build would break once the grace period ends.
- [ ] ~~If that fails, step through versions~~ Not needed. For reference: 11.6 → 11.8 → 11.10 → 11.12 → 11.14 → 11.16 → 12.0 → 12.x. Dump after each step that works, isolate the failing migration or data problem, fix just that.
- [ ] Go through the [breaking changes list](https://directus.io/docs/releases/breaking-changes) item by item. Already known to be relevant:
  - **12.0:** `IP_TRUST_PROXY` now defaults to `false`. Behind Fly's proxy it must be set to `true`.
  - **12.0:** licence changed from BUSL-1.1 to MSCL-1.0-GPL (see Questions).
  - **11.16:** versions/drafts handling changed; `@directus/visual-editing` must be v2.
  - **12.1:** hash util endpoints removed; GraphQL mutations tightened.
- [x] **Extensions baked into the image** (`Dockerfile`, 2026-10-27): `FROM directus/directus:11.17.4`, then `pnpm install` of super-header-interface **1.2.0**, video-player-interface **1.0.1** and image-upload-resizer **2.3.0**. generate-types was dropped. No extensions volume, no `EXTENSIONS_LOCATION`, no Marketplace.
  - **Resizer 2.x renamed its env vars and defaults to AVIF.** To keep today's behaviour (WebP, quality 80, ≤ 2000px), set `EXTENSIONS_IMAGE_UPLOAD_RESIZER_FORMAT=webp`, `..._QUALITY_WEBP=80` and `..._MAXSIZE=2000`. The old `EXTENSIONS_REDUCE_ON_UPLOAD_*` vars are dead. 2.x strips EXIF/GPS by default (1.2.1 kept it), which is accepted as a privacy improvement.
  - Owner confirmed super-header 1.2.0 in the Studio. Committed as `fdd723a` (branch `chore/env-cleanup`).
  - Tested: a 4000×3000 JPEG upload is stored as a 2000×1500 WebP; the Studio bundle has Video and Super Header; the site matches the baseline (the only differences are the owner's test edits).
  - **Migration step:** `delete from directus_extensions where source = 'registry';` removes the stale Marketplace rows (now done by `dev-restore.sh`). On R2, the `uploads/extensions/` folder is not needed.
- [ ] **Site:** upgrade `@directus/sdk` if needed, rebuild, diff against the baseline, test live preview.
- [ ] Commit the upgraded schema snapshot to the repo.

## Phase 3 – Test environment on Fly, Neon and R2

**Progress (2026-10-27)**
- [x] Fly app `ffcp-cms-test` created by the owner (org `personal`). `fly.toml` written: `iad`, suspend when idle, `/server/ping` check, 1 GB, Neon-friendly pool (`DB_POOL__MIN=0`, idle timeout 60 s).
- [x] Credentials in `.env.fly` (gitignored, `chmod 600`, plain `KEY=value` lines for `fly secrets import`). `SECRET` was generated (64 chars). The R2 endpoint must **not** include the bucket path (Cloudflare shows it with one).
- [x] Neon reachable: direct (non-pooler) endpoint in `us-east-1`, database `neondb`, empty.
- [x] R2 bucket `ffcp-cms-assets`: private; the scoped token can read, write and delete.
- [x] **Neon runs PostgreSQL 18.6** (its default), not 15. Tested locally: a PG15 dump restored into PG18 (with the PG18 `pg_restore`), plus the sort backfill and 11.17.4 migrations, gives a site with **0 differences** vs the baseline. Keep PG18 and use a `postgres:18` client for restores.
- [x] **Test environment deployed (2026-10-28)** at https://ffcp-cms-test.fly.dev:
  1. Prod backup restored into Neon (`postgres:18` `pg_restore --no-owner --no-acl`): 80 tables, 283 files, 11 users. Then: sort backfill (437 rows), flows off, registry rows removed, `directus_files.storage` set to `r2`.
  2. The 283 original files (692 MB) were copied to R2 with `rclone --files-from <filename_disk list>`, so no `extensions/` and no cached thumbnails. `rclone check`: 0 differences.
  3. `fly secrets import --stage < .env.fly`, then `fly deploy`. Migrations ran on Neon; 3 extensions loaded; `/server/health` OK. Warm timings: health ~0.35 s, image ~0.55 s; first requests 2–3 s (cold start).
  - The first startup with migrations exceeded the 30 s health-check grace, so it was raised to 60 s (redeployed 2026-10-28; check passing). `/server/health` reports `warn` for a few seconds after a cold start, then `ok`.
  - **Custom domain `https://ffcp-cms-test.tupp.dev`**: a DNS-only CNAME to `ffcp-cms-test.fly.dev`. Fly's default validation stalled ("Issuing…" for 7+ min), so we added `_acme-challenge` CNAME → `ffcp-cms-test.tupp.dev.02kljxp.flydns.net` and TXT `_fly-ownership` = `app-02kljxp`; the cert was issued within ~10 s. **Do the same for the production domain**, ideally adding these records before the cutover so the cert is ready in advance.
  - **Site built from Fly + Neon + R2: 0 differences** vs the 11.5.1 baseline. The build went through a localhost Caddy proxy to Fly, because the site's `image.domains` doesn't include the test host.
  - [x] **Test preview site (2026-10-28).** A separate Netlify site, **`ffcp-website-preview-test.netlify.app`** (same repo, `IS_PREVIEW=true`, CMS URLs → `https://ffcp-cms-test.tupp.dev`), so production editors' previews on `ffcp-website-preview` are untouched.
    - `../site`: `ffcp-cms-test.tupp.dev` added to `image.domains` (`e0cee38`, pushed). On Netlify, images go through the Netlify Image CDN (`/.netlify/images?url=…`); verified 200 WebP from the test CMS.
    - `fly.toml`: preview-test site added to `FRAME_SRC`; redeployed.
    - Test CMS `pages.preview_url` = `https://ffcp-website-preview-test.netlify.app{{permalink}}` (set in Neon; the redeploy restarted Directus, which clears the cached setting).
    - Owner tested live preview from the test Studio (2026-10-28): it loads and reloads on save.
    - **At cutover:** point the original `ffcp-website-preview` site at the new production CMS, then delete `ffcp-website-preview-test`.

- [ ] **Stateless container:**
  - `Dockerfile` based on a pinned `directus/directus:12.x`
  - **Extensions copied into the image** instead of Marketplace installs onto a volume
  - Database in Neon, files in R2 → **no Fly volume at all**
- [ ] **Fly:**
  - One machine, `auto_stop_machines = 'suspend'`
  - ~1–2 GB RAM (the 12000px transform limit needs memory for `sharp`)
  - Health check on `/server/health`
  - In-memory cache is fine for one machine; more than one would need Redis for cache and websockets
- [ ] **Neon:**
  - Same region as Fly (e.g. AWS us-east-1 ↔ Fly `iad`)
  - Use the **direct** (non-pooled) connection string for Directus, at least while migrations run
  - Use **Neon branches** for rehearsals: restore prod into `main`, branch into `test`, discard freely
- [ ] **R2:**
  - Assets bucket via `STORAGE_LOCATIONS`, `s3` driver, region `auto`, R2 endpoint
  - ~~Optionally Cloudflare caching in front of the assets domain~~ Skipped; see Phase 5
- [ ] Set secrets with `fly secrets`.
- [ ] Update CSP/CORS for the new domains.
- [x] Netlify preview → test CMS (see below).
- [ ] **Backups** (decided 2026-10-28). Neon free has only a 6 h restore window, 1 manual snapshot and no scheduled backups; R2 deletes are immediate.
  - A separate bucket **`ffcp-cms-snapshots`** (`ffcp-cms-backups` already exists: it's the current production CMS's; **leave it untouched** until after decommissioning) with its **own** token (R/W on `ffcp-cms-snapshots`, read-only on `ffcp-cms-assets`). **Environment prefixes** `test/` and `prod/`, with lifecycle rules and the lock set per prefix.
  - **GitHub Actions** nightly job in `ffcp-cms` (failure emails; independent of Fly). Secrets go in GitHub.
  - DB: `pg_dump -Fc` → `<env>/db/daily/` (kept 35 days, via lifecycle rule); on the 1st of the month also → `<env>/db/monthly/` (kept 365 days). **Bucket lock on `<env>/db/`** (e.g. 30 days).
  - Files: nightly `rclone copy` (never deletes) of originals → `<env>/files/`, so files deleted in Directus are kept in the backup. Overwritten files (Directus "Replace file") are moved to `<env>/replaced/<date>/` with `--backup-dir`. Cached thumbnails (`*__*`) are skipped.
  - No copy outside Cloudflare: **risk accepted by owner**.
  - Restore test every few months into a Neon branch.
  - [x] Two R2 tokens (owner, 2026-10-28): **read-only on `ffcp-cms-assets`** and **read/write on `ffcp-cms-snapshots`**. Keys are in `.env.backup` (gitignored, 600), kept out of `.env.fly` so `fly secrets import` never pushes them to the CMS. Permissions verified: 7/7 allow/deny checks as intended.
  - [x] `scripts/backup.sh` + `.github/workflows/backup.yml` (07:17 UTC nightly + manual run; `postgres:18` container; **rclone pinned to v1.68.2**). Debian's rclone 1.60 fails R2-to-R2 copies with `501 NotImplemented`, and env vars named `RCLONE_*` are read as rclone flags. Tested locally: 2.2 MB dump (82 tables) + 285 files, ~27 s.
  - [x] Owner: lifecycle rules (`test/db/daily/` 35 d, `test/db/monthly/` 365 d) + bucket lock (`test/db/`, 30 d) set in the R2 dashboard. **Add the same for `prod/` at cutover.**
  - [x] Owner: GitHub secrets added. `chore/env-cleanup` fast-forwarded into `main` and pushed (`93566c1..d74d4b4`, 2026-10-28). Dokploy doesn't auto-deploy on push (owner confirmed).
  - [x] First manual run from GitHub succeeded (2026-10-28, dump `test/db/daily/directus-2026-10-28T1341Z.dump`). Its annotations led to `actions/checkout@v5` (Node 24, pushed as `3ed2844`). The `ubuntu-latest` → Ubuntu 26 notice is harmless because the job runs in the `postgres:18` container.
  - [x] **Restore test passed (2026-10-28): 0 differences** vs the baseline. Runbook:
    1. Neon API (project-scoped key in `.env.neon`): `POST /projects/<id>/branches` `{"branch":{"name":"restore-test"},"endpoints":[{"type":"read_write"}]}`, then `GET /connection_uri?...&pooled=false` (the API returns the pooler URI by default).
    2. On the branch: `drop schema public cascade; create schema public;`, then `pg_restore --no-owner --no-acl` of the newest `<env>/db/daily/` dump (`postgres:18` client).
    3. Download `<env>/files/` and run the image with `STORAGE_LOCATIONS=r2`, `STORAGE_R2_DRIVER=local`, `STORAGE_R2_ROOT=<files dir>` (no DB change needed). Use the entrypoint `node cli.js bootstrap && exec pm2-runtime start ecosystem.config.cjs` (no `exec` before bootstrap).
    4. `scripts/build-site.sh restore-test` + `compare-site.py`, then delete the branch, container and downloads.
  - [ ] Repeat the restore test every few months.
  - [ ] At cutover: set `BACKUP_ENV: prod` in the workflow and update the `DB_CONNECTION_STRING` secret if the prod database differs.

## Phase 4 – Data migration rehearsal, then cutover

**Decisions (2026-10-28)**
- **New Fly app `ffcp-cms` for production**; `ffcp-cms-test` is deleted after cutover. Same Neon project (`ffcp-db`) and R2 bucket (`ffcp-cms-assets`), restored fresh.
- **Email**: prod secrets in `.env.fly.prod` (gitignored, 600), using Directus's names (`EMAIL_SMTP_HOST/PORT/USER/PASSWORD`, `EMAIL_FROM`; the compose file's `EMAIL_HOST` etc. were only aliases). `EMAIL_TRANSPORT=smtp` goes in the prod `fly.toml`. The test app's `.env.fly` has no email settings.
- **New `SECRET`** for production (generated into `.env.fly.prod`). Editors log in again once after cutover.
- **DNS for `familyforestcarbon.org` is run by another party.** Coordinate early: lower the TTL (currently **14400 s = 4 h** on `cms`/`assets`, both → VPS `152.53.241.119`), add `_acme-challenge` + `_fly-ownership` records ahead of time, then switch the records at cutover.
- **`assets.familyforestcarbon.org` to be retired** (owner), once downloads are served from Netlify. The live site currently links **all PDF/MP4 downloads to `assets.familyforestcarbon.org/assets/<id>`** (e.g. 13 on `/forester-training-resources/`).
- **Netlify downloads change (Phase 5) moves ahead of cutover**, then **`assets.familyforestcarbon.org` is retired at cutover** (owner, 2026-10-28): it is not kept as a transition alias. Old external links to `assets.…/assets/<id>` will stop working; risk accepted.
- **VPS step**: the owner runs one command, `scp scripts/vps-backup.sh netcup:ffcp-vps-backup.sh && ssh -t netcup 'bash ffcp-vps-backup.sh'` (one sudo prompt, read-only on prod). I download the result with rsync (no sudo).
- Rehearse now, **on the real production targets** (new `ffcp-cms` app, Neon `production` branch, assets bucket; no DNS change). **Stop `ffcp-cms-test` when the rehearsal starts** (owner approved).

- [ ] **Scripted migration path:**
  1. Dump prod (11.5.1)
  2. Restore into Neon
  3. **Sort fix from the production API** (during the content freeze, so the order and the dump agree): `DIRECTUS_TOKEN=<site token> scripts/migration/backfill-sort.py https://cms.familyforestcarbon.org relations.json scripts/migration/site-requests.txt`, then apply the SQL to the restored copy.
  4. Start upgraded Directus (runs the migrations)
  5. `rclone` uploads from the VPS to R2
  6. `UPDATE directus_files SET storage = '<r2 location>'`
  7. Transformed thumbnails don't need copying — they're regenerated
- [x] **Rehearsal 1 (2026-10-28), on the real production targets**: VPS backup `20261028-1740` → new Fly app **`ffcp-cms`** (https://ffcp-cms.fly.dev), Neon `production` branch, R2 `ffcp-cms-assets`. **Site build: 0 differences** vs a fresh baseline from the same backup. **Machine time ≈ 5 min** (+ ~1 min VPS command). Timings are in `.migration/rehearsal/timing.log`.
  - `ffcp-cms-test` scaled to 0 (app kept; `fly deploy` brings it back).
  - **Finding: the "unsorted" order differs between restores of the same version.** Yesterday's restore had a different order on 4 pages; **today's matched the live site**. → Runbook step: compare the fresh baseline's order with the live site before applying the sort fix. After the fix, order is explicit and stable.
  - Pitfalls hit: the temporary 11.5.1 container needs `.dev/uploads` mounted, or the site build fails on images; nested shell quoting → moved to `scripts/migration/neon-restore.sh` (`KEEP_FLOWS=1` at cutover).
  - No SMTP warnings at startup (Directus verifies the connection).
  - [x] Owner: Studio checklist on https://ffcp-cms.fly.dev passed (2026-10-28). Live preview shows the old CMS until the DNS switch, which is expected (see cutover step 3).
  - **Finding 2: restores never reproduce production's order reliably.** Today's restore also disagreed with the live site on 3 pages (page-block order). **New method: read the order from the production CMS's API** (`backfill-sort.py https://cms.familyforestcarbon.org …` with the site token; read-only, the same requests as a site build). Production's order matched the live site on **all 53 pages** (`scripts/check-live-order.py`). It was applied on Neon; the rehearsal app's site build then had 0 differences vs the production-order baseline (apart from the owner's test edit). The local 11.5.1 step is no longer needed.
  - [x] **Runbook script `scripts/migration/migrate.sh <backup> [rehearsal|cutover]`** (2026-10-28). Steps: preflight → download + verify → extract uploads → **reference build from the production CMS** → Neon restore (`neon-restore.sh`) → **sort fix from the production API** → R2 sync → deploy `ffcp-cms` (`-e PUBLIC_URL=…` by mode) → **verify**: new-CMS build vs production build (`compare-site.py`) + order vs live site (`check-live-order.py`). It asks before wiping Neon and before deploying (`CONFIRM=0` skips the prompts). Timings go to `.migration/rehearsal/<backup>.log`.
  - **Rehearsal 3 (script, 2026-10-28): 0 differences vs production, 0 reordered pages of 53, ~3.5 min** end to end.
  - Pitfall fixed: **Astro's content store (`node_modules/.astro/data-store.json`) carried content over between builds against different CMSes**, so a reference build showed the rehearsal app's test edit. `build-site.sh` now deletes it before every build. Earlier comparisons were consistent with fresh fetches, but treat any pre-fix result with that in mind.
- [ ] **Cutover:**
  1. Content freeze
  2. Final dump and file sync
  3. DNS switch: `cms.familyforestcarbon.org` → `ffcp-cms` (certificate records added beforehand). `assets.familyforestcarbon.org` is retired.
     - In Netlify, set `DIRECTUS_ASSETS_URL=https://cms.familyforestcarbon.org` on **both the live site and `ffcp-website-preview`** (the Netlify downloads change must already be live). The preview site keeps `DIRECTUS_API_URL=https://cms.familyforestcarbon.org`, so live preview follows the DNS switch automatically. During the rehearsal, previews from `ffcp-cms.fly.dev` show the old CMS, which is expected.
  4. Fill in the one-time "project owner" form in the Studio (or set `PROJECT_OWNER`). It sends the owner email and org to Directus.
  5. Rebuild the site
- [ ] Keep the same `SECRET` and the static token's user so the site keeps working without config changes.
- [ ] Keep the VPS running read-only for ~2 weeks as rollback, then decommission it.

## Phase 5 – After the migration

### Resize images in the browser before upload

Shrink images in the Data Studio before they're uploaded, instead of resizing them on the server.

- [ ] Scaffold a custom **interface extension**: `npx create-directus-extension@latest`, then choose "interface".
- [ ] In the Vue component, resize the picked file with [`browser-image-compression`](https://www.npmjs.com/package/browser-image-compression) (e.g. `maxWidthOrHeight: 2000`, `maxSizeMB: 1`). Then upload it with `useApi().post('/files', formData)` and emit the new file id.
- [ ] Set image fields (M2O to `directus_files`) to use the new interface.
- [ ] Bake the extension into the Docker image, alongside the other extensions.
- [ ] Set `FILES_MAX_UPLOAD_SIZE` (e.g. `5mb`) as a server-side backstop, because the browser resize can be bypassed through the API.
- [ ] Decide whether `sane-image-size` is still needed or can be removed.
- [ ] Decide whether to lower `ASSETS_TRANSFORM_IMAGE_MAX_DIMENSION` (currently 12000) to reduce Fly's memory needs.
- **Limitation:** this only applies to fields that use the interface. Uploads made directly in the File Library still send the original file.

### Serve PDFs and videos from Netlify instead of the CMS

Images are already copied into the static build (63 in `/_astro/`), but 10 of the 54 pages link straight to the CMS for **24 PDFs (51 MB) and 4 MP4s (31 MB)**. Visitors downloading them wake the Fly machine (2–3 s when it's idle).

- [ ] Add an Astro integration to `../site` (static builds only; preview builds keep CMS links) that, after the build:
  1. Finds links to `<DIRECTUS_ASSETS_URL>/assets/<id>` in the built HTML.
  2. Downloads each file once into the build as `/downloads/<id>/<filename_download>`.
  3. Rewrites the links to point at the local copies.
- [x] Netlify plan checked by owner (2026-10-28): bandwidth is fine, so **move both the PDFs and the 4 MP4s**.
- [ ] Optional: cache downloads between builds (each build re-downloads ~82 MB otherwise).
- Freshness: a replaced file updates on the next site build, the same as all other content.
- Doing this **before cutover** would mean visitors never touch the CMS during the move.

### Cloudflare cache in front of the CMS: skipped (owner, 2026-10-28)

Little gain: visitors only fetch the PDFs/MP4s above from the CMS, and the production domain isn't on Cloudflare. Revisit only if `familyforestcarbon.org` moves its DNS to Cloudflare. The rule would cache `/assets/*` only, bypass any request with a cookie, `Authorization` header or `access_token`, and use a short TTL (replaced files go stale).

### Replace the "Deploy Website" flow with the built-in Deployment module

The Deployment module was added in 11.15.0, gained Netlify in 11.15.2, access control and live status webhooks in 11.16.0, and dashboard links in 11.17.0. All of it is included in 11.17.4.

- [ ] In Netlify, create a personal access token. Then configure Netlify in the Deployment module, with an account slug if needed.
- [ ] Set up Netlify webhooks to the CMS for live build status. This needs the public Fly URL, so it won't work against the local copy.
- [ ] Set deployment permissions for editors (RBAC).
- [ ] Test a deploy, then remove the old "Deploy Website" flow.

---

## Open questions

1. ~~**Past upgrade failures:**~~ Answered — an extension conflict or error.
   Original question — which versions did you try, and what broke (migration errors, extensions, the UI, the site)?
2. ~~**Current database:**~~ Answered — Postgres 15 on the VPS, managed by Dokploy.
   Original question — is Postgres on the same VPS (Dokploy-managed)? Which major version? Roughly how large?
3. ~~**Extensions:**~~ Answered — see the extensions table.
   Original question — what's installed on prod today, including the video extension? Are any your own builds?
4. ~~**Domains:**~~ Answered — test on `*.tupp.dev` (behind Cloudflare). Production stays on `familyforestcarbon.org`, which is **not** on Cloudflare.
   Original question — which is the live CMS URL (`ffcp-cms.tupp.dev` or `cms.familyforestcarbon.org`) and the assets domain (`cdn.tupp.dev` or `assets.familyforestcarbon.org`)? Is Cloudflare in front of them now?
5. **Licensing:** Directus 12 moved to MSCL-1.0-GPL. Under BSL there was a ~$5M total-finances threshold before a commercial licence was required. Is the organisation under that threshold? Check the current terms — this may decide 11.x vs 12.x.
6. **Automation:** are there Flows, webhooks or build hooks (e.g. Netlify rebuild on publish)?
7. ~~**Plans and regions:**~~ Answered — Neon free plan; Fly in eastern/central US (proposed: Fly `iad` + Neon AWS `us-east-1`, both in N. Virginia). Owner has a Fly account and org. Use a **new** R2 bucket.
   Original question — Neon free or paid (free has storage and point-in-time-restore limits)? Preferred Fly region?
8. ~~**Repo and CI:**~~ Answered — **manual `fly deploy`** (owner's choice, 2026-10-27). GitHub Actions is only for the nightly backup. Region: **Fly `iad` + Neon AWS `us-east-1`** (confirmed).
   Original question — is this repo on GitHub? Deploys via GitHub Actions (`flyctl deploy`), or by hand?

## Suggestions

- **Pin every image tag.** The old Fly Dockerfile used `:latest`, which can cause surprise upgrades.
- **Schema-as-code.** Commit snapshots so schema changes can be reviewed and reproduced.
- **Site-build diff as the regression test** for both the upgrade and the cutover — cheap and catches a lot.
- **Bake extensions into the image** so Fly machines are fully reproducible and stateless.
- **Neon branches for every rehearsal** — restore once, branch many times.

---

## References

- [Directus breaking changes](https://directus.io/docs/releases/breaking-changes)
- [Directus changelog](https://directus.com/docs/releases/changelog)
- [Directus upgrading guide](https://directus.io/docs/self-hosting/upgrading)
- [v12.x release mirror](https://sourceforge.net/projects/directus.mirror/files/v12.1.0/)
