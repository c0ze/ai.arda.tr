#!/usr/bin/env bash
#
# Build the committed frontend and deploy it to the ai-arda-tr Worker
# (ai.arda.tr). Uses your local wrangler login; run `npx wrangler login` once
# if it asks. Commit first: uncommitted changes are not deployed. The backend
# is not touched (Cloud Run, deploy-backend.yml).
#
# Usage:
#   ./scripts/deploy_cloudflare.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build_site.sh
npx --yes wrangler@4.168.0 deploy
