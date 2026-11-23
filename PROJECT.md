# PROJECT.md

The handoff document for this repository: architecture, constraints, key files, and how to run and validate. Rules for agents are in [CLAUDE.md](CLAUDE.md) (= `AGENTS.md`).

## Project Overview

AI Resume Bot - A personal AI-powered resume chatbot for ai.arda.tr. The bot answers questions about Arda's career, skills, experience, and personal interests (including his music) using Google's Gemini API. It is deliberately scoped to Arda: a guardrail in the system prompt makes it decline off-topic requests (coding, homework, general chat) rather than act as a general-purpose assistant.

## Architecture

- **Backend**: Gleam on the Erlang/OTP BEAM runtime (Wisp + Mist)
- **Frontend**: Gleam + [Lustre](https://lustre.build/) targeting JavaScript in [frontend/](frontend/); build output lands in [public/](public/), served by the Gleam backend locally and by GitHub Pages in production
- **AI**: Google Gemini (`gemini-3.5-flash` by default, configurable via `GEMINI_MODEL`)
- **Voice**: English replies only. Google Cloud Text-to-Speech (Standard voices), streamed alongside the text on request; or, when the visitor opts in, Phonon running in their browser (see [Voice replies](#voice-replies))
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
│       ├── guard.gleam     # Request checks for both chat endpoints: origin, content type, size limits
│       ├── server.gleam    # Wisp handler: CORS, /api/chat, /healthz, static serving
│       ├── stream_handler.gleam     # Raw Mist handler for /api/chat/stream (SSE)
│       ├── speech.gleam    # Voice: sentence splitter, markdown → words, SSML marks, raw offsets (pure)
│       ├── voice.gleam     # Voice: per-reply session, bounded synthesis, in-order speech events (pure)
│       ├── tts.gleam       # Voice: Cloud Text-to-Speech client (metadata-server auth) + mock
│       └── dotenv.gleam    # Minimal .env loader (real env vars win)
├── test/
│   ├── ai_resume_bot_test.gleam     # gleeunit tests (prompt, email, SSE parsing, rate limit, blog)
│   ├── email_reply_test.gleam       # several [[SEND_EMAIL]] blocks: only the first is sent, none is shown (fake sender)
│   ├── guard_test.gleam             # request limits, invisible-only messages, header checks, declared bodies
│   ├── server_test.gleam            # Wisp handler: 400/403/405/413/415/429, connection: close, CORS, /healthz, HEAD (never reaches Gemini)
│   ├── speech_test.gleam            # splitter / markdown stripper / UTF-16 offsets (EN, TR, JA)
│   ├── stream_body_test.gleam       # stream path: chunked body limit, pre-body rejections close the connection
│   ├── stream_events_test.gleam     # SSE actor driven without a socket: thinking/voice at start, chunks
│   └── voice_test.gleam             # speech session with a mocked TTS, TTS wire format, request compat
├── frontend/               # Lustre (Gleam -> JS) frontend project
│   ├── gleam.toml          # target = "javascript", [tools.lustre.*] config
│   ├── test/               # node --test: ffi.test.mjs (transport, markdown sanitiser, voice level, scheme glue), app.test.mjs (update/view), page.test.mjs (the generated index.html: head, scheme boot script, stylesheets, fonts, noscript, JSON-LD; brand copies; style.css on tokens, the ember's picture)
│   └── src/
│       ├── frontend.gleam  # Lustre app: init/update/view, API effect, FFI
│       ├── frontend/i18n.gleam    # EN/JP/TR translations + quick-prompt strings
│       ├── frontend/wordmark.gleam # The arda.tr wordmark as inline SVG (the outline of public/brand/logo/wordmark.svg, one colour)
│       ├── ffi.mjs         # localStorage, scheme switch (window.ardaScheme), marked+DOMPurify, scroll, SSE client, speaker glue, the ember's --ix-level
│       ├── voice.mjs       # Verbatim copy of design-previews/onebit/voice.js (speech playback + reveal); do not fork
│       └── natural.mjs     # The natural English voice: Phonon in the browser (opt-in), sentence by sentence
├── public/                 # Hand-written style.css + favicon + CNAME + built Lustre bundle (frontend.js, index.html: generated, not committed)
│   ├── brand/              # Verbatim copies from arda.tr's brand/: arda.css (theme tokens), brand.css (ix- patterns), scheme.js, art/ (emblem, ember, wisp), logo/wordmark.svg
│   └── vendor/             # marked 18.0.5, DOMPurify 3.4.8, phonon-tts 0.7.1 (the engine only: single-threaded wasm + WebGPU; no model)
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
# Frontend tests (Node 24; no npm dependencies). There is no Gleam test module in
# frontend/: these Node tests drive the compiled Gleam.
(cd frontend && gleam build && node --test test/*.test.mjs)   # transport, app update/view, the generated page
# The bundle and index.html in ./public (generated, git-ignored); `gleam run` does this too:
(cd frontend && gleam run -m lustre/dev build --minify --outdir=../public)

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
| `ALLOWED_ORIGINS` | yes | — | Semicolon-delimited CORS allowlist; must include `https://arda.tr` and `https://resume.arda.tr` for their widgets. Other origins get 403 |
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
| `TTS_SPEAKING_RATE_JA` | no | `1.06` | Japanese speaking rate (Japanese speaks faster) |
| `VOICE_MAX_CHARS` | no | `1200` | Spoken characters per reply; the rest is revealed after the audio |
| `VOICE_MAX_CHARS_JA` | no | `400` | The same cap for Japanese replies |
| `TTS_BACKEND` | no | `google` | `mock` = generated WAV tones with fake marks, for local end-to-end runs |
| `TTS_ACCESS_TOKEN` / `TTS_QUOTA_PROJECT` | dev-only | — | Stand-ins for the metadata server when running locally against the real API: `TTS_ACCESS_TOKEN=$(gcloud auth print-access-token) TTS_QUOTA_PROJECT=ai-resume-chatbot-479106`. Never set in production. |

`.env` is loaded from the repo root (or parent). Real process env vars always override `.env` values, so production Cloud Run settings cannot be shadowed by a stray local file.

## Key Implementation Details

### Resume Data Flow
1. At build time (Docker) or on first startup, resume JSON is fetched from GitHub (`c0ze/resume`). The deployed image is rebuilt daily by the scheduled backend deploy, so a résumé edit reaches the bot within about a day.
2. Data is cached to `./data/`.
3. On boot, `resume.load_from_disk` reads and decodes all five files.
4. `prompt.build` compiles the system prompt. It opens with a scope guardrail (`scope_guardrail` in [prompt.gleam](src/ai_resume_bot/prompt.gleam)) that confines the bot to Arda-related topics, then the résumé sections. A curated [personal.md](personal.md) (interests, music, hobbies — beyond the résumé) is appended if present, then `job_requirements.md` if present, along with the `[[SEND_EMAIL]]` instructions (only when SMTP is configured; see [Contact Email Handoff](#contact-email-handoff)). Both files are baked into the Docker image and read at startup (see `maybe_append_personal` / `maybe_append_job_requirements` in [ai_resume_bot.gleam](src/ai_resume_bot.gleam)).

### API
- `POST /api/chat` → `{"message": "...", "history": [...]}` → `{"reply": "..."}` (non-streaming).
- `POST /api/chat/stream` → same request body (+ optional `"voice": true, "lang": "en"|"ja"|"tr"`) → SSE stream of `{type, ...}` events (streaming).
  - SSE events: `thinking` → `chunk` (text delta) → `done` (full reply) or `error`. A reply with no text ends in `error` (`Empty reply`), never a blank `done`; on `/api/chat` it is a 500.
  - With `voice: true`, `voice` / `speech` / `speech_end` events interleave, all before `done` (see [Voice replies](#voice-replies)). Without it the stream is byte-for-byte the text-only one.
  - The frontend accepts LF/CRLF framing, settles once on a valid terminal event,
    and reports truncated or stalled responses as errors (45s idle deadline), releasing
    the busy composer. Its transport tests run in CI and before UI publication.
  - Handled at the raw Mist level (Wisp cannot do streaming responses).
- `GET /healthz` (and `/health`, since Cloud Run's front end reserves some paths ending in `z`) → 200 `{"ok":true}`: no model call, no rate limit.
- `GET /*` → static files from `PUBLIC_DIR`. `HEAD` is answered like `GET`, without the body.
- Limits (`guard.gleam`, both endpoints): an empty `message`, or one with nothing visible in it (only Unicode whitespace such as NBSP or U+3000, control characters, and default-ignorable code points such as the zero-width space, joiners, BOM and bidi marks; format signs that draw a glyph, such as the Arabic number sign U+0600, count as text; `guard.is_blank`), gets 400 `Message is empty` (an accepted message is forwarded as sent), one over 20,000 characters (graphemes; `shared.max_message_chars`, also the input's `maxlength`, which counts UTF-16 units and so never allows more) 400 `Message is too long (at most 20000 characters)`. 20,000 leaves room for a pasted job description. History is capped to the last 20 items and each item is cut to 8000 characters (`shared.max_history_item_chars`), not rejected: the sibling widgets resend a rejected message as history, which would wedge their conversation. That trimming, not the body limit, bounds what reaches the model.
- Body limits (413 `Request body too large`): `/api/chat/stream` reads at most 1,000,000 bytes (`guard.max_stream_body_bytes`), counted as it reads, so a chunked body is limited too, except that the pinned Mist (6.0.2) assembles each HTTP chunk whole before handing it over, so a single oversized chunk is buffered in memory once before it is rejected. `/api/chat` reads up to Wisp's default, 8,000,000 bytes, as it always has. The sibling widgets send their whole conversation, uncapped, with every question, so a long one (70 turns of 2,500 Japanese characters is ~1.05 MB) can pass the stream's limit; after the stream's 413 they retry on `/api/chat`, which still reads it. On both endpoints the history is then trimmed (see Limits), and that, not the body limit, bounds what reaches the model.
- Body framing (`guard.check_framing`, both endpoints, before anything else): the policy is exactly one `Transfer-Encoding: chunked` (that exact value) or exactly one all-digit Content-Length, not both. Anything else (`Chunked`, `gzip`, `abc`, `+14`, both headers) gets 400 `Unsupported request framing` with `connection: close`. Mist reads `Chunked`, `gzip` or an unparseable length such as `abc` as an empty body and would leave the real one on the socket; `+14` would parse but is outside the policy; both headers at once is where a proxy and a server can disagree. Mist keeps one value per header name (the last one wins), so duplicate headers on the wire reach the check as one: the duplicate-header cases in the tests exercise the function, not wire-level protection. Browsers send a Content-Length.
- Connections: a response sent without reading a declared request body (Content-Length other than 0, or any Transfer-Encoding) carries `connection: close`, and Mist closes the socket after it, so the unread body is never parsed as a further request (one whose `X-Forwarded-For` the sender wrote): the 403/415/429 rejections, 405, the 413s, the framing 400 and the stream's 400 `Failed to read request body`, non-GET static requests (404), and GETs or preflights that carry a body (`guard.close_if_body_unread`). Requests without a body, and those whose body was read (200, 400), keep the connection.
- Header checks (`guard.check_headers`, both endpoints, before the rate limiter): a request whose `Origin` is neither in `ALLOWED_ORIGINS` nor the backend's own origin (its `Host`) gets 403 `Origin not allowed`; requests with no `Origin` (curl, server-side callers) pass. A body that is not `application/json` (a charset parameter is fine) gets 415 `Content-Type must be application/json`. All three clients send `Content-Type: application/json`.
- Rate limiting is per client IP (right-most `X-Forwarded-For` hop); IPv6 clients are keyed on their /64.
- Error shapes (`{"error": "..."}`): 400 `Invalid JSON` / the limits above, 403, 413, 415, 429 (with `retry-after`), 500 `Internal AI Error`, 502 contact-email failure.

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
- While streaming, nothing from `[[SEND_EMAIL]]` on is sent as a `chunk` (or voiced): `email.streamable` holds back a trailing `[`, `[[`, `[[S`… in case a tag is split across chunks, and releases it once it cannot be one. The client gets the cleaned reply in `done`. If the block cannot be parsed, `email.strip_block` removes it and the failure message is appended. Only the first block is ever sent; on a successful extraction every further block and stray tag is stripped from the user-facing text too (`email.extract`), on both endpoints.
- `smtp.send` dispatches via the `gen_smtp_client` Erlang shim.
- Without SMTP configuration (`GMAIL_*`), the `[[SEND_EMAIL]]` instructions are not put in the prompt at all (`prompt.job_requirements_rider`): the bot says it cannot pass messages on and points people to the contact details on the résumé (https://resume.arda.tr) or LinkedIn. If a block still arrives, the user gets `contact_failure_message` and an error log.

### Frontend design (Kara Duman)
- Follows the family brand "Kara Duman" (`../DESIGN-SYSTEM.md`, adopted 2026-11-23; it replaced The Index of the day before, and One Bit Forest before that). How it is applied here is in [DESIGN.md](DESIGN.md); the design is slide 15 of the brand (`../output/rebrand-kara-duman/15-ai-chat.png`). The assistant is the ember, the smoke is Arda: dark unless pinned, one 720px column under a bar as wide as the family's pages, blackletter for the `h1` only, a wisp of smoke in the far right margin.
- **Brand files are verbatim copies** from the arda.tr repository's `brand/` folder: `public/brand/arda.css` (the built Astryx `arda` theme: every token, scoped to `[data-astryx-theme="arda"]`), `public/brand/brand.css` (the family patterns, classes prefixed `ix-`), `public/brand/scheme.js` (the light/dark pin), `public/brand/art/emblem.webp`, `ember.webp` and `wisp.webp` (the artwork this site uses), `public/brand/logo/wordmark.svg` and `public/favicon.svg` (`brand/logo/favicon.svg`). Never edit them here: change them in arda.tr, copy them again, and bump their `?v=` in `frontend/gleam.toml`. `test/page.test.mjs` compares the copies with `../arda.tr/brand` when that checkout is beside this one (CI has none and skips it). There is no CI check against arda.tr's published contract (`config/themes.json`) yet.
- This site has no React, so no Astryx components: Lustre's view functions use the theme's tokens and brand.css's classes. Site-specific rules are hand-written in `public/style.css` (unlayered, so they win over the four layers) on the tokens only: a test rejects a hex colour or a px font size there. Bump `style.css?v=` in `frontend/gleam.toml` when it changes. style.css also: defines `--spacing-1…8` in `@layer astryx-base` (brand.css reads them, but they come from `@astryxdesign/core`, which only the React sites load); sets `--ix-ember-art` on `:root` to `/brand/art/ember.webp` (brand.css draws the assistant, `.ix-mark`, from it; a test checks the file is there); sets `--ix-margin` to 20px up to 720px of width (the guide's phone margin: brand.css's own clamp gives 32px at 390px); and keeps code in a reply at 18px on touch screens, where the theme's `--text-code-size` is 16px.
- The page head and static body are `[tools.lustre.html]` in `frontend/gleam.toml`: title and og/twitter title "Arda's AI Construct - Ask about Arda Karaduman", one description for all three description tags (it must not say the chat passes messages on: production has no SMTP), a `<noscript>` linking arda.tr, the résumé and the blog, and a WebSite JSON-LD block at the end of `body` whose `about`/`author` is `https://arda.tr/#person`, the Person arda.tr defines for the family. `body` is copied into `index.html` verbatim. The head also carries, in this order: `<meta name="color-scheme" content="dark">` and `<meta name="theme-color" content="#0D0C0A">` (soot); the inline `@layer reset, astryx-base, astryx-theme, brand;` before any stylesheet; the fonts (Google Fonts, `display=swap`, preconnect: Grenze Gotisch 700/800/900, Spectral 400/400i/600, JetBrains Mono 400/700, Zen Antique 400: exactly these, a test checks the list); `arda.css`, `brand.css`, `style.css`; the boot script; marked and DOMPurify; a module script that loads `scheme.js` as `window.ardaScheme`. `test/page.test.mjs` checks the `index.html` generated from it.
- **Scheme: dark unless the visitor pins light.** The pin is stored as `light`/`dark` in localStorage `theme` (the key the earlier designs used). The boot script is scheme.js's own `bootSnippet("theme", "dark")` followed by `document.documentElement.setAttribute("data-astryx-theme","arda")` (Lustre's html config cannot put attributes on `<html>`): it runs before first paint, sets `<html data-theme>` and the color-scheme meta, and rewrites an id stored by an older design to its role (`xerox`, `xerox-hc`, `paper` → light; `night`, `night-hc`, `carbon` → dark). It is pasted into `gleam.toml`; the test compares it with `public/brand/scheme.js` and runs it, so paste the new output when scheme.js changes. After load, the switch in the bar calls `toggleScheme("theme", "dark")` through `ffi.mjs` (`scheme_toggle`; `scheme_watch` follows a pin changed in another tab). The scheme is not in the Lustre model: both labels are in the markup, each naming the scheme it would switch to, and brand.css (`.ix-scheme [data-when]`) shows the one that fits `<html data-theme>`. High contrast is `prefers-contrast: more` (brand.css), no longer a rendition.
- Layout: `.shell` is pinned to the viewport (`100dvh`): the bar (brand.css `.ix-wrap`, up to 1200px), then, each in the 720px column (`.ix-wrap--read`): the conversation (`#messages-container`, the only part that scrolls), the composer (a hairline, the input and the send button, the disclaimer) and the footer (`nav.family`). So the input never leaves the screen. The scroller holds the page header (`.intro`: the large ember beside the `h1` and one secondary line), a 1px rule, the transcript, and the quick prompts (`#quick-topics`: "Try asking" as a `.ix-label` naming a group of `.ix-chip` buttons), which sit at the foot of the scroller while the conversation is short and follow the last message once it is long. A fresh conversation (first load, a language switch) is shown from its top (`scroll_to_top` in `ffi.mjs`), so the heading is on screen; every reply scrolls to its end. The wisp (`.wisp.ix-plate` in `main`, `aria-hidden`) is placed in the right margin, its right edge on the bar's, from 1200px of width and 640px of height; it does not scroll, and on bone paper its plate is soot. Up to 720px of width: 20px margins, and the bar drops the sibling links (the footer has them). Up to 480px the bar is two lines: the brand and the voice toggle, then the languages and the scheme switch (`.ix-bar__nav` becomes `display: contents`, so the order is the DOM's); up to 368px `ask` goes too. On short screens the footer goes first (`max-height: 40em`, which includes 320x568), then the paddings draw in and, under 960px of width, the sibling links go so the bar is one line (`max-height: 36em`: phone landscape). On touch screens under 1024px the theme switches to its own mobile type scale (`arda.css`, `pointer: coarse`: the `h1` is 44px, not 64px; style.css gives a narrow window without touch the same): check phone layouts with touch emulation, not just a narrow window.
- The bar: one link to https://arda.tr holding the round emblem (`img.ix-emblem`, empty `alt`) and the arda.tr wordmark (inline SVG, `wordmark.gleam`: one path in `currentColor`); `ask` (`.ix-bar__site`); then, pushed right (`.ix-bar__nav--end`): `works` / `blog` / `résumé` (the family's names for its sites, the same in every language; `works` is arda.tr), the voice toggle, the language switch (`aria-pressed` marks the one in use: ember and underlined) and the scheme switch. `nav.family` in the footer links arda.tr, blog.arda.tr, resume.arda.tr and lind.arda.tr (hostnames in every language; the label is `family_label` in `i18n.gleam`). Never link coze.org from this page.
- Replies are sanitised with an allowlist (`SANITIZE` in `ffi.mjs`): the tags markdown renders to, and only `href`, `title`, `start`, `align`. Nothing that loads a resource or positions itself survives. They are set as `.ix-prose` at the body size (links ember and underlined), with headings kept in Spectral: blackletter is for the page's `h1` only.
- The assistant is the ember (`.ix-mark`, drawn by brand.css from `--ix-ember-art`), nothing else: no orb, no cursor, no canvas. Its replies are left-aligned beside the ember, without a bubble (`.ix-msg`), the visitor's words right-aligned on the surface colour (`.ix-msg--you`); each message names its speaker for screen readers (`.ix-sr`). The ember has `data-busy="true"` while a reply is awaited or written (it glows in a slow pulse; under `prefers-reduced-motion` it is only brighter), and "Thinking…" is written beside it until the first text. A `role="status"` line (visually hidden) says ready / thinking / writing / speaking. A message containing kana is marked `lang="ja"`, so on an English or Turkish page it still gets the Japanese face (brand.css `:lang(ja)`: Zen Antique, never blackletter; the Japanese `h1` is Heading 2's size at weight 400).
- Error lines are `ChatMessage(is_error: True)` and, like empty replies, never go back to the model (`wire_history`). The transport's `HTTP 429`, `Network error` and timeout map to localised lines in `i18n.gleam`; other errors show as they came. Every error line has no ember, the family's error colour (`.ix-error`), and a localised "Error" label above its written message (`error_label`), which is also announced with it: an error is never told by colour alone.
- One request at a time: `stream_chat` aborts the request in flight before starting another, and a reset (language switch) calls `abort_stream`. Each send/reset bumps `Model.generation`; stream events carry the generation they were started with and older ones are dropped, so a reply can never land in a newer conversation. `test/app.test.mjs` drives `init`/`update`/`view` in Node to check this.
- `voice.mjs` must stay byte-identical to `design-previews/onebit/voice.js`; change the shared copy first.
- Voice: while a reply is spoken, the model's `speech` is `Speaking(msg_id, shown)` and the message renders `reveal_prefix(text, shown)` (UTF-16 prefix, with a half-typed link or `**` tidied). Once the voice has started on a reply its ember stops pulsing, and the speaker's loudness (0 to 1, what used to drive the orb) is set on it as the custom property `--ix-level` (`set_mark_level` in `ffi.mjs`, on `.msg.is-streaming .ix-mark`); brand.css makes the ember glow with it. The property is removed at silence and when the speaker stops. `done` does not end the reveal while the voice runs; `SpeechEnded` does. The voice toggle (`.voice-toggle`, a chip in the bar) reads `Voice: On/Off` (localised; its `title` says `Read replies aloud`) and carries `aria-pressed`.

### Voice replies
The assistant reads its replies aloud, in sync with the text. Protocol (types in `shared/src/shared.gleam`, `StreamEvent`):
- `{"type":"voice","on":bool}` right after `thinking`. `false` when `VOICE_ENABLED=false` or TTS is unavailable, so clients never wait for audio.
- `{"type":"speech","seq":n,"start":a,"end":b,"audio":base64|null,"mime":"audio/mpeg","marks":[{"o":offset,"t":seconds}]}`: one sentence, in `seq` order. `audio: null` = synthesis failed; the client reveals that sentence silently at its turn. Empty `marks` = reveal linearly over the clip.
- `{"type":"speech_end","upto":offset}`: no more audio; text past `upto` (over the cap, code blocks) is revealed after the audio. The `[[SEND_EMAIL]]` block is never streamed (see [Contact Email Handoff](#contact-email-handoff)).
- Offsets index the RAW reply (concatenated `chunk` texts) in UTF-16 code units (JS string indices).

Server pipeline ([stream_handler.gleam](src/ai_resume_bot/stream_handler.gleam) → [voice.gleam](src/ai_resume_bot/voice.gleam) → [speech.gleam](src/ai_resume_bot/speech.gleam) → [tts.gleam](src/ai_resume_bot/tts.gleam)):
- Chunks are cut into sentences (`. ! ?` + whitespace, `。！？`, newlines, a 220-unit clause cap); markdown is stripped (emphasis, code ticks, headings, list markers; links read as their label, bare URLs as their domain; code fences skipped) while every word keeps its raw end offset. The reply's language follows the UI `lang`, switching to Japanese on kana/kanji and to Turkish on ş/ğ/ı/İ.
- SSML puts a `<mark/>` after each word. For Japanese the marks go at punctuation and where a kana run meets kanji/katakana. Marks inside words make the voice pause (measured +17% duration), so Japanese is deliberately not marked every 2–3 characters.
- `v1beta1/text:synthesize`, `enableTimePointing: [SSML_MARK]`, MP3 24 kHz, pitch −4 st, rate 0.92. At most 3 sentences are synthesised at once, by unlinked worker processes; events go out in order. A 400 is retried without marks. A 403/429 (or no token) marks TTS unavailable for 10 minutes. `done` is held until `speech_end` has been sent, because clients stop reading at `done`.
- Auth: the Cloud Run service identity. The access token comes from the metadata server and is cached until 2 minutes before expiry; no keys or secrets. The service runs as the default compute SA `599610058688-compute@developer.gserviceaccount.com`, which has `roles/editor` (checked 2026-09-23). That is enough for Text-to-Speech. If the service ever moves to a dedicated SA, give it `roles/serviceusage.serviceUsageConsumer`. The Text-to-Speech API must be enabled on `ai-resume-chatbot-479106` (it is).
- Startup logs `Voice on: TTS reachable, voices …` or a warning (checked via the voices API).
- Voices: the lowest male Standard voice per language by measured f0 at −4 st. en-US-Standard-D (~99 Hz), tr-TR-Standard-E (~92 Hz), ja-JP-Standard-C (~120 Hz). All return mark timepoints. Change them via the `TTS_VOICE_*` env vars (a new deploy or `gcloud run services update --update-env-vars`). Free tier: 4M Standard chars/month; replies cap at `VOICE_MAX_CHARS`.

Client ([voice.mjs](frontend/src/voice.mjs), master copy `design-previews/onebit/voice.js`, reused by the arda.tr / resume.arda.tr widgets): `unlockAudio()` in the send gesture; `createSpeaker({onReveal, onLevel, onEnd})` per reply, fed every SSE event. The audio goes to the speakers as it is, through a gain and an analyser for the loudness (`voiceChain`); the "robot" effect (ring modulator, bit-crush, comb) was removed on 2026-11-23. Voice is on by default; the voice toggle under the input mutes it (localStorage `voice` = `on`/`off`). A muted request carries no voice fields.

**Only English is spoken** (since 2026-11-23). `voice_for(model)` in `frontend.gleam` decides who speaks a reply: nobody when voice is off or the language is Japanese or Turkish (the request is then text-only, and the bar shows no voice controls); the server's voice in English; the natural voice in English once it is loaded. `requestFields(lang)` in `voice.mjs` applies the same rule for the arda.tr and résumé widgets. The server still accepts `lang: ja|tr`; no client asks for it.

**The natural voice** ([natural.mjs](frontend/src/natural.mjs)) is [Phonon](https://github.com/gradium-ai/xn-ptts) by Gradium, running in the visitor's browser in a worker: the engine is vendored in `public/vendor/phonon-tts/` (npm `phonon-tts` 0.7.1; plain ES modules, loaded with a dynamic `import()` only when asked for), the model is Phonon 31m English (`DEFAULT_MODEL`, a Hugging Face repo pinned to a commit, about 67 MB, Apache-2.0) and the voice is Preston from `gradium/phonon-voices` (pinned to a commit; the lowest of the catalogue's male English voices, about 122 Hz measured). The files are kept in the browser's Cache API.
- It is an opt-in: the second chip in the bar ("Natural voice · 67 MB" → "Loading voice N%" → "Natural voice: On"). The choice is `localStorage["natural-voice"] = "on"`; a returning visitor's model is loaded at startup from the cache. Turning it off frees the model and keeps the cache.
- With it on, the request is text-only and `createNaturalSpeaker` (same `{handle, stop}` shape as voice.mjs's speaker, fed the same SSE events) cuts the streamed text into sentences (`sentenceEnds`), strips the markdown (`speakable`), synthesises them in order and plays them through voice.mjs's chain (`speechInput()`), so the ember's loudness works the same. A sentence is shown when its audio starts; the reveal is by sentence, not by word (Phonon gives no word timings). At most 1200 characters are spoken.
- Text never waits long for the voice: if a sentence's audio is not ready 2.5 s after the one before ended, the sentence is shown and the voice follows. On one CPU thread generation ran at 1.3 to 1.7 times real time on a ThinkPad (GitHub Pages cannot send the headers wasm threads need); with WebGPU (`device: "auto"`) it runs on the GPU.
- The speaker starts reporting on the first `chunk`, not on `thinking`: the app only follows a voice once the stream state is `Streaming`.

Local end-to-end: `TTS_BACKEND=mock gleam run` (real Gemini, fake audio), or against the real API with `TTS_ACCESS_TOKEN` / `TTS_QUOTA_PROJECT` as above.

### CORS
- Origins validated against `ALLOWED_ORIGINS`, delimited by `;`.
- Only the echoed `Access-Control-Allow-Origin` is set; preflight `OPTIONS` returns 200 with full CORS headers. The only allowed request header is `Content-Type`, and every CORS response carries `Vary: Origin`.
- [cloud_deploy.sh](cloud_deploy.sh) refuses to deploy if `ALLOWED_ORIGINS` is missing.

## Deployment

- **Backend**: `./cloud_deploy.sh` or `.github/workflows/deploy-backend.yml` → Cloud Run (`ai-arda-tr-api`, asia-northeast1)
  - The workflow also runs **daily** (`17 3 * * *`, 12:17 JST, though GitHub often starts it hours late) to rebuild with the current résumé, which is baked in at build time; `gh workflow run deploy-backend.yml --repo c0ze/ai.arda.tr` refreshes at once. Its `keepalive` job re-enables the workflow on each scheduled run so GitHub's 60-day inactivity rule never switches the schedule off. See [DEPLOYMENT_OPTIONS.md](DEPLOYMENT_OPTIONS.md#auto-refresh-on-résumé-changes).
- **Frontend**: Push to `main` triggers `.github/workflows/deploy-ui.yml` → GitHub Pages
- Cloud Run URL: `https://ai-arda-tr-api-599610058688.asia-northeast1.run.app`

