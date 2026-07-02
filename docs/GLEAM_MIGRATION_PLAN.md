# Gleam Migration Plan

## Goal

Rewrite this project from Go plus vanilla JavaScript into a Gleam-based system while keeping the current behavior:

- Chat UI for asking about Arda's resume and background
- `POST /api/chat` backend endpoint
- Resume data fetch and prompt building
- Gemini API integration
- Optional email handoff when the model emits a contact payload
- Deployment to Google Cloud Run for the backend

This plan assumes we want a pragmatic migration, not a risky big-bang rewrite.

## Executive Summary

Yes, the project can be rewritten in Gleam.

Yes, the backend can run on Erlang/Elixir via the BEAM runtime.

The lowest-risk path is:

1. Rewrite the backend in Gleam on the Erlang target.
2. Keep the current frontend HTML/CSS/JS during the backend migration.
3. Rewrite the frontend in Gleam later only if the team still wants a full Gleam stack.

## Why This Project Is a Good Fit

The current app is small and cleanly separated:

- HTTP startup and routing live in `main.go`
- The API surface is one endpoint: `POST /api/chat`
- Resume ingestion and prompt building are already isolated
- There is no database, auth layer, queue, or background worker system
- The frontend is a self-contained browser UI

That keeps the migration scope focused on runtime and tooling rather than business complexity.

## Recommended Target Architecture

### Backend

- Language: Gleam
- Target: Erlang
- Runtime: BEAM
- HTTP layer: a small Gleam web stack such as Wisp + Mist, or equivalent
- Gemini integration: direct HTTP calls to the Gemini REST API
- Email delivery: SMTP through a Gleam package, or a small Erlang/Elixir interop wrapper if package support is weak
- Deployment: BEAM release in a Docker container on Google Cloud Run

### Frontend

Two valid choices exist:

- Transitional choice: keep `public/index.html`, `public/style.css`, and `public/script.js`
- Full Gleam choice: rebuild the UI in Gleam on the JavaScript target, likely with Lustre

### Shared Code

Share only pure code across frontend and backend:

- Request and response types
- JSON codecs
- Validation helpers
- Translation constants if desired

Do not try to force browser and server runtime code into one package without clear payoff.

## Recommended Migration Strategy

### Option A: Backend-First Migration

This is the recommended path.

Benefits:

- Lowest delivery risk
- Preserves the current working UI
- Lets us learn Gleam on the server side first
- Keeps the deploy and rollback story simple

Downside:

- The project is temporarily mixed-stack

### Option B: Full Rewrite at Once

This is possible, but not recommended unless the rewrite itself is the goal.

Benefits:

- Faster arrival at a pure Gleam stack
- Shared types from the start

Downsides:

- More moving parts at once
- Harder debugging
- Larger cutover risk
- More time spent on build tooling before user-visible value

## Phase Plan

### Phase 0: Discovery and Setup

Goal: prepare the repo for migration without changing production behavior.

Deliverables:

- Decide whether the repo becomes a Gleam monorepo or a separate `frontend/` and `backend/` layout
- Decide whether frontend migration is in-scope now or deferred
- Add a migration branch
- Document current behavior and non-negotiables

Recommended decisions:

- Use a monorepo with clear folders:
  - `gleam_backend/`
  - `gleam_frontend/`
  - `shared/` only if common code is genuinely useful
- Keep current Go app deployable until the Gleam backend is proven

Estimated effort:

- 0.5 to 1 day

### Phase 1: Model the Domain in Gleam

Goal: port the data shapes and pure logic first.

Scope:

- Chat request and response types
- Resume data types
- Prompt-building logic
- Email payload parsing logic
- Environment configuration parsing

Deliverables:

- Gleam types for current JSON payloads
- Unit tests for prompt generation
- Unit tests for `[[SEND_EMAIL]]` extraction

Notes:

- This phase is high-confidence because it is mostly pure code
- It should closely mirror the current Go logic before any design changes

Estimated effort:

- 1 to 2 days

### Phase 2: Rewrite Resume Data Fetch and Startup Loading

Goal: port the fetch/cache/load flow currently handled by `main.go` and `internal/resume/resume.go`.

Scope:

- Fetch resume JSON files from GitHub
- Cache them to disk or bake them into the image
- Load them at startup
- Build the system prompt once at boot

Recommended approach:

- Keep the current behavior first: build-time or startup-time fetch into local files
- Consider moving to build-time fetch only after parity is reached

Deliverables:

- Gleam service that loads all resume sections
- Startup validation for required environment variables
- Failure behavior that matches the current app

Estimated effort:

- 1 to 2 days

### Phase 3: Rewrite the Backend API in Gleam

Goal: replace the Go HTTP server with a Gleam server running on BEAM.

Scope:

- Serve `POST /api/chat`
- Handle JSON decode and encode
- Enforce request size limits
- Recreate CORS behavior
- Return stable error responses

Recommended implementation notes:

- Keep the route surface minimal
- Match the current request and response contract exactly
- Preserve `PORT`-based startup for Cloud Run

Deliverables:

- Gleam backend with parity for the current API
- Local development entrypoint
- Logging and structured error paths

Estimated effort:

- 2 to 3 days

### Phase 4: Replace Gemini Integration

Goal: port the Gemini call path now in `internal/gemini/gemini.go`.

Scope:

- Build the request body for Gemini
- Send user message plus chat history
- Inject the system instruction
- Parse the first text response

Recommended approach:

- Use direct HTTP calls to the Gemini REST API
- Avoid waiting for a specialized Gleam Gemini SDK unless one is already mature enough

Benefits of direct HTTP:

- Smaller dependency surface
- Easier debugging
- Fewer ecosystem risks
- Clear request and response testing

Deliverables:

- Gemini client module
- Integration test with mocked HTTP
- Configurable model name via environment variable

Estimated effort:

- 1 to 2 days

### Phase 5: Rebuild Email Delivery

Goal: replace the SMTP logic currently in `internal/api/api.go`.

Scope:

- Parse contact payload JSON
- Sanitize text fields
- Send email through Gmail SMTP or another provider

Recommended approach:

- Start with a minimal implementation that preserves current behavior
- If Gleam SMTP support is awkward, add a tiny interop boundary to Erlang or Elixir instead of over-engineering

Important note:

- This is the part most likely to need BEAM interop
- That is acceptable and does not reduce the value of the rewrite

Deliverables:

- Working email sender
- Clear failure messages and logs
- Configuration parity with `GMAIL_USER`, `GMAIL_APP_PASSWORD`, and `CONTACT_ADDRESS`

Estimated effort:

- 1 to 2 days

### Phase 6: Deploy the Gleam Backend to Cloud Run

Goal: make the new backend production-ready without touching the frontend yet.

Scope:

- Build BEAM release
- Create Dockerfile
- Expose the correct port
- Update deploy script or CI workflow

Recommended approach:

- Run the backend as a containerized BEAM release on Cloud Run
- Keep the current Go deployment path available until cutover is complete

Deliverables:

- Docker image for the Gleam backend
- Local container smoke test
- Cloud Run staging deployment
- Rollback instructions

Estimated effort:

- 1 to 2 days

### Phase 7: Frontend Decision Point

Goal: decide whether the current frontend should remain as-is or be rewritten in Gleam.

Decision criteria:

- Do we want a pure Gleam codebase, or just a Gleam backend?
- Is the current frontend painful to maintain?
- Will shared types and state modeling provide real value?

Recommendation:

- Only do the frontend rewrite after the backend is stable in production

## Frontend Rewrite Plan

If we choose the full Gleam path, the frontend should be rewritten after backend cutover.

### Proposed Frontend Stack

- Language: Gleam
- Target: JavaScript
- UI framework: Lustre
- Styling: keep the current CSS initially
- Build output: static assets for GitHub Pages or another static host

### What Should Be Ported

- Theme state
- Language toggle state
- Chat history state
- Typing indicator
- Quick prompts
- API request flow
- Markdown rendering strategy

### What Should Not Be Rewritten Immediately

- The visual design system
- CSS architecture
- Hosting model

Keeping the current CSS reduces risk and preserves the current look while the interaction layer moves to Gleam.

### Estimated Frontend Effort

- UI parity with current behavior: 2 to 4 days
- Extra time for build tooling, testing, and polish: 1 to 3 more days

## Suggested Repo Structure

### Transitional Layout

```text
.
├── legacy_go/                 # optional archive location for the old backend
├── gleam_backend/
│   ├── gleam.toml
│   ├── src/
│   ├── test/
│   └── Dockerfile
├── gleam_frontend/            # only if frontend rewrite begins
│   ├── gleam.toml
│   ├── src/
│   ├── public/
│   └── build/
├── public/                    # current static UI, kept during backend migration
├── data/
└── docs/
```

### Simpler Alternative

If we want less churn, keep the current root layout and add only:

```text
./backend_gleam
./frontend_gleam
```

This is easier if we expect a long transition period.

## Architectural Decisions

### Decision 1: Backend on BEAM

Decision:

- Use Gleam on the Erlang target for the backend

Reason:

- This is the most natural and best-supported backend runtime for Gleam
- It gives access to BEAM reliability and interop with Erlang and Elixir packages

### Decision 2: Gemini via HTTP, Not SDK Dependency

Decision:

- Call the Gemini REST API directly

Reason:

- Simpler than betting on a niche language SDK
- Easier to test and inspect

### Decision 3: Preserve API Contract First

Decision:

- Do not redesign the API during migration

Reason:

- Stable contract means the frontend can remain untouched during backend cutover

### Decision 4: Frontend Rewrite Is Optional

Decision:

- Treat the frontend rewrite as a second milestone, not a prerequisite

Reason:

- The current frontend is already small and functional
- Most of the backend value can be delivered without UI churn

## Risks and Mitigations

### Risk: Gleam Ecosystem Gaps

Examples:

- SMTP support
- Some HTTP client ergonomics
- Fewer ready-made integrations than Go

Mitigation:

- Use small, well-contained interop with Erlang or Elixir when needed
- Prefer direct protocol-level integrations over heavy wrappers

### Risk: Learning Curve

Examples:

- BEAM release packaging
- Gleam build workflows
- Different error-handling style from Go

Mitigation:

- Migrate pure modules first
- Keep the old backend deployable until parity is proven

### Risk: Too Much Change at Once

Mitigation:

- Split backend and frontend rewrites
- Release the backend migration first

### Risk: Prompt or Response Behavior Drift

Mitigation:

- Snapshot current prompt output
- Add contract tests around Gemini request construction and response parsing

## Test Strategy

### Contract Tests

- `POST /api/chat` request shape
- `POST /api/chat` response shape
- CORS behavior
- Error body behavior

### Pure Logic Tests

- Prompt building
- Resume JSON parsing
- Email tag extraction
- Email payload parsing

### Integration Tests

- Startup with expected environment variables
- Gemini API call path using a stub server
- SMTP delivery path using a fake server if available

### Manual Smoke Tests

- English and Japanese UI flows
- Quick prompt buttons
- Successful chat round trip
- Contact flow that triggers email

## Rollout Plan

### Stage 1

- Build Gleam backend locally
- Verify parity against the current frontend

### Stage 2

- Deploy Gleam backend to staging on Cloud Run
- Point a local or preview frontend at staging

### Stage 3

- Run side-by-side comparison with the Go backend
- Validate responses, logs, and email behavior

### Stage 4

- Switch production frontend to the Gleam backend URL
- Keep the Go backend available for rollback for a short window

### Stage 5

- Decide whether to retire Go completely
- Start frontend rewrite only after stable production confidence

## Estimated Total Effort

### Recommended Path: Backend First

| Scope | Experienced with Gleam | Learning Gleam While Doing It |
|---|---:|---:|
| Backend migration to production parity | 1 to 2 weeks | 2 to 4 weeks |
| Optional frontend rewrite after that | 3 to 7 days | 1 to 2 weeks |

### Big-Bang Full Rewrite

| Scope | Experienced with Gleam | Learning Gleam While Doing It |
|---|---:|---:|
| Backend plus frontend in one push | 2 to 3 weeks | 4 to 6 weeks |

## Success Criteria

The migration is successful when:

- The frontend can talk to the new backend without contract changes
- The new backend loads resume data and builds the same prompt content
- Gemini responses are functionally equivalent
- Email contact flow still works
- Cloud Run deployment and rollback are documented and reliable
- The Go backend can be retired without loss of functionality

## Recommended Next Step

Start with a backend-only proof of concept in a new `gleam_backend/` directory.

That proof of concept should implement only:

- environment loading
- resume loading
- prompt building
- `POST /api/chat`
- Gemini API call through direct HTTP

If that feels good in local development and staging, continue with email delivery and deployment. Only then decide whether the frontend should move to Gleam too.
