# AI Resume Bot (ai.arda.tr)

A sarcastic, heavy metal-loving AI chatbot that answers questions about Arda's career. It uses Google's Gemini 2.5 Flash model.

## Architecture

*   **Frontend:** Static HTML/JS/CSS hosted on **GitHub Pages**.
*   **Backend:** Go (Golang) API hosted on **Google Cloud Run** (Tokyo Region).
*   **AI Model:** Google Gemini 2.5 Flash.

## Prerequisites

*   Google Cloud Project with Cloud Run enabled.
*   Gemini API Key.
*   `gcloud` CLI installed and authenticated.

## Local Development

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/your-username/ai.arda.tr.git
    cd ai.arda.tr
    ```

2.  **Create a `.env` file:**
    ```env
    GEMINI_API_KEY=your_actual_key
    GCP_PROJECT_ID=your_project_id
    GCP_REGION=asia-northeast1
    ```

3.  **Run the Backend:**
    ```bash
    go run main.go
    ```

4.  **Run the Frontend:**
    Open `public/index.html` in your browser. (Note: For local development, `public/script.js` defaults to `/api/chat`, so you might need to serve the frontend via the Go server or update the script to point to `http://localhost:8080`).

## Deployment

### 1. Deploy Backend (Cloud Run)

We use a helper script that reads from your `.env` file.

```bash
chmod +x cloud_deploy.sh
./cloud_deploy.sh
```

**Important:**
*   This deploys publicly (`--allow-unauthenticated`) so the frontend can access it.
*   Copy the **Service URL** from the output.

### 2. Deploy Frontend (GitHub Pages)

1.  Open `public/script.js`.
2.  Update `API_BASE_URL` with your Cloud Run Service URL:
    ```javascript
    const API_BASE_URL = "https://ai-arda-tr-api-xyz.a.run.app";
    ```
3.  Push changes to GitHub:
    ```bash
    git add public/script.js
    git commit -m "Update API endpoint"
    git push origin main
    ```
4.  The GitHub Actions workflow will automatically deploy to `ai.arda.tr`.

## License

MIT