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

The bot bakes the résumé JSON into its image at **build time** (`gleam run -- fetch`), so the running service holds a snapshot from its last deploy. `deploy-backend.yml` therefore runs on a **daily schedule** (`0 3 * * *`, 12:00 JST) so résumé edits propagate on their own. **No setup and no credentials.**

Staleness is bounded at 24 hours. After editing the résumé, refresh immediately with:

```bash
gh workflow run deploy-backend.yml --repo c0ze/ai.arda.tr
```

### Why not a push notification

This used to be a `repository_dispatch` of type `resume-updated`, fired by [`c0ze/resume`](https://github.com/c0ze/resume) and authenticated with a fine-grained PAT in a `BOT_DEPLOY_TOKEN` secret. The PAT was minted 2026-06-06 with a 30-day expiry, died around 2026-07-06, and **nothing surfaced it for six weeks** — the sending workflow only ran on résumé content pushes, so the bot quietly answered visitors from a stale résumé until an unrelated change happened to trigger it again.

The obvious fix is keyless auth, and this repo already does that for GCP — the deploy authenticates by Workload Identity Federation with no stored key. But GitHub's own API **does not accept GitHub Actions OIDC tokens**; they federate to external providers only. So a GitHub→GitHub `repository_dispatch` always needs a bearer credential: a PAT that expires, or a GitHub App whose private key does not.

A schedule needs neither. The credential was removed rather than rotated, which is why there is nothing here to expire.

**Cost note:** this deploy builds the container from source (`source: '.'`), so a scheduled run is a full Cloud Build image build, push and deploy — not a lightweight restart. At daily that is ~365 builds and 365 stored images a year for a document that changes a handful of times. If Artifact Registry storage grows, either widen the cron to weekly (`0 3 * * 1`) or add an Artifact Registry cleanup policy.
