# Backend Deployment Options (Google Cloud Run)

The backend is a Gleam/BEAM service packaged by the repo-root [Dockerfile](Dockerfile) and deployed to Cloud Run (`ai-arda-tr-api`, `asia-northeast1`). You have two ways to ship it.

## Option 1: Manual Deployment from Local

Best for rapid iteration.

1.  **Authenticate:**
    ```bash
    gcloud auth login
    gcloud config set project YOUR_PROJECT_ID
    ```

2.  **Deploy:**
    ```bash
    gcloud run deploy ai-arda-tr-api \
      --source . \
      --platform managed \
      --region asia-northeast1 \
      --project YOUR_PROJECT_ID \
      --allow-unauthenticated \
      --set-env-vars "GEMINI_API_KEY=your_key,ALLOWED_ORIGINS=https://ai.arda.tr;http://localhost:8080"
    ```
    `GEMINI_API_KEY` and `ALLOWED_ORIGINS` are required at startup. `GMAIL_USER` / `GMAIL_APP_PASSWORD` / `CONTACT_ADDRESS` are optional for the contact-email handoff.

3.  **Finalize:**
    - The Cloud Run URL is already hard-coded as `API_BASE_URL` in [public/script.js](public/script.js). Update it only if you rename the service or move regions.

### Helper Script

[cloud_deploy.sh](cloud_deploy.sh) reads `.env` and requires:
- `GCP_PROJECT_ID`
- `GEMINI_API_KEY`
- `ALLOWED_ORIGINS`

It forwards optional `GMAIL_USER`, `GMAIL_APP_PASSWORD`, and `CONTACT_ADDRESS`. It also verifies the active `gcloud` project and switches it to `GCP_PROJECT_ID` before calling `gcloud run deploy --source .`, which builds the Gleam Dockerfile via Cloud Build.

> `--allow-unauthenticated` is required because the frontend is a public website. Without it, every visitor would need an IAM login.

---

## Option 2: GitHub Actions (Workload Identity Federation)

[.github/workflows/deploy-backend.yml](.github/workflows/deploy-backend.yml) runs on `workflow_dispatch` and uses **Workload Identity Federation** so no long-lived service-account JSON keys are stored in GitHub.

### One-time Google Cloud setup

```bash
export PROJECT_ID="your-project-id"
export SERVICE_ACCOUNT="github-deployer"
export REPO="akara/ai.arda.tr"   # owner/repo

gcloud iam service-accounts create "$SERVICE_ACCOUNT"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/run.admin"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.admin"

gcloud iam workload-identity-pools create "github-pool" \
  --location="global" --display-name="GitHub Pool"

gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --location="global" \
  --workload-identity-pool="github-pool" \
  --display-name="GitHub Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --issuer-uri="https://token.actions.githubusercontent.com"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

gcloud iam service-accounts add-iam-policy-binding \
  "$SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/attribute.repository/$REPO"
```

### GitHub repository secrets

Under `Settings → Secrets and variables → Actions`:

| Secret | Purpose |
|---|---|
| `GCP_WIF_PROVIDER` | Full provider resource name (see below) |
| `GCP_SA_EMAIL` | `github-deployer@YOUR_PROJECT_ID.iam.gserviceaccount.com` |
| `GEMINI_API_KEY` | Google Gemini API key |
| `ALLOWED_ORIGINS` | Semicolon-delimited CORS allowlist |
| `GMAIL_USER` | (optional) SMTP user for contact handoff |
| `GMAIL_APP_PASSWORD` | (optional) SMTP app password |
| `CONTACT_ADDRESS` | (optional) Recipient address; defaults to `GMAIL_USER` |

Fetch the provider resource name with:
```bash
gcloud iam workload-identity-pools providers describe github-provider \
  --location=global \
  --workload-identity-pool=github-pool \
  --format="value(name)"
```

Trigger the workflow manually from the Actions tab (`Deploy Backend to Cloud Run → Run workflow`).
