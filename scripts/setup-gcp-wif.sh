#!/usr/bin/env bash
#
# One-time bootstrap for GitHub Actions -> Google Cloud deploys using
# Workload Identity Federation (keyless OIDC — no long-lived service-account
# JSON keys are ever stored in GitHub).
#
# Run this ONCE, locally, with an account that has Owner / IAM Admin on the
# project. It is idempotent, so it is safe to re-run. At the end it prints the
# two values to store as GitHub Actions secrets (GCP_WIF_PROVIDER, GCP_SA_EMAIL)
# and the exact `gh secret set` commands.
#
# Usage:
#   ./scripts/setup-gcp-wif.sh
#   PROJECT_ID=my-project REPO=owner/repo ./scripts/setup-gcp-wif.sh
#
set -euo pipefail

# --- Configuration (override via environment) -------------------------------
PROJECT_ID="${PROJECT_ID:-ai-resume-chatbot-479106}"
REPO="${REPO:-c0ze/ai.arda.tr}"          # owner/repo allowed to deploy
POOL_ID="${POOL_ID:-github-pool}"
PROVIDER_ID="${PROVIDER_ID:-github-provider}"
SA_NAME="${SA_NAME:-gh-deploy}"

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Project  : ${PROJECT_ID}"
echo "Repo     : ${REPO}"
echo "Pool     : ${POOL_ID}"
echo "Provider : ${PROVIDER_ID}"
echo "SA       : ${SA_EMAIL}"
echo

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"

echo "==> Enabling required APIs"
gcloud services enable \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  --project="${PROJECT_ID}"

echo "==> Workload Identity Pool"
if ! gcloud iam workload-identity-pools describe "${POOL_ID}" \
  --project="${PROJECT_ID}" --location="global" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "${POOL_ID}" \
    --project="${PROJECT_ID}" --location="global" \
    --display-name="GitHub Actions"
fi

echo "==> OIDC provider (locked to repo ${REPO})"
if ! gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
  --project="${PROJECT_ID}" --location="global" \
  --workload-identity-pool="${POOL_ID}" >/dev/null 2>&1; then
  # The attribute-condition restricts which repository may mint usable tokens.
  # Without it, recent gcloud refuses to create a GitHub OIDC provider — and it
  # is the key defense against other repos impersonating this one.
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository == '${REPO}'"
fi

echo "==> Deploy service account"
if ! gcloud iam service-accounts describe "${SA_EMAIL}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="GitHub Actions deployer (Cloud Run)"
fi

echo "==> Granting deploy roles"
# run.admin            : create/update the Cloud Run service
# cloudbuild.builds.*  : `gcloud run deploy --source` builds via Cloud Build
# artifactregistry.*   : push the built image (and create the repo first time)
# storage.admin        : the Cloud Build source-staging bucket
# iam.serviceAccountUser: act as the Cloud Run runtime service account
for role in \
  roles/run.admin \
  roles/cloudbuild.builds.editor \
  roles/artifactregistry.admin \
  roles/storage.admin \
  roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None >/dev/null
  echo "    + ${role}"
done

echo "==> Binding the repo's OIDC identity to the deploy SA"
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${REPO}" \
  >/dev/null

PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"

cat <<EOF

✅ Workload Identity Federation is configured.

Set these GitHub Actions repository secrets (from this repo's root):

  gh secret set GCP_WIF_PROVIDER --body "${PROVIDER_RESOURCE}"
  gh secret set GCP_SA_EMAIL     --body "${SA_EMAIL}"

The deploy workflow also needs GEMINI_API_KEY and ALLOWED_ORIGINS secrets
(and optional GMAIL_USER / GMAIL_APP_PASSWORD / CONTACT_ADDRESS). Once all
secrets are set, pushing backend changes to main will deploy automatically.
EOF
