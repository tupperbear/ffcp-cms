#!/usr/bin/env bash
# Build the site (SITE_DIR in migration.env) statically against a CMS (default:
# the local dev CMS) and save the output.
# Usage: [CMS_URL=https://...] scripts/build-site.sh <name>   -> .migration/baselines/<name>/
#
# The site's astro.config merges .env over the shell env, so the CMS URL is
# overridden with a temporary .env.production.local (removed on exit).
# Note: the Netlify adapter always writes to <site>/dist, which this replaces.
# Uses the Node version from the site's .nvmrc when nvm has it installed.
set -euo pipefail

NAME=${1:?usage: scripts/build-site.sh <name>}
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/migration.env"
SITE=$(cd "$HERE" && cd "$SITE_DIR" && pwd)
OUT=$HERE/.migration/baselines/$NAME

cd "$SITE"
if [ -f .nvmrc ]; then
	want=$(tr -d ' \nv' <.nvmrc)
	nvm_bin=$HOME/.nvm/versions/node/v$want/bin
	if [ -x "$nvm_bin/node" ]; then
		PATH=$nvm_bin:$PATH
	elif [ "$(node -v)" != "v$want" ]; then
		echo "warning: site wants Node $want (.nvmrc), using $(node -v); install it with: nvm install $want" >&2
	fi
fi
echo "node $(node -v)"

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
