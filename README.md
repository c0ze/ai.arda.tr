# AI Resume Bot (ai.arda.tr)

A chatbot that answers questions about Arda's career, backed by Google's Gemini API.

## Architecture

- **Backend**: Gleam on the Erlang/OTP BEAM runtime (Wisp + Mist), hosted on **Google Cloud Run** (Tokyo).
- **Frontend**: Static HTML/CSS/JS in [public/](public/), served by the Gleam backend locally and by **GitHub Pages** in production.
- **AI Model**: Google Gemini (`gemini-3-flash-preview` by default, configurable via `GEMINI_MODEL`).

## Prerequisites

- [mise](https://mise.jdx.dev/) — installs the pinned Erlang/OTP, rebar3, and Gleam toolchain via [.mise.toml](.mise.toml).
- A Google Gemini API key.
- `gcloud` CLI (only for deployment).

## Local Development

1. **Install the toolchain:**
   ```sh
   mise install
   ```

2. **Create a `.env` file at the repo root:**
   ```env
   GEMINI_API_KEY=your_actual_key
   ALLOWED_ORIGINS=https://ai.arda.tr;http://localhost:8080
   # Optional:
   # PORT=8080
   # LOG_REQUESTS=true              # per-request logs, off in prod by default
   # GEMINI_MODEL=gemini-3-flash-preview
   # GMAIL_USER=...                 # contact-email handoff (optional)
   # GMAIL_APP_PASSWORD=...
   # CONTACT_ADDRESS=...
   ```
   Real process env vars always override `.env` values.

3. **Run the backend:**
   ```sh
   gleam deps download
   gleam run                # boot HTTP server on $PORT (default 8080)
   gleam run -- fetch       # just refresh resume JSON under ./data and exit
   gleam test               # pure-logic tests (prompt + email extraction)
   ```

4. **Open the app:**

   http://localhost:8080/ — the Gleam backend serves the frontend from [public/](public/) and the API on the same port. [public/script.js](public/script.js) auto-detects `localhost` and uses the same-origin `/api/chat`, so no frontend config is needed.

## Deployment

### Backend — Cloud Run

```sh
chmod +x cloud_deploy.sh
./cloud_deploy.sh
```

Reads `GCP_PROJECT_ID`, `GEMINI_API_KEY`, `ALLOWED_ORIGINS`, and optional `GMAIL_*` / `CONTACT_ADDRESS` from `.env`, then runs `gcloud run deploy --source .` against the Gleam [Dockerfile](Dockerfile).

The resume JSON is fetched at build time and baked into the image. The static frontend in [public/](public/) is also baked in, so the single Cloud Run service can serve both.

### Frontend — GitHub Pages

The static bundle in [public/](public/) is deployed to GitHub Pages by [.github/workflows/deploy-ui.yml](.github/workflows/deploy-ui.yml). For production, [public/script.js](public/script.js) uses the hard-coded Cloud Run URL in `API_BASE_URL`.

## Environment Variables

| Var | Required | Default | Purpose |
|---|---|---|---|
| `GEMINI_API_KEY` | yes | — | Google Gemini API key |
| `ALLOWED_ORIGINS` | yes | — | Semicolon-delimited CORS allowlist |
| `PORT` | no | `8080` | HTTP listen port |
| `PUBLIC_DIR` | no | `./public` | Static asset directory |
| `GEMINI_MODEL` | no | `gemini-3-flash-preview` | Gemini model id |
| `LOG_REQUESTS` | no | off | `true`/`1`/`yes`/`on` enables per-request logs |
| `GMAIL_USER` | no | — | SMTP user for contact-email handoff |
| `GMAIL_APP_PASSWORD` | no | — | SMTP app password |
| `CONTACT_ADDRESS` | no | `GMAIL_USER` | Recipient of contact emails |

## License

MIT
