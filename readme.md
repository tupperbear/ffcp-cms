# FFCP CMS
Description of project goes here...

## Setup
1. Clone repo
2. Copy `.env.example` to `.env` and fill in the values
3. Spin up the container
```
docker compose up
```
4. Access the application using the url output in the setup logs (http://0.0.0.0:8055)
## After the migration: image size baseline (2026-11-13)

Following `docs/optimization-playbook.md` §3, with FFCP's own resizer settings
(`EXTENSIONS_IMAGE_UPLOAD_RESIZER_MAXSIZE=2000`, WebP q80):

- `scripts/reencode-images.py plan` listed 92 images (82 JPEGs for the resizer, 10 PNGs
  over 2000 px as WebP q85). Originals came from `.dev/uploads` (all matched the CMS's
  `filesize`); rehearsed on the dev CMS first, then one file on production, then the rest.
- Result: 92 replaced in place (same ids), 0 failed; **299 MB → 37 MB**. CMS images
  360 MB → 98 MB; all files 0.73 GB → 0.46 GB (284 files). Old originals stay in the
  backups bucket under `prod/files/`.
- Site build (54 pages, images via Netlify Image CDN) before: 42 s; cold build after:
  40 s. Compared with `scripts/compare-site.py`: 1 difference, by design: a portrait
  background image (`b3951347…`) now requests 1489×2000 instead of 2000×2687.
- Seen on the dev rehearsal: one file left an extra copy (`<id>__<hash>.webp`, 255 kB),
  and names with a dot give odd disk names (`<id>. HiRes-36 (1)`); both serve fine.
