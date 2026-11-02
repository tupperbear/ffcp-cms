# Directus CMS migration playbook

How to move a Directus CMS from the Dokploy VPS to **Fly.io + Neon Postgres + Cloudflare R2**, upgrading Directus along the way. Distilled from the FFCP migration (cut over 2026-11-02, 0 differences); [`migration-plan.md`](migration-plan.md) is the full FFCP record if you need the detail behind a step.

**Assumed setup** (true for FFCP, `aff-cms` and `atfs-cms`):
- The old CMS runs on the shared VPS under Dokploy: a Directus compose project plus a Postgres Swarm service, with files on Docker volumes. **The three CMSes share the server: only ever touch the containers and volumes of the one you're migrating.**
- It feeds an **Astro site on Netlify**: a static live site, plus an SSR preview site used for Directus live preview.
- **DNS for the production domain is run by someone else**, so every DNS change is a request with lead time.

**Target:** one Fly machine (suspends when idle), extensions baked into the image, database on Neon, files on R2, nightly backups from GitHub Actions to a separate R2 bucket.

**The method in one line:** build the site against the old CMS and against the new one, and diff the HTML. Every phase ends with "0 differences" before you move on.

---

## 1. Copy the kit into the new CMS repo

| File | What to change |
|---|---|
| `migration.env` | **Every value**: site repo path and URL, production and assets domains, Fly app names, test domain, VPS ssh alias and IP, Postgres service, database name, volume prefix, backup folder. Find the VPS names with `sudo docker ps` and `sudo docker volume ls` on the VPS. |
| `scripts/` (all of it) | Nothing. The scripts read `migration.env`. |
| `scripts/migration/site-requests.txt` | Don't copy it. Generate it with `capture-site-requests.sh` (Phase 6). |
| `Dockerfile` | Directus version and the extension list with pinned versions (Phase 2). |
| `docker-compose.dev.yml` | Postgres major version and Directus version to match the old production CMS. |
| `fly.toml` (test), `fly.prod.toml` (prod) | `app`, `PUBLIC_URL`, CSP `FRAME_SRC` (the preview site), and the env vars from the old compose file. |
| `.github/workflows/backup.yml` | `ASSETS_R2_BUCKET`, `BACKUP_R2_BUCKET`; `BACKUP_ENV: test` until cutover. |
| `.gitignore` | Keep `.env.*` and `.migration` ignored: `.migration/` holds production dumps. |

Secrets live in gitignored files, never in `migration.env`:
- `.env.fly` / `.env.fly.prod`: `SECRET` (≥ 32 bytes, new one for prod), `DB_CONNECTION_STRING`, `STORAGE_R2_KEY/SECRET/BUCKET/ENDPOINT`, `EMAIL_FROM`, `EMAIL_SMTP_HOST/PORT/USER/PASSWORD` (prod only).
- `.env.backup`: the two backup tokens (`ASSETS_R2_*` read-only, `BACKUP_R2_*` read/write).
- The site repo's `.env` must have `DIRECTUS_STATIC_TOKEN` (the scripts use it to read the old CMS the way the site does).

| Script | Does |
|---|---|
| `run-vps-backup.sh` | Owner runs it: read-only dump + volumes tar on the VPS (one sudo prompt). Prints the backup name. |
| `dev-restore.sh <dir>` | Restores a backup into the local dev stack (flows switched off). |
| `build-site.sh <name>` | Builds the site against `CMS_URL` (default `localhost:8055`) into `.migration/baselines/<name>`; picks the Node version from the site's `.nvmrc`. |
| `compare-site.py <a> <b>` | Diffs two builds, ignoring per-build noise and which CMS host was used. |
| `check-live-order.py <build>` | Compares list order on every page with the live site. |
| `migration/capture-site-requests.sh` | Records the site's list requests to the old CMS (for the sort fix). |
| `migration/migrate.sh <backup> rehearsal\|cutover` | The whole data migration and its verification, ~5 min. |
| `backup.sh` + workflow | Nightly backup (GitHub Actions). |

## 2. Ask the owner first

- **Who runs DNS** for the production domain, and how fast do they respond? Which records point at the VPS today (`cms`, `assets`, others) and with what TTL?
- **Downloads:** does the live site link PDFs or videos straight to the CMS? (FFCP: 28 files.) These move to Netlify before cutover.
- **Editors:** how many Studio users, and how many collections? This decides 11.x vs 12.x (see Pitfalls).
- **Email:** SMTP provider and credentials for password resets and invites.
- **Flows and webhooks:** e.g. a "Deploy Website" flow that calls a Netlify build hook.
- **Extensions** actually in use on prod.
- **Risk calls:** OK to retire the old assets domain (breaks old external links)? Backups only inside Cloudflare?
- **Accounts:** Fly org, Neon plan and region, R2 buckets. Use Fly `iad` with Neon AWS `us-east-1`.

## 3. Phases

Each phase lists its **exit check**. Don't start the next phase until it passes.

### Phase 0: Inventory and a backup (read-only on prod)
1. Fill in `migration.env`.
2. Owner runs `scripts/run-vps-backup.sh`; download with `rsync -a <VPS_SSH>:<VPS_BACKUP_DIR>/<name>/ .migration/backups/<name>/` and check `shasum -a 256 -c SHA256SUMS`.
3. Record: Directus and Postgres versions, extensions (`directus_extensions` table and `uploads/extensions/.registry/`), flows, roles, the static token's user, the full env list from the compose file.

**Exit:** a verified backup and a list of what prod runs.

### Phase 1: Local copy identical to prod
1. `docker-compose.dev.yml` with prod's exact Directus and Postgres versions.
2. `scripts/dev-restore.sh .migration/backups/<name>`.
3. `scripts/build-site.sh site-<old version>`: this is the **baseline**.

**Exit:** Studio works (owner checks editing, uploads, extensions), baseline saved.

### Phase 2: Upgrade locally
1. Write the `Dockerfile`: pinned `directus/directus:<target>`, extensions installed with `pnpm install <pkg>@<version>`. No Marketplace, no `EXTENSIONS_LOCATION`.
2. Start it on the restored data (migrations run on startup), rebuild the site, compare with the baseline.
3. Read the [breaking changes](https://directus.io/docs/releases/breaking-changes) between the two versions. Check renamed extension env vars (see Pitfalls).
4. If lists come out in a different order, that's the null-sort problem (Pitfalls): the sort fix in Phase 6 handles it.

**Exit:** 0 differences vs the baseline (after the sort fix if needed); owner checks the Studio, including live preview and any custom interfaces.

### Phase 3: Test environment on Fly, Neon and R2
1. Create the Neon database (Postgres 18 is Neon's default; use the **direct**, non-pooled connection string), the R2 assets bucket (private) and the Fly test app.
2. `.env.fly`, then `fly secrets import --stage -a <test app> < .env.fly` and `fly deploy`.
3. Restore into Neon and copy files to R2 by hand, as in the FFCP plan (Phase 3): `neon-restore.sh` in a `postgres:18` container, then `rclone copy --files-from` the `filename_disk` list. (`migrate.sh` always targets the production app, so it's for Phase 6.)
4. Custom test domain: add the `_acme-challenge` CNAME **and** `_fly-ownership` TXT records that `fly certs add` prints, or the cert can stall.
5. A **separate Netlify preview site** pointed at the test CMS (`IS_PREVIEW=true`), so editors' real previews stay on the old CMS. Add the test host to the site's `image.domains` and to `FRAME_SRC`, and set `pages.preview_url` on the test CMS.

**Exit:** site built from the test CMS has 0 differences; owner tests live preview on the test preview site.

### Phase 4: Backups
1. Bucket `<name>-snapshots` with prefixes `test/` and `prod/`; two tokens: read-only on the assets bucket, read/write on the snapshots bucket (`.env.backup`, never in `.env.fly`).
2. GitHub secrets: `DB_CONNECTION_STRING`, `R2_ENDPOINT`, `ASSETS_R2_KEY/SECRET`, `BACKUP_R2_KEY/SECRET`. Run the workflow by hand once.
3. R2 dashboard → snapshots bucket → Settings: lifecycle `test/db/daily/` 35 days, `test/db/monthly/` 365 days; bucket lock `test/db/` 30 days.
4. **Restore test** into a Neon branch (runbook in the FFCP plan, Phase 3 → Backups).

**Exit:** a green run, files in `test/`, and a restore test with 0 differences.

### Phase 5: Site and DNS preparation (weeks before cutover)
1. **Downloads to Netlify:** copy the FFCP site's `src/integrations/local-downloads.ts` into the new site. It copies linked CMS files into the build and fails the build if any is missing. Ship it before the cutover, so visitors never touch the CMS during the move.
2. **Production Fly app** (`fly.prod.toml`, `.env.fly.prod` with a new `SECRET` and the email settings), then `fly certs add <PROD_DOMAIN> -a <FLY_APP>`.
3. **Email the DNS owner** with an exact table and an explicit order; FFCP's DNS owner switched early and set different values than asked:

   > **Now (no effect on the live site):**
   > | Type | Name | Value |
   > |---|---|---|
   > | — | `<PROD_DOMAIN>` and `<OLD_ASSETS_DOMAIN>` | TTL **300 s** |
   > | CNAME | `_acme-challenge.<PROD_DOMAIN>` | `<value from fly certs add>` |
   > | **TXT** (not CNAME) | `_fly-ownership.<PROD_DOMAIN>` | `<value from fly certs add>` |
   >
   > **At cutover, only when we tell you on the day:** `<PROD_DOMAIN>` → A `<Fly IPv4>` + AAAA `<Fly IPv6>`; delete `<OLD_ASSETS_DOMAIN>`. Please don't change these records before then.

   Get the Fly IPs from `fly ips list -a <FLY_APP>`.
4. Check with DNS-over-HTTPS (local `dig` may return nothing): `curl -s -H 'accept: application/dns-json' 'https://dns.google/resolve?name=<name>&type=<type>'`, and `fly certs check <PROD_DOMAIN> -a <FLY_APP>` should show Issued.

**Exit:** downloads live on Netlify, the cert issued, the TTL lowered at least one old-TTL period before cutover.

### Phase 6: Rehearsal on the real production targets
1. `scripts/migration/capture-site-requests.sh`: re-run it whenever the site's queries change.
2. Owner runs `scripts/run-vps-backup.sh`.
3. `scripts/migration/migrate.sh <backup> rehearsal`: restores into the production Neon database, fixes the sort order from the old CMS's API, syncs files to R2, deploys `<FLY_APP>` with its `fly.dev` URL, then verifies.
4. Owner runs the Studio checklist on `https://<FLY_APP>.fly.dev`.

**Exit:** `0 difference(s)` and `0 reordered`; rehearse until it's boring (FFCP: 3 rehearsals, ~3.5 min each).

### Phase 7: Cutover day
Agree the time with the DNS owner. In order:
1. **Content freeze:** editors stop editing.
2. **Backup:** owner runs `scripts/run-vps-backup.sh`.
3. **`migrate.sh <backup> cutover`**: flows kept active, `PUBLIC_URL` = production domain. **Stop here unless it reports 0 differences and 0 reordered pages.**
4. **DNS switch** by the DNS owner. Check until both Google and Cloudflare DNS return the Fly IPs.
5. **Netlify:** `DIRECTUS_ASSETS_URL=https://<PROD_DOMAIN>` on the live and preview sites; delete the test preview site.
6. **Rebuild the live site.**
7. **Studio:** fill in the one-time "project owner" form. Editors log in again (new `SECRET`).
8. **Backups:** set `BACKUP_ENV: prod` in the workflow, push, and run it by hand; check `prod/db/daily/` and `prod/files/` in R2. Add the `prod/` lifecycle rules and lock (same as `test/`).
9. **Test:** Studio edit and image upload, live preview, the deploy flow triggers Netlify, live site pages, images and downloads, `fly certs check`.

**Rollback:** the DNS owner points the domain back at the VPS IP (the old CMS stays up, read-only); restore the old `DIRECTUS_ASSETS_URL`. Edits made on the new CMS would be lost.

If the DNS switch happens before step 3 (it did at FFCP): freeze immediately and continue with steps 2–3. `migrate.sh` reaches the old CMS by `VPS_IP`, so it works either way.

### Phase 8: Two weeks later
- DNS owner restores the usual TTL. Keep the `_acme-challenge` and `_fly-ownership` records: renewals use them.
- Delete the Fly test app and the test prefix rules.
- Decommission the old CMS on the VPS (only its containers and volumes), then the old backups bucket.

## 4. Pitfalls we hit

- **List order isn't stored.** Many junction rows have a null `sort`, so their order is whatever Postgres returns. It differed between Directus versions *and between restores of the same dump*. The fix is to read the order from the **old CMS's API** during the freeze and write it as explicit sort values (`backfill-sort.py`, run by `migrate.sh`). Relations with no sort field at all (FFCP: `text_with_buttons_block_buttons`) can't be fixed this way: add a sort field in the Studio before the order matters.
- **Astro's content store** (`node_modules/.astro/data-store.json`) carries content between builds against different CMSes. `build-site.sh` deletes it before each build.
- **Node version:** the site's Astro version sets the minimum Node. `build-site.sh` uses `.nvmrc` through nvm; the first FFCP cutover run failed on the shell's older Node.
- **Directus 12.x licence:** the free tier allows 25 collections, 3 Studio seats and 5 flows, and over the limit it blocks the API after a grace period. FFCP (53 collections, 10 users) stayed on **11.17.4**, the last 11.x. Check each CMS's counts before choosing.
- **11.x "project owner" form** sends the owner's details to Directus even with `TELEMETRY=false`; it can be pre-filled with `PROJECT_OWNER`.
- **Extensions in two places:** `EXTENSIONS_LOCATION=local` stored Marketplace extensions under `uploads/extensions/`. The likely cause of earlier failed upgrades. Bake extensions into the image, delete `directus_extensions` rows with `source = 'registry'` (`neon-restore.sh` does it), and don't copy `uploads/extensions/` to R2.
- **image-upload-resizer 2.x** renamed its env vars (`EXTENSIONS_IMAGE_UPLOAD_RESIZER_*`) and defaults to AVIF; set `FORMAT=webp`, `QUALITY_WEBP`, `MAXSIZE` to keep the old behaviour.
- **Health checks:** use `/server/ping`; `/server/health` needs auth in 12.x and reports `warn` for a few seconds after a cold start. Give the first deploy (migrations) a 60 s grace period.
- **Neon:** use the direct connection string; `DB_POOL__MIN=0` and a 60 s idle timeout so connections close before Neon suspends. Restore with a `postgres:18` client.
- **Collation warning** on `pg_dump` from the VPS (glibc 2.36 → 2.41) is harmless here: the logical dump is restored into a fresh database.
- **R2:** the endpoint must not include the bucket path (Cloudflare shows it with one). Debian's rclone 1.60 fails R2-to-R2 copies: pin rclone (1.68.2). Env vars named `RCLONE_*` are read as rclone flags.
- **Fly certificates** can stall without the `_acme-challenge` CNAME.
- **Live preview settings are cached**: after changing `preview_url`, restart Directus.
- **DNS owners don't always do what's asked:** FFCP got 900 s instead of 300 s, a CNAME instead of a TXT, and the switch before the data migration. Send exact tables, say "only on the day" for the switch, and check every record yourself.

## 5. Timings (FFCP)

| Step | Time |
|---|---|
| VPS backup (owner) | ~1.5 min |
| `migrate.sh` end to end | 3.5–5 min (download ~1.5, Neon restore ~2.5, verify build ~1.5) |
| DNS propagation | up to the TTL (900 s) |
| Whole cutover, freeze to tests passed | ~1 h with one hiccup |
| Project, inventory to cutover | ~9 days |
