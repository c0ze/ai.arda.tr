# AGENTS.md

This file provides guidance to coding agents working with this repository.

## Project Overview

AI Resume Bot - A personal AI-powered resume chatbot for ai.arda.tr. The bot answers questions about Arda's career, skills, experience, and personal interests (including his music) using Google's Gemini API. It is deliberately scoped to Arda: a guardrail in the system prompt makes it decline off-topic requests (coding, homework, general chat) rather than act as a general-purpose assistant.

## Architecture

- **Backend**: Gleam on the Erlang/OTP BEAM runtime (Wisp + Mist)
- **Frontend**: Gleam + [Lustre](https://lustre.build/) targeting JavaScript in [frontend/](frontend/); build output lands in [public/](public/), served by the Gleam backend locally and by GitHub Pages in production
- **AI**: Google Gemini (`gemini-3.5-flash` by default, configurable via `GEMINI_MODEL`)
- **Deployment**: Docker container on Google Cloud Run (backend), GitHub Pages (frontend)

## Project Structure

```
.
├── gleam.toml              # Gleam project manifest
├── manifest.toml           # Resolved dep lockfile
├── src/
│   ├── ai_resume_bot.gleam          # Entry point: CLI modes (fetch / server) + env loading
│   ├── ai_resume_bot_ffi.erl        # Tiny Erlang FFI (halt_flush, shell)
│   ├── ai_resume_bot_smtp_ffi.erl   # gen_smtp_client shim for contact emails
│   ├── ai_resume_bot_stream_ffi.erl # httpc SSE shim for Gemini streaming
│   ├── blog_cache_ffi.erl           # Single-slot ETS cache for recent blog posts
│   ├── rate_limit_ffi.erl           # ETS-backed per-IP rate-limit counters
│   └── ai_resume_bot/
│       ├── models.gleam    # Chat + resume types, JSON decoders
│       ├── resume.gleam    # Fetch c0ze/resume JSON + load from disk
│       ├── blog.gleam      # Fetch recent posts from RSS, cache + inject into prompt
│       ├── prompt.gleam    # System prompt builder
│       ├── gemini.gleam    # Direct REST client for generativelanguage.googleapis.com
│       ├── gemini_stream.gleam      # Streaming (SSE) Gemini client
│       ├── email.gleam     # [[SEND_EMAIL]] tag extract + sanitize
│       ├── smtp.gleam      # SMTP delivery wrapper over the FFI
│       ├── rate_limit.gleam         # Per-IP rate limiting over the ETS FFI
│       ├── server.gleam    # Wisp handler: CORS, /api/chat, static serving
│       ├── stream_handler.gleam     # Raw Mist handler for /api/chat/stream (SSE)
│       └── dotenv.gleam    # Minimal .env loader (real env vars win)
├── test/
│   └── ai_resume_bot_test.gleam     # gleeunit tests (prompt + email)
├── frontend/               # Lustre (Gleam -> JS) frontend project
│   ├── gleam.toml          # target = "javascript", [tools.lustre.*] config
│   └── src/
│       ├── frontend.gleam  # Lustre app: init/update/view, API effect, FFI
│       ├── frontend/i18n.gleam    # EN/JP translations + quick-prompt strings
│       ├── frontend/icons.gleam   # Inline SVG icons (via element.unsafe_raw_html)
│       └── ffi.mjs         # localStorage, matchMedia, marked+DOMPurify, scroll
├── public/                 # Hand-written style.css + favicon + CNAME + built Lustre bundle
├── data/                   # Resume JSON fetched from c0ze/resume
├── Dockerfile              # BEAM release on erlang:28-alpine
├── cloud_deploy.sh         # gcloud run deploy wrapper, reads .env
└── .github/workflows/      # CI/CD for backend and UI
```

## Common Commands

```sh
# Install pinned erlang/rebar/gleam toolchain from .mise.toml
mise install

# Local dev: requires GEMINI_API_KEY + ALLOWED_ORIGINS in .env at repo root
gleam deps download
gleam run                   # builds Lustre bundle into ./public then boots HTTP server on $PORT (default 8080)
gleam run -- fetch          # refresh resume JSON into ./data
gleam test                  # pure-logic tests (backend only)

# `gleam run` detects frontend/gleam.toml and shells out to
# `gleam run -m lustre/dev build --minify --outdir=../public` inside frontend/
# before starting the server. In the production Docker runtime stage the
# frontend/ tree is absent, so the check is a no-op and the bundle is baked
# in by an earlier build stage.

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
| `GEMINI_MODEL` | no | `gemini-3.5-flash` | Gemini model id |
| `LOG_REQUESTS` | no | off | Per-request logs; off in prod, on in local `.env` |
| `RATE_LIMIT_REQUESTS` | no | `30` | Max chat requests per window per client IP |
| `RATE_LIMIT_WINDOW_SECONDS` | no | `60` | Rate-limit window length, in seconds |
| `BLOG_FEED_URL` | no | `https://blog.arda.tr/rss.xml` | RSS feed for the "recent posts" prompt section |
| `BLOG_REFRESH_SECONDS` | no | `21600` | Background refresh interval for the feed (default 6h) |
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
4. `prompt.build` compiles the system prompt. It opens with a scope guardrail (`scope_guardrail` in [prompt.gleam](src/ai_resume_bot/prompt.gleam)) that confines the bot to Arda-related topics, then the résumé sections. A curated [personal.md](personal.md) (interests, music, hobbies — beyond the résumé) is appended if present, then `job_requirements.md` if present, along with the `[[SEND_EMAIL]]` instructions. Both files are baked into the Docker image and read at startup (see `maybe_append_personal` / `maybe_append_job_requirements` in [ai_resume_bot.gleam](src/ai_resume_bot.gleam)).

### API
- `POST /api/chat` → `{"message": "...", "history": [...]}` → `{"reply": "..."}` (non-streaming).
- `POST /api/chat/stream` → same request body → SSE stream of `{type, ...}` events (streaming).
  - SSE events: `thinking` → `chunk` (text delta) → `done` (full reply) or `error`.
  - Handled at the raw Mist level (Wisp cannot do streaming responses).
- `GET /*` → static files from `PUBLIC_DIR`.
- Error shapes: 400 `Invalid JSON`, 500 `Internal AI Error`, 502 contact-email failure.

### Gemini Client
- Direct REST calls to `generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`.
- Streaming variant uses `streamGenerateContent?alt=sse` via Erlang FFI (`ai_resume_bot_stream_ffi.erl`).
- No SDK dependency. System instruction passed via `system_instruction`, history as `contents`.
- The base system prompt is built once at startup; a per-request dynamic block (recent blog posts) is appended via `gemini.with_context` so the static prompt stays cached while the recent section stays fresh.

### Recent Blog Posts
- `blog.gleam` fetches `BLOG_FEED_URL` (default `blog.arda.tr/rss.xml`), parses the newest 3 items, and stores a markdown snippet in a single-slot ETS cache (`blog_cache_ffi.erl`). The initial fetch is **synchronous at startup** (bounded by a 5s timeout) so the first request — even a cold-start one — has the posts; subsequent refreshes run every `BLOG_REFRESH_SECONDS` (default 6h) in an **unlinked** background process. The cache is overwritten each refresh, so it never grows; state is in-memory only (Cloud Run is ephemeral — a fresh instance just re-populates it). Each fetch logs its outcome.
- Handlers read `blog.current()` per request and append it to the system instruction, so "what is Arda working on recently?" is answered from the latest posts. Fetch/parse failures keep the last good snippet (or omit the section entirely), so a feed outage never breaks chat.

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
