# Backend Deployment Options (Google Cloud Run)

You have two main ways to deploy the Go backend.

## Option 1: Manual Deployment (from Local)
**Best for:** Rapid testing, simple setup, no CI/CD overhead.

1.  **Authenticate:**
    ```bash
    gcloud auth login
    gcloud config set project YOUR_PROJECT_ID
    ```

2.  **Deploy:**
    Run this command in the root of your project:
    ```bash
    gcloud run deploy ai-arda-tr-api \
      --source . \
      --platform managed \
      --region asia-northeast1 \
      --allow-unauthenticated \
      --set-env-vars GEMINI_API_KEY=your_key_here
    ```

3.  **Finalize:**
    - Copy the URL provided in the output.
    - Paste it into `public/script.js` as the `API_BASE_URL`.
    - Push the change to `public/script.js` to update the live frontend.

---
      # --allow-unauthenticated is REQUIRED because your frontend is a public website.
      # Without this, Cloud Run would require a Google IAM login for every visitor.

## Option 2: Automated Deployment (GitHub Actions)
**Best for:** Professional workflow, automatic updates on push.

**Security:** We use **Workload Identity Federation**, which allows GitHub Actions to authenticate without storing long-lived service account keys (JSON files).

### Setup Steps

1.  **Google Cloud Setup (One-time):**
    Run these commands locally to set up the trust:

    ```bash
    # Variables
    export PROJECT_ID="your-project-id"
    export SERVICE_ACCOUNT="github-deployer"

    # 1. Create Service Account
    gcloud iam service-accounts create $SERVICE_ACCOUNT

    # 2. Grant Permissions (Cloud Run Admin & Artifact Registry Admin)
    gcloud projects add-iam-policy-binding $PROJECT_ID \
      --member="serviceAccount:$SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com" \
      --role="roles/run.admin"
    
    gcloud projects add-iam-policy-binding $PROJECT_ID \
      --member="serviceAccount:$SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com" \
      --role="roles/iam.serviceAccountUser"
      
    gcloud projects add-iam-policy-binding $PROJECT_ID \
        --member="serviceAccount:$SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com" \
        --role="roles/artifactregistry.admin"

    # 3. Create Workload Identity Pool
    gcloud iam workload-identity-pools create "github-pool" \
      --location="global" \
      --display-name="GitHub Pool"

    # 4. Create Provider
    gcloud iam workload-identity-pools providers create-oidc "github-provider" \
      --location="global" \
      --workload-identity-pool="github-pool" \
      --display-name="GitHub Provider" \
      --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
      --issuer-uri="https://token.actions.githubusercontent.com"

    # 5. Allow Repository to Impersonate Service Account
    # REPLACE "user/repo" with your actual "username/repository-name"
    gcloud iam service-accounts add-iam-policy-binding "$SERVICE_ACCOUNT@$PROJECT_ID.iam.gserviceaccount.com" \
      --role="roles/iam.workloadIdentityUser" \
      --member="principalSet://iam.googleapis.com/projects/$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')/locations/global/workloadIdentityPools/github-pool/attribute.repository/akara/ai.arda.tr"
    ```

2.  **GitHub Secrets:**
    Go to `Settings > Secrets and variables > Actions` and add:
    - `GCP_PROJECT_ID`: Your Google Cloud Project ID.
    - `GCP_SA_EMAIL`: `github-deployer@YOUR_PROJECT_ID.iam.gserviceaccount.com`
    - `GCP_WIF_PROVIDER`: The full provider path. You can get it with:
      ```bash
      gcloud iam workload-identity-pools providers describe github-provider \
        --location=global \
        --workload-identity-pool=github-pool \
        --format="value(name)"
      ```
    - `GEMINI_API_KEY`: Your actual Gemini API key.

3.  **Workflow File:**
    Create `.github/workflows/deploy-backend.yml` (I can create this for you if you choose this path).