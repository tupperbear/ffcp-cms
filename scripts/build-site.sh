#!/usr/bin/env bash
# Build ../site statically against a CMS (default: the local dev CMS) and save the output.
# Usage: [CMS_URL=https://...] scripts/build-site.sh <name>   -> .migration/baselines/<name>/
# Assumes the site repo is checked out next to this one (../site).
#
# The site's astro.config merges .env over the shell env, so the CMS URL is
# overridden with a temporary .env.production.local (removed on exit).
# Note: the Netlify adapter always writes to ../site/dist, which this replaces.
set -euo pipefail

NAME=${1:?usage: scripts/build-site.sh <name>}
HERE=$(cd "$(dirname "$0")/.." && pwd)
SITE=$HERE/../site
OUT=$HERE/.migration/baselines/$NAME

cd "$SITE"
trap 'rm -f "$SITE/.env.production.local"' EXIT
CMS_URL=${CMS_URL:-http://localhost:8055}
cat >.env.production.local <<EOF
DIRECTUS_API_URL="$CMS_URL"
DIRECTUS_ASSETS_URL="$CMS_URL"
IS_PREVIEW=false
EOF

# Astro's content store persists between builds and can carry content over from a
# build against a different CMS, so always start from a fresh fetch.
rm -f node_modules/.astro/data-store.json .astro/data-store.json
npx astro build
rm -rf "$OUT"
mkdir -p "$HERE/.migration/baselines"
cp -R dist "$OUT"
echo "Saved to $OUT ($(find "$OUT" -name '*.html' | wc -l | tr -d ' ') pages)"
