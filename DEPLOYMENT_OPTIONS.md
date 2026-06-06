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
    - The Cloud Run URL is hard-coded as `cloud_run_base` in [frontend/src/frontend.gleam](frontend/src/frontend.gleam). Update it only if you rename the service or move regions.

### Helper Script

[cloud_deploy.sh](cloud_deploy.sh) reads `.env` and requires:
- `GCP_PROJECT_ID`
- `GEMINI_API_KEY`
- `ALLOWED_ORIGINS`

It forwards optional `GMAIL_USER`, `GMAIL_APP_PASSWORD`, and `CONTACT_ADDRESS`. It also verifies the active `gcloud` project and switches it to `GCP_PROJECT_ID` before calling `gcloud run deploy --source .`, which builds the Gleam Dockerfile via Cloud Build.

> `--allow-unauthenticated` is required because the frontend is a public website. Without it, every visitor would need an IAM login.

---

## Option 2: GitHub Actions (Workload Identity Federation)

[.github/workflows/deploy-backend.yml](.github/workflows/deploy-backend.yml) **auto-deploys on push to `main`** (backend paths only) and authenticates with **Workload Identity Federation**, so no long-lived service-account JSON keys are ever stored in GitHub.

### One-time Google Cloud setup

Run the idempotent bootstrap script once, using an account with Owner / IAM Admin on the project. It enables the required APIs and creates:

- a Workload Identity **pool + OIDC provider locked to this repo** (via an `assertion.repository` attribute condition),
- a dedicated **deploy service account**,
- the IAM roles needed for source-based Cloud Run deploys (`run.admin`, `cloudbuild.builds.editor`, `artifactregistry.admin`, `storage.admin`, `iam.serviceAccountUser`), and
- the `workloadIdentityUser` binding that lets only this repo's Actions impersonate the SA.

```bash
PROJECT_ID=ai-resume-chatbot-479106 REPO=c0ze/ai.arda.tr ./scripts/setup-gcp-wif.sh
```

It prints `GCP_WIF_PROVIDER` and `GCP_SA_EMAIL` with ready-to-paste `gh secret set` commands.

### GitHub repository secrets

Under `Settings → Secrets and variables → Actions` (or via `gh secret set`):

| Secret | Purpose |
|---|---|
| `GCP_WIF_PROVIDER` | Full provider resource name (printed by the script) |
| `GCP_SA_EMAIL` | Deploy SA, e.g. `gh-deploy@PROJECT_ID.iam.gserviceaccount.com` (printed by the script) |
| `GEMINI_API_KEY` | Google Gemini API key |
| `ALLOWED_ORIGINS` | Semicolon-delimited CORS allowlist |
| `GMAIL_USER` | (optional) SMTP user for contact handoff |
| `GMAIL_APP_PASSWORD` | (optional) SMTP app password |
| `CONTACT_ADDRESS` | (optional) Recipient address; defaults to `GMAIL_USER` |

### Triggering

Once the secrets are set, **pushing backend changes to `main` deploys automatically** (path-filtered to `Dockerfile`, `src/**`, `shared/src/**`, `gleam.toml`, `manifest.toml`, and `job_requirements.md`). You can also run it on demand from the Actions tab (`Deploy Backend to Cloud Run → Run workflow`).

---

## Auto-refresh on résumé changes

The bot bakes the résumé JSON into its image at **build time** (`gleam run -- fetch`), so the running service holds a snapshot from its last deploy. To make résumé edits propagate automatically, this deploy also accepts a `repository_dispatch` event of type `resume-updated`, and the source repo ([`c0ze/resume`](https://github.com/c0ze/resume)) fires it whenever its content changes.

**One-time setup:**

1. Create a **fine-grained PAT** scoped to **`c0ze/ai.arda.tr`** with **Contents: Read and write** (that scope authorizes the `POST /repos/{owner}/{repo}/dispatches` API).
2. In **`c0ze/resume`**, add it as the Actions secret **`BOT_DEPLOY_TOKEN`**.
3. `c0ze/resume`'s `notify-bot.yml` workflow then dispatches `resume-updated` to this repo whenever `content/**` changes, triggering a backend redeploy that re-fetches the latest résumé.

Until the PAT is set, refresh manually with `gh workflow run deploy-backend.yml` (or the Actions tab).
