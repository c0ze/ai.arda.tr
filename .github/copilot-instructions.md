# Copilot Instructions for ai.arda.tr

## Project Overview
- **Purpose:** AI Resume Chatbot (Arda's Resume Bot) deployed on Google Cloud Run. Serves a static frontend and a chat API proxying requests to Google Gemini 1.5 Flash.
- **Stack:** Go 1.23+, Google Cloud Run, Gemini API, Vanilla HTML/CSS/JS frontend (in `public/`).
- **Architecture:** Single-container monolith. Go server serves static files and `/api/chat` endpoint. No database or multi-service boundaries.

## Key Files & Structure
- `main.go`: Go HTTP server. Serves static files and `/api/chat` POST endpoint. Handles Gemini API calls with persona injection.
- `public/`: Frontend assets (`index.html`, `style.css`, `script.js`).
- `Dockerfile`: Multi-stage build. Produces a minimal distroless image for Cloud Run.
- `go.mod`: Go module definition.
- `project_plan.md`: Contains detailed setup, build, and deployment instructions.

## Build & Run
- **Local build:** `go build -o server main.go`
- **Docker build:** `docker build -t ai-resume-bot .`
- **Run locally:** `./server` (serves on `localhost:8080` by default)
- **Cloud Run deploy:**
  ```sh
  gcloud run deploy ai-resume-bot \
    --source . \
    --platform managed \
    --region us-central1 \
    --allow-unauthenticated \
    --set-env-vars GEMINI_API_KEY=YOUR_KEY
  ```
- **Environment variables:** `PORT` (default 8080), `GEMINI_API_KEY` (required for Gemini API access)

## API & Data Flow
- **Frontend** sends POST to `/api/chat` with `{ message: string }`.
- **Backend** (Go) validates, calls Gemini API, injects system persona, returns `{ reply: string, error?: string }`.
- **Persona:** "You are Arda's Resume Bot. You are cynical, sarcastic, into heavy metal, and Linux. You answer questions about Arda's career."

## Patterns & Conventions
- **No database** or persistent storage.
- **All static assets** in `public/`.
- **Go server** is the only backend entrypoint.
- **Gemini API key** is never exposed to frontend; always injected server-side.
- **Error handling:** Returns `error` field in JSON response for API errors.
- **Frontend** is minimal, no frameworks, just fetch API and DOM manipulation.

## Integration & Extensibility
- **To add new endpoints:** Use `http.HandleFunc` in `main.go`.
- **To change persona/system prompt:** Edit `callGemini` in `main.go`.
- **To update frontend:** Edit files in `public/`.

## References
- See `project_plan.md` for full setup, deployment, and architecture rationale.
- Example deployment and build commands are in `project_plan.md` and above.

---

**For AI agents:**
- Always keep Gemini API key server-side.
- Follow the persona and API contract in `main.go`.
- Use multi-stage Docker builds for production images.
- Reference `project_plan.md` for any workflow or deployment questions.
