# Directus + Astro optimisation playbook

What we did to the AFF CMS and site after its migration (2026-11-11), and how to do the
same for FFCP and ATFS. It follows on from the migration playbook
([`migration-playbook.md`](migration-playbook.md)): same setup (Directus 11.17.4 on Fly, Neon,
R2; Astro site on Netlify with a static live site and an SSR preview site), same method:
**measure, change one thing on a branch, build the site before and after, diff the HTML.**

The details and every number are in AFF's readme ("After the migration") and
`aff/cms/docs/media-audit/2026-11-11-report.md`.


> **Copy.** The original is `aff/cms/docs/optimization-playbook.md` (GitHub `tupperbear/aff-cms`);
> update it there and copy it here. The scripts it names (`scripts/delete-files.py`,
> `scripts/reencode-images.py`, `scripts/prepare-image.mjs`, `scripts/media-audit/`) are in
> that repo: copy them into this one before use. `prepare-image.mjs` finds `sharp` in
> `../../site/new/site` (AFF's layout); point `SHARP_FROM` at this CMS's site `package.json`.

## Results at AFF

| | Before | After |
|---|---:|---:|
| Local site build, warm cache | 7 min 23 s | **36 s** |
| Rendering the pages (in that build) | 421 s | 20 s |
| Preview (SSR) site build, local | 148 s | **10 s** |
| Netlify deploy, live site | 220–466 s | **161 s** |
| Netlify deploy, preview site | 114–156 s | **30 s** |
| Site build output | 873 MB | 524 MB |
| Built images over 1 MB | 97 | 5 |
| Image weight per page (examples) | home 9.0 MB, newsroom 51.6 MB | 1.8 MB, 7.6 MB |
| CMS files | 1,546 / 6.0 GB | **1,127 / 1.68 GB** |
| CMS images | 2.27 GB | 388 MB |

Order matters: **build speed first** (it gives you a fast, trustworthy build to check
everything else with), then **remove unused files**, then **bring the rest to a size
baseline**. We also tried Directus's native Netlify deployments (Deployment module,
11.17+) as a replacement for the "Deploy Website" flow and build hook; it worked but AFF
chose to keep the flow (notes in AFF's readme).

---

## 1. Site build speed

### What was slow

- **Every image was fetched just to read its size.** `getRemoteImageUrl` in
  `src/lib/utils.ts` called `inferRemoteSize` for each CMS image (~1750 per build), and
  `<Image inferSize>` does the same. With a warm image cache this *was* the build:
  rendering took 421 s at 25% CPU, waiting on the network. FFCP and ATFS have the same
  code (`src/lib/utils.ts`, plus FFCP's `image_block.astro` and ATFS's
  `block-full-image.astro` use `inferSize`).
- **Some images were built from full-size originals** (up to 9520 px, 30–80 MB) because
  components asked for no size: background images, two-column images, the og image, and
  every `<Image inferSize src={getFileURL(...)}>`. Blog cards built both a 620 px version
  they didn't show and the full original they did.

### The fix (site commit `2f28d8b`)

- **One query for all file sizes:** `directus.files({ fields: ['id','width','height'], limit: -1 })`
  once per build (0.4 s), and work out the size Directus returns for a transform:
  `width`+`height` → exactly that (Directus crops to fit); one of them → scale the other by
  the aspect ratio with `Math.round`; Directus also **enlarges** smaller images. Fall back
  to `inferRemoteSize` only when a file has no size. See `getRemoteImage()` in AFF's
  `src/lib/utils.ts`; it returns `{ src, width, height }` for `getImage()` or `<Image {...}>`.
- **Cap every image** where the component asked for no size, by asking Directus for a
  width (so the build downloads a small version): default 1600, cards 800, full-width
  image 2000, file thumbnails 600, og image 1200.
- **Cards build only the image they show.**

### Gotchas

- **The SEO plugin stores its image as `<id>.jpg`.** Strip the extension before looking the
  id up, or those images silently skip the cap (we found 10 MB og images that way).
- **Singleton collections** (`globals`) return an object, not a list, from `/items/…`.
- **Rounding:** for 6 of 1730 large JPEGs Directus's scaled side was 1 px smaller than
  `Math.round` gives (libvips shrink-on-load). Harmless: Astro resizes by width only, so
  the image is the same; at most an `<Image>` height attribute is 1 px off.
- **New transforms can 503.** A change that asks for many new image versions at once makes
  Directus generate them from large originals; its pressure limiter returns 503 and Astro
  fails the build (`Failed to load remote image … 503`). Before pushing such a change,
  warm the new URLs one at a time (we logged every image URL from a build and requested
  each serially: 1730 URLs, 21 min), so the Netlify build finds them ready. Re-running a
  failed local build also works: Astro keeps what it already made.
- **Astro's remote image cache** keeps images for as long as Directus allows (30 days), so
  replacing an original doesn't change a warm build. To check new originals, move
  `node_modules/.astro` aside and build cold.

### How we checked

- `scripts/build-site.sh <name>` against the live CMS before and after, timed.
- Compare with image file names and `width`/`height` attributes normalised (they change by
  design), then require **0 other differences**: AFF had 767 pages identical, plus a
  stray invalid `inferSize="true"` attribute gone.
- Count built images over 1 MB and image bytes per page.
- **Preview site:** build with `IS_PREVIEW=true` from `main` and from the branch (the 110
  pre-rendered listing pages must match), then run `astro dev` in preview mode against the
  live CMS and request pages that use every image component; all images must load.
- The Netlify adapter rewrites `.netlify/v1/config.json`, which is tracked in the AFF site
  repo by mistake: save and restore it around preview builds.

---

## 2. Unused files

### Method

1. **Work on a copy of the database, not production.** The auto-mode safety check blocks
   reading the production database directly, and a fixed snapshot is better anyway. We
   restored the latest backup's `directus.dump` into a throwaway Postgres container
   (`aff-audit-db`) and checked that production had the same file list (site token,
   `/files?limit=-1`).
2. **References** (`scripts/media-audit/find-refs.sql`): every file field (AFF: 20, all
   FKs), plus a UUID scan of every text, JSON and UUID column, which catches rich text,
   Markdown, the SEO field, video blocks (file id as a string) and button links. Leave out
   revisions, activity and versions.
3. **What's live:** a static build is the ground truth. Built images are named
   `/_astro/<file id>_…`, downloads sit under `/downloads/<id>/`; collect every UUID from
   the build and keep those that are file ids. Every live file must also be referenced
   (a check on the scan).
4. **Why the rest isn't shown** (`scripts/media-audit/classify.py`): follow each reference
   to its page or post: blocks via `pages_blocks`/`posts_blocks` (M2A `collection` +
   `item`), nested items (file rows, slides, link cards, points, leaders) via their block
   junctions. Watch for **junction rows whose page or post id is null** (left behind when
   it was deleted): they count as detached. Check the few that look shown but aren't by
   hand (AFF: two published leaders with the same slug).
5. Groups: **A** unreferenced, **B** only in detached blocks, **C** only in drafts or
   archived items (the owner's call: deleting breaks the draft), keep: live + CMS itself
   (logo, favicon, avatars).

AFF: 1,029 live; A 347 (2.0 GB, 46 of them PDFs); B 73 (0.44 GB); C 92 (1.48 GB). Videos
were half of it (2.07 GB; one 900 MB MP4 in a draft video block). 75 unused files had the
same name as a live file (repeat uploads of 32 MB stock photos).

### Deleting (`scripts/delete-files.py`)

- **Backups first:** the nightly backup copies files to `prod/files/` and never deletes,
  so deleted files stay recoverable (with their row from a daily DB dump, kept 35 days).
- Deleting a file sets content file fields to null (`ON DELETE SET NULL`), so detached
  blocks just lose their image; `directus_settings` fields are `NO ACTION`.
- Leave out anything whose emptying could break a live page (AFF: the duplicate leader's
  photo) and decide about **PDFs**: older emails and partner sites may link to
  `cms…/assets/<id>` directly (AFF deleted them; check the request logs if unsure).
- The script needs a **temporary admin token** (Studio → your user → Token → generate →
  Save; in a gitignored `.env.cleanup`; clear it afterwards). Without `--delete` it only
  checks. Before deleting it re-checks the live CMS: every file still exists, no file field
  points at a group A file (group B only from the expected rows), and nothing in the
  activity log since the snapshot mentions a listed file or block. Deletes in batches of
  25 and logs every row.
- After: file count and a full site build (**0 differences**), and check no deleted id is
  in the `main` or preview builds. AFF: 419 files, 2.43 GB.

---

## 3. Size baseline

### The rule

**Use the CMS's own upload resizer settings as the baseline**, so old and new files are
treated alike. AFF and ATFS: `EXTENSIONS_IMAGE_UPLOAD_RESIZER_MAXSIZE=1920`, WebP q73.
**FFCP's MAXSIZE is 2000**: use 2000 there. Agreed at AFF:

| Files | Treatment |
|---|---|
| JPEG/TIFF/AVIF/WebP over the max side, or within it but over 1 MB | let the resizer make them (WebP q73) |
| PNG over the max side | WebP q85, uploaded so the resizer skips it |
| PNG within the max side | left alone |
| anything that wouldn't shrink by 20% | skipped |
| PDFs, videos, SVGs | left alone (separate decisions) |

Why PNGs got WebP q85: lossless PNG at 1920 px only went from 70 to 47 MB (some grew),
and the site already serves every PNG as lossy WebP (Astro's default, ~q80), so q85
originals lose nothing visible. 70 MB → 4 MB.

The site never hands out originals (only resized versions, and downloads are PDFs), so
shrinking originals changes storage, transform speed (big originals cause the 503s),
backups and Studio, not what visitors get. Check this per site: look for images under
`/downloads/` in the build.

### How the resizer works (directus-extension-image-upload-resizer 2.3.0)

- A `files.upload` hook: it runs on **every upload, including replacing a file's content**
  (`PATCH /files/<id>` with a file). It re-encodes JPEG/PNG/WebP/AVIF/TIFF to the configured
  format at most MAXSIZE on the longest side (fit inside, no enlargement) and keeps the
  result only if it's smaller than the upload.
- It skips an upload whose form carries **`optimized=true`** (no such column needed).
- It writes `filename_download` without the extension (we put `.webp` back), and Directus
  then derives the disk name from that: names containing a dot get odd disk names
  (`<id>. HiRes-11`). They serve fine; it also happens to new uploads.
- Replacing keeps the file id (so every reference keeps working), updates type, size and
  dimensions, renames the stored file to `<id>.webp` and **deletes the old original and all
  its resized versions** from storage. `<id>.jpg` URLs (the SEO field) still work.
- On production the resizer sets the new type **before** the new size: wait until the size
  is no longer the uploaded one and two reads agree, or you'll log the intermediate file.

### The run (`scripts/reencode-images.py`, `scripts/prepare-image.mjs`)

1. `reencode-images.py plan <csv>` lists the files from the live CMS by the rule above.
2. Collect the originals locally and **check each against the CMS's `filesize`**: from the
   dev copy (`.dev/uploads`) where they match, else from the backup's `volumes.tar`
   (`tar -xf … --strip-components=2 "*_directus_uploads/_data/<filename_disk>"`).
3. Dry run (default): estimates each result with sharp and marks the skips. AFF: 193 files
   1,959 MB → 73 MB estimated, 6 skipped.
4. **Rehearse on the local dev CMS** (`docker compose -f docker-compose.dev.yml up`, flows
   inactive, a local admin token set in its database), then check every replaced file:
   WebP, within the max side, download name, only the new file in `.dev/uploads`.
5. **One file on production** (we used the biggest, an 80 MB TIFF → 258 kB), check it,
   check its old original is in the backups bucket, then the rest (`--apply`; one file at
   a time, uploads are ≤ a 1920 px q95 JPEG, ~32 min for 192 files).
6. Re-read every file from the live CMS against the log; cold site build (move
   `node_modules/.astro` aside) and compare: **0 differences** apart from image names
   and sizes. Look at a few images side by side.

AFF: 193 replaced, 1,959 MB → 74 MB, 0 failed. A fully cold build then hit one 503 at
image 1467 of 1731 (load, not a bad file); re-running continued. Netlify's warm cache keeps
the images built from the old originals until they expire, which is harmless.

---

## 4. Checklist for FFCP and ATFS

1. **Disk:** each local build is ~0.5–0.9 GB, a cold Astro cache ~1.6 GB, originals for
   the baseline ~2 GB, the backup itself several GB. Check `df -h` before each step.
2. **Build speed:** port `getRemoteImage()` / `getFileSizes()` / `transformedSize()` and the
   `files()` client method; replace every `inferRemoteSize` and `inferSize`; cap every
   image without a size; strip `.jpg` from SEO ids. Branch, time before/after, compare,
   test the preview site, warm new transform URLs serially, then merge.
3. **Unused files:** restore the latest dump into a scratch container; run
   `find-refs.sql`; load the build's ids; adapt `classify.py`'s junctions to the CMS's
   schema; review groups A/B/C (and PDFs) with the owner; delete with `delete-files.py`;
   full build, 0 differences.
4. **Size baseline:** read the CMS's resizer settings (`fly.prod.toml`); plan, collect and
   verify originals, dry run, rehearse on dev, one file on prod, the rest, verify, cold
   build.
5. **Afterwards:** remove the admin token and `.env.cleanup`; delete local baselines,
   originals and the old Astro cache once settled; record results in the repo readme.

## 5. Working notes

- The user does account steps (tokens, dashboards) from short walkthroughs; Claude runs
  scripts and pushes the cms repo. Pushing the site's `main` deploys production.
- The auto-mode safety check blocks reading the production database and deleting
  `.migration/` data: use backups for analysis and let the user run deletions.
- Ask before each production write step (deleting, the first replaced file, the rest).
- Group C (drafts), duplicate items and detached block rows are content decisions for
  the site owner, not clean-up.
