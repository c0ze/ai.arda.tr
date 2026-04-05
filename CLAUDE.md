# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

AI Resume Bot - A personal AI-powered resume chatbot for ai.arda.tr. The bot answers questions about Arda's career, skills, and experience using Google's Gemini API.

## Architecture

- **Backend**: Gleam on the Erlang/OTP BEAM runtime (Wisp + Mist)
- **Frontend**: Vanilla HTML/CSS/JavaScript in [public/](public/), served by the Gleam backend locally and by GitHub Pages in production
- **AI**: Google Gemini (`gemini-3-flash-preview` by default, configurable via `GEMINI_MODEL`)
- **Deployment**: Docker container on Google Cloud Run (backend), GitHub Pages (frontend)

## Project Structure

```
.
├── gleam.toml              # Gleam project manifest
├── manifest.toml           # Resolved dep lockfile
├── src/
│   ├── ai_resume_bot.gleam          # Entry point: CLI modes (fetch / server) + env loading
│   ├── ai_resume_bot_ffi.erl        # Tiny Erlang FFI (halt_flush)
│   ├── ai_resume_bot_smtp_ffi.erl   # gen_smtp_client shim for contact emails
│   └── ai_resume_bot/
│       ├── models.gleam    # Chat + resume types, JSON decoders
│       ├── resume.gleam    # Fetch c0ze/resume JSON + load from disk
│       ├── prompt.gleam    # System prompt builder
│       ├── gemini.gleam    # Direct REST client for generativelanguage.googleapis.com
│       ├── email.gleam     # [[SEND_EMAIL]] tag extract + sanitize
│       ├── smtp.gleam      # SMTP delivery wrapper over the FFI
│       ├── server.gleam    # Wisp handler: CORS, /api/chat, static serving
│       └── dotenv.gleam    # Minimal .env loader (real env vars win)
├── test/
│   └── ai_resume_bot_test.gleam     # gleeunit tests (prompt + email)
├── public/                 # Static frontend (served by Wisp, or GitHub Pages)
├── data/                   # Resume JSON fetched from c0ze/resume
├── Dockerfile              # BEAM release on erlang:27-alpine
├── cloud_deploy.sh         # gcloud run deploy wrapper, reads .env
└── .github/workflows/      # CI/CD for backend and UI
```

## Common Commands

```sh
# Install pinned erlang/rebar/gleam toolchain from .mise.toml
mise install

# Local dev: requires GEMINI_API_KEY + ALLOWED_ORIGINS in .env at repo root
gleam deps download
gleam run                   # HTTP server on $PORT (default 8080)
gleam run -- fetch          # refresh resume JSON into ./data
gleam test                  # pure-logic tests

# Build Docker image
docker build -t ai-resume-bot .

# Run Docker container
docker run -p 8080:8080 \
  -e GEMINI_API_KEY=your_key \
  -e ALLOWED_ORIGINS=http://localhost:8080 \
  ai-resume-bot
```

## Environment Variables

| Var | Required | Default | Purpose |
|---|---|---|---|
| `GEMINI_API_KEY` | yes | — | Google Gemini API key |
| `ALLOWED_ORIGINS` | yes | — | Semicolon-delimited CORS allowlist |
| `PORT` | no | `8080` | HTTP listen port |
| `PUBLIC_DIR` | no | `./public` | Static asset directory |
| `GEMINI_MODEL` | no | `gemini-3-flash-preview` | Gemini model id |
| `LOG_REQUESTS` | no | off | Per-request logs; off in prod, on in local `.env` |
| `GMAIL_USER` | no | — | SMTP user for contact handoff |
| `GMAIL_APP_PASSWORD` | no | — | SMTP app password |
| `CONTACT_ADDRESS` | no | `GMAIL_USER` | Recipient of contact emails |
| `GCP_PROJECT_ID` | deploy-only | — | Required by [cloud_deploy.sh](cloud_deploy.sh) |

`.env` is loaded from the repo root (or parent). Real process env vars always override `.env` values, so production Cloud Run settings cannot be shadowed by a stray local file.

## Key Implementation Details

### Resume Data Flow
1. At build time (Docker) or on first startup, resume JSON is fetched from GitHub (`c0ze/resume`).
2. Data is cached to `./data/`.
3. On boot, `resume.load_from_disk` reads and decodes all five files.
4. `prompt.build` compiles the system prompt; if `job_requirements.md` exists, it is appended along with the `[[SEND_EMAIL]]` instructions.

### API
- `POST /api/chat` → `{"message": "...", "history": [...]}` → `{"reply": "..."}`.
- `GET /*` → static files from `PUBLIC_DIR`.
- Error shapes: 400 `Invalid JSON`, 500 `Internal AI Error`, 502 contact-email failure.

### Gemini Client
- Direct REST calls to `generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`.
- No SDK dependency. System instruction passed via `system_instruction`, history as `contents`.

### Contact Email Handoff
- Gemini emits a `[[SEND_EMAIL]]{...JSON...}[[/SEND_EMAIL]]` block in its reply.
- `email.extract` parses the payload, strips the tags, sanitizes header-injection vectors.
- `smtp.send` dispatches via the `gen_smtp_client` Erlang shim.
- Without SMTP configuration (`GMAIL_*`), the user gets `contact_failure_message` and an error log.

### CORS
- Origins validated against `ALLOWED_ORIGINS`, delimited by `;`.
- Only the echoed `Access-Control-Allow-Origin` is set; preflight `OPTIONS` returns 200 with full CORS headers.
- [cloud_deploy.sh](cloud_deploy.sh) refuses to deploy if `ALLOWED_ORIGINS` is missing.

## Deployment

- **Backend**: `./cloud_deploy.sh` or `.github/workflows/deploy-backend.yml` → Cloud Run (`ai-arda-tr-api`, asia-northeast1)
- **Frontend**: Push to `main` triggers `.github/workflows/deploy-ui.yml` → GitHub Pages
- Cloud Run URL: `https://ai-arda-tr-api-599610058688.asia-northeast1.run.app`
