# AI Resume Bot (ai.arda.tr)

A chatbot that answers questions about Arda's career, backed by Google's Gemini API.

## Architecture

- **Backend**: Gleam on the Erlang/OTP BEAM runtime (Wisp + Mist), hosted on **Google Cloud Run** (Tokyo).
- **Frontend**: Gleam + [Lustre](https://lustre.build/) targeting JavaScript, sources in [frontend/](frontend/). The build emits a minified bundle into [public/](public/) (alongside the hand-written [public/style.css](public/style.css)), which is served by the Gleam backend locally and by **GitHub Pages** in production.
- **AI Model**: Google Gemini (`gemini-3.5-flash` by default, configurable via `GEMINI_MODEL`).

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
   # GEMINI_MODEL=gemini-3.5-flash
   # GMAIL_USER=...                 # contact-email handoff (optional)
   # GMAIL_APP_PASSWORD=...
   # CONTACT_ADDRESS=...
   ```
   Real process env vars always override `.env` values.

3. **Run the backend (also builds the frontend):**
   ```sh
   gleam deps download
   gleam run                # builds the Lustre bundle into ./public, then boots HTTP server on $PORT (default 8080)
   gleam run -- fetch       # just refresh resume JSON under ./data and exit
   gleam test               # pure-logic tests (prompt + email extraction)
   ```
   `gleam run` detects [frontend/gleam.toml](frontend/gleam.toml) and runs `lustre/dev build --minify --outdir=../public` as a prerequisite. In the production Docker image the `frontend/` tree is not copied into the runtime stage, so this check is a no-op there and the bundle is produced by an earlier Docker stage instead. For HMR-style dev you can still run `gleam run -m lustre/dev start` from inside [frontend/](frontend/) — it proxies `/api` to `http://localhost:8080` (see `[tools.lustre.dev]` in [frontend/gleam.toml](frontend/gleam.toml)).

4. **Open the app:**

   http://localhost:8080/ — the Gleam backend serves the Lustre-built bundle from [public/](public/) and the API on the same port. The frontend auto-detects `localhost` and uses the same-origin `/api/chat`, so no config is needed.

## Deployment

### Backend — Cloud Run

```sh
chmod +x cloud_deploy.sh
./cloud_deploy.sh
```

Reads `GCP_PROJECT_ID`, `GEMINI_API_KEY`, `ALLOWED_ORIGINS`, and optional `GMAIL_*` / `CONTACT_ADDRESS` from `.env`, then runs `gcloud run deploy --source .` against the multi-stage [Dockerfile](Dockerfile): stage 1 builds the Lustre bundle, stage 2 compiles the Gleam backend into an Erlang release, stage 3 is the slim runtime image.

The resume JSON is fetched at build time and baked into the image. The built frontend bundle is also baked in, so the single Cloud Run service can serve both.

### Frontend — GitHub Pages

[.github/workflows/deploy-ui.yml](.github/workflows/deploy-ui.yml) installs the Gleam toolchain, runs `lustre/dev build --minify --outdir=../public` from [frontend/](frontend/), and publishes [public/](public/) to GitHub Pages. In production the frontend hits the hard-coded Cloud Run URL (see `cloud_run_base` in [frontend/src/frontend.gleam](frontend/src/frontend.gleam)).

## Environment Variables

| Var | Required | Default | Purpose |
|---|---|---|---|
| `GEMINI_API_KEY` | yes | — | Google Gemini API key |
| `ALLOWED_ORIGINS` | yes | — | Semicolon-delimited CORS allowlist |
| `PORT` | no | `8080` | HTTP listen port |
| `PUBLIC_DIR` | no | `./public` | Static asset directory |
| `GEMINI_MODEL` | no | `gemini-3.5-flash` | Gemini model id |
| `LOG_REQUESTS` | no | off | `true`/`1`/`yes`/`on` enables per-request logs |
| `RATE_LIMIT_REQUESTS` | no | `30` | Max chat requests per window per client IP |
| `RATE_LIMIT_WINDOW_SECONDS` | no | `60` | Rate-limit window length, in seconds |
| `GMAIL_USER` | no | — | SMTP user for contact-email handoff |
| `GMAIL_APP_PASSWORD` | no | — | SMTP app password |
| `CONTACT_ADDRESS` | no | `GMAIL_USER` | Recipient of contact emails |

## License

MIT
