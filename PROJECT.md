# AGENTS.md

This file provides guidance to coding agents working with this repository.

## Project Overview

AI Resume Bot - A personal AI-powered resume chatbot for ai.arda.tr. The bot answers questions about Arda's career, skills, experience, and personal interests (including his music) using Google's Gemini API. It is deliberately scoped to Arda: a guardrail in the system prompt makes it decline off-topic requests (coding, homework, general chat) rather than act as a general-purpose assistant.

## Architecture

- **Backend**: Gleam on the Erlang/OTP BEAM runtime (Wisp + Mist)
- **Frontend**: Gleam + [Lustre](https://lustre.build/) targeting JavaScript in [frontend/](frontend/); build output lands in [public/](public/), served by the Gleam backend locally and by GitHub Pages in production
- **AI**: Google Gemini (`gemini-3.5-flash` by default, configurable via `GEMINI_MODEL`)
- **Voice**: Google Cloud Text-to-Speech (Standard voices), streamed alongside the text on request (see [Voice replies](#voice-replies))
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
│   ├── ai_resume_bot_tts_ffi.erl    # TTS token / availability cache (persistent_term), crash guard
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
│       ├── speech.gleam    # Voice: sentence splitter, markdown → words, SSML marks, raw offsets (pure)
│       ├── voice.gleam     # Voice: per-reply session, bounded synthesis, in-order speech events (pure)
│       ├── tts.gleam       # Voice: Cloud Text-to-Speech client (metadata-server auth) + mock
│       └── dotenv.gleam    # Minimal .env loader (real env vars win)
├── test/
│   ├── ai_resume_bot_test.gleam     # gleeunit tests (prompt, email, SSE parsing, rate limit, blog)
│   ├── speech_test.gleam            # splitter / markdown stripper / UTF-16 offsets (EN, TR, JA)
│   └── voice_test.gleam             # speech session with a mocked TTS, TTS wire format, request compat
├── frontend/               # Lustre (Gleam -> JS) frontend project
│   ├── gleam.toml          # target = "javascript", [tools.lustre.*] config
│   └── src/
│       ├── frontend.gleam  # Lustre app: init/update/view, API effect, FFI
│       ├── frontend/i18n.gleam    # EN/JP/TR translations + quick-prompt strings
│       ├── ffi.mjs         # localStorage, marked+DOMPurify, scroll, SSE client, orb/cursor mounting, speaker glue
│       ├── onebit.mjs      # Verbatim copy of design-previews/onebit/onebit.js (1-bit orb + crackle); do not fork
│       └── voice.mjs       # Verbatim copy of design-previews/onebit/voice.js (speech playback + reveal); do not fork
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
# Frontend transport regressions (Node 24; no npm dependencies):
(cd frontend && gleam build && node --test test/*.test.mjs)

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
| `VOICE_ENABLED` | no | `true` | Offer voice replies (`false`/`0`/`off` disables; clients then get `voice: false`) |
| `TTS_VOICE_EN` / `TTS_VOICE_TR` / `TTS_VOICE_JA` | no | `en-US-Standard-D` / `tr-TR-Standard-E` / `ja-JP-Standard-C` | Cloud TTS voice per language |
| `TTS_PITCH` | no | `-4` | Semitones |
| `TTS_SPEAKING_RATE` | no | `0.92` | 1.0 = normal |
| `VOICE_MAX_CHARS` | no | `1200` | Spoken characters per reply; the rest is revealed after the audio |
| `TTS_BACKEND` | no | `google` | `mock` = generated WAV tones with fake marks, for local end-to-end runs |
| `TTS_ACCESS_TOKEN` / `TTS_QUOTA_PROJECT` | dev-only | — | Stand-ins for the metadata server when running locally against the real API: `TTS_ACCESS_TOKEN=$(gcloud auth print-access-token) TTS_QUOTA_PROJECT=ai-resume-chatbot-479106`. Never set in production. |

`.env` is loaded from the repo root (or parent). Real process env vars always override `.env` values, so production Cloud Run settings cannot be shadowed by a stray local file.

## Key Implementation Details

### Resume Data Flow
1. At build time (Docker) or on first startup, resume JSON is fetched from GitHub (`c0ze/resume`).
2. Data is cached to `./data/`.
3. On boot, `resume.load_from_disk` reads and decodes all five files.
4. `prompt.build` compiles the system prompt. It opens with a scope guardrail (`scope_guardrail` in [prompt.gleam](src/ai_resume_bot/prompt.gleam)) that confines the bot to Arda-related topics, then the résumé sections. A curated [personal.md](personal.md) (interests, music, hobbies — beyond the résumé) is appended if present, then `job_requirements.md` if present, along with the `[[SEND_EMAIL]]` instructions. Both files are baked into the Docker image and read at startup (see `maybe_append_personal` / `maybe_append_job_requirements` in [ai_resume_bot.gleam](src/ai_resume_bot.gleam)).

### API
- `POST /api/chat` → `{"message": "...", "history": [...]}` → `{"reply": "..."}` (non-streaming).
- `POST /api/chat/stream` → same request body (+ optional `"voice": true, "lang": "en"|"ja"|"tr"`) → SSE stream of `{type, ...}` events (streaming).
  - SSE events: `thinking` → `chunk` (text delta) → `done` (full reply) or `error`.
  - With `voice: true`, `voice` / `speech` / `speech_end` events interleave, all before `done` (see [Voice replies](#voice-replies)). Without it the stream is byte-for-byte the text-only one.
  - The frontend accepts LF/CRLF framing, settles once on a valid terminal event,
    and reports truncated or stalled responses as errors (45s idle deadline), releasing
    the busy composer. Its transport tests run in CI and before UI publication.
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

### Frontend design (One Bit Forest)
- Follows the family design system (`../DESIGN-SYSTEM.md`, section ai.arda.tr). Styles are hand-written in `public/style.css`; bump `style.css?v=` in `frontend/gleam.toml` when it changes.
- Renditions: `night` (default), `night-hc`, `xerox`, `xerox-hc`, stored in localStorage `theme` and applied as `body[data-theme]`. Legacy ids migrate on read (`light`→xerox, `paper`→xerox-hc, `dark`→night, `carbon`→night-hc) in both the pre-hydration script (`frontend/gleam.toml`) and `theme_from_string` (`frontend.gleam`); keep the two in sync.
- The construct orb and the crackle cursor are canvases created by `ffi.mjs`, outside Lustre's vdom: the orb mounts into `#construct-orb` (a vnode with no children, so re-renders never touch it); the cursor is re-appended to the end of `.msg.is-streaming .txt` in a `before_paint` effect after each chunk. The orb sizzles on every chunk, simmers between `thinking` and the first chunk, and does neither under `prefers-reduced-motion`.
- `onebit.mjs` must stay byte-identical to `design-previews/onebit/onebit.js`, and `voice.mjs` to `design-previews/onebit/voice.js`; change the shared copy first.
- Voice: while a reply is spoken, the model's `speech` is `Speaking(msg_id, shown)` and the message renders `reveal_prefix(text, shown)` (UTF-16 prefix, with a half-typed link or `**` tidied). The cursor trails the revealed text, and the status reads `speaking…`. `done` no longer ends the cursor while the voice runs; `SpeechEnded` does. The `♪` toggle (`.voice-toggle`, next to the language switch) shows `♪ on/off` (localised). On phones it shows only `♪`, struck through when muted.

### Voice replies
The construct reads its replies aloud, in sync with the text. Protocol (types in `shared/src/shared.gleam`, `StreamEvent`):
- `{"type":"voice","on":bool}` right after `thinking`. `false` when `VOICE_ENABLED=false` or TTS is unavailable, so clients never wait for audio.
- `{"type":"speech","seq":n,"start":a,"end":b,"audio":base64|null,"mime":"audio/mpeg","marks":[{"o":offset,"t":seconds}]}`: one sentence, in `seq` order. `audio: null` = synthesis failed; the client reveals that sentence silently at its turn. Empty `marks` = reveal linearly over the clip.
- `{"type":"speech_end","upto":offset}`: no more audio; text past `upto` (over the cap, code blocks, the `[[SEND_EMAIL]]` block) is revealed after the audio.
- Offsets index the RAW reply (concatenated `chunk` texts) in UTF-16 code units (JS string indices).

Server pipeline ([stream_handler.gleam](src/ai_resume_bot/stream_handler.gleam) → [voice.gleam](src/ai_resume_bot/voice.gleam) → [speech.gleam](src/ai_resume_bot/speech.gleam) → [tts.gleam](src/ai_resume_bot/tts.gleam)):
- Chunks are cut into sentences (`. ! ?` + whitespace, `。！？`, newlines, a 220-unit clause cap); markdown is stripped (emphasis, code ticks, headings, list markers; links read as their label, bare URLs as their domain; code fences skipped) while every word keeps its raw end offset. The reply's language follows the UI `lang`, switching to Japanese on kana/kanji and to Turkish on ş/ğ/ı/İ.
- SSML puts a `<mark/>` after each word. For Japanese the marks go at punctuation and where a kana run meets kanji/katakana. Marks inside words make the voice pause (measured +17% duration), so Japanese is deliberately not marked every 2–3 characters.
- `v1beta1/text:synthesize`, `enableTimePointing: [SSML_MARK]`, MP3 24 kHz, pitch −4 st, rate 0.92. At most 3 sentences are synthesised at once, by unlinked worker processes; events go out in order. A 400 is retried without marks. A 403/429 (or no token) marks TTS unavailable for 10 minutes. `done` is held until `speech_end` has been sent, because clients stop reading at `done`.
- Auth: the Cloud Run service identity. The access token comes from the metadata server and is cached until 2 minutes before expiry; no keys or secrets. The service runs as the default compute SA `599610058688-compute@developer.gserviceaccount.com`, which has `roles/editor` (checked 2026-09-23). That is enough for Text-to-Speech. If the service ever moves to a dedicated SA, give it `roles/serviceusage.serviceUsageConsumer`. The Text-to-Speech API must be enabled on `ai-resume-chatbot-479106` (it is).
- Startup logs `Voice on: TTS reachable, voices …` or a warning (checked via the voices API).
- Voices: the lowest male Standard voice per language by measured f0 at −4 st. en-US-Standard-D (~99 Hz), tr-TR-Standard-E (~92 Hz), ja-JP-Standard-C (~120 Hz). All return mark timepoints. Change them via the `TTS_VOICE_*` env vars (a new deploy or `gcloud run services update --update-env-vars`). Free tier: 4M Standard chars/month; replies cap at `VOICE_MAX_CHARS`.

Client ([voice.mjs](frontend/src/voice.mjs), master copy `design-previews/onebit/voice.js`, reused by the arda.tr / resume.arda.tr widgets): `unlockAudio()` in the send gesture; `createSpeaker({onReveal, onLevel, onEnd})` per reply, fed every SSE event. The robot chain: ring modulator (58 Hz sine, 55% wet / 45% dry) → bit-crush (16-step staircase blended 40%) → 5.2 kHz low-pass → metallic comb (4.5 ms, 0.42 feedback, 35% mix) → 0.95 gain → limiter (−6 dB, 12:1) → analyser. Offline renders of real clips peak at 0.86–0.92, with RMS within ~2 dB of the dry voice. Voice is on by default; the `♪` toggle in the bar mutes it (localStorage `voice` = `on`/`off`). A muted request carries no voice fields.

Local end-to-end: `TTS_BACKEND=mock gleam run` (real Gemini, fake audio), or against the real API with `TTS_ACCESS_TOKEN` / `TTS_QUOTA_PROJECT` as above.

### CORS
- Origins validated against `ALLOWED_ORIGINS`, delimited by `;`.
- Only the echoed `Access-Control-Allow-Origin` is set; preflight `OPTIONS` returns 200 with full CORS headers.
- [cloud_deploy.sh](cloud_deploy.sh) refuses to deploy if `ALLOWED_ORIGINS` is missing.

## Deployment

- **Backend**: `./cloud_deploy.sh` or `.github/workflows/deploy-backend.yml` → Cloud Run (`ai-arda-tr-api`, asia-northeast1)
- **Frontend**: Push to `main` triggers `.github/workflows/deploy-ui.yml` → GitHub Pages
- Cloud Run URL: `https://ai-arda-tr-api-599610058688.asia-northeast1.run.app`


<!-- ============================================================
UNRECONCILED — 6 lines that existed only in CLAUDE.md when CLAUDE.md and
AGENTS.md were consolidated (2026-08-08). Fold anything useful into the
sections above, then delete this block.
============================================================ -->

Claude Code there.
# CLAUDE.md
guidance (stack, architecture, project structure, env vars, the blog-RSS
prompt section, the `[[SEND_EMAIL]]` contact handoff, CORS, and deployment).
Read **AGENTS.md** first — it is canonical. This file only exists to point
This repository uses **[AGENTS.md](./AGENTS.md)** as the single source of agent
