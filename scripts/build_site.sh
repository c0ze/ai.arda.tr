#!/usr/bin/env bash
#
# Build the committed frontend into _site/ for the ai-arda-tr Worker. Same
# steps deploy-ui.yml ran for GitHub Pages: Lustre build into public/, then the
# browser-boundary tests. Used by scripts/deploy_cloudflare.sh. Commit first:
# it builds HEAD (git archive), not the working tree.
#
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"

# The pinned toolchain (.mise.toml), resolved here: mise would not trust the
# copy's .mise.toml in the temp dir.
if command -v mise >/dev/null 2>&1; then
  eval "$(cd "$repo" && mise env -s bash)"
fi

src="$(mktemp -d)"
trap 'rm -rf "$src"' EXIT
git -C "$repo" archive HEAD | tar -x -C "$src"

cd "$src/frontend"
gleam deps download
# lustre_dev_tools downloads Bun in a single attempt; retry the build.
built=""
for attempt in 1 2 3; do
  if gleam run -m lustre/dev build --minify --outdir=../public; then
    built=1
    break
  fi
  echo "Lustre build failed (attempt $attempt of 3)" >&2
  rm -rf .lustre
  sleep 10
done
[ -n "$built" ] || exit 1
gleam build
node --test test/*.test.mjs

rm -rf "$repo/_site"
mv "$src/public" "$repo/_site"
echo "built $repo/_site from $(git -C "$repo" rev-parse --short HEAD)"
