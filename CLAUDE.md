# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

AI Resume Bot - A personal AI-powered resume chatbot for ai.arda.tr. The bot answers questions about Arda's career, skills, and experience using Google's Gemini API.

## Architecture

- **Backend**: Go 1.23 web server with Gemini AI integration
- **Frontend**: Vanilla HTML/CSS/JavaScript (no frameworks)
- **AI**: Google Gemini 3.5 Flash model
- **Deployment**: Docker container on Google Cloud Run (backend), GitHub Pages (frontend)

## Project Structure

```
.
├── main.go                 # Entry point, HTTP server setup
├── internal/
│   ├── api/api.go         # HTTP handlers and CORS middleware
│   ├── gemini/gemini.go   # Gemini API client wrapper
│   ├── models/models.go   # Data structures (ChatRequest, ChatResponse, Resume types)
│   └── resume/resume.go   # Resume data fetching and prompt building
├── public/                 # Static frontend files
│   ├── index.html
│   ├── script.js          # Chat UI logic, i18n (EN/JP)
│   └── style.css
├── Dockerfile             # Multi-stage build for Cloud Run
└── .github/workflows/     # CI/CD for backend and UI deployment
```

## Common Commands

```bash
# Run locally (requires GEMINI_API_KEY in .env)
go run main.go

# Fetch resume data only (for build-time caching)
go run main.go -fetch

# Build Docker image
docker build -t ai-resume-bot .

# Run Docker container
docker run -p 8080:8080 -e GEMINI_API_KEY=your_key ai-resume-bot
```

## Environment Variables

- `GEMINI_API_KEY` - Required. Google Gemini API key
- `PORT` - Optional. Server port (default: 8080)
- `ALLOWED_ORIGINS` - Optional. Semicolon-separated list of allowed CORS origins (default: *)

## Key Implementation Details

### Resume Data Flow
1. At build time (Docker) or startup, resume JSON is fetched from GitHub (`c0ze/resume` repo)
2. Data is cached to `./data/` directory
3. Resume data is compiled into a system prompt for Gemini

### API Endpoint
- `POST /api/chat` - Accepts `{"message": "..."}`, returns `{"reply": "..."}`

### Frontend
- Supports English and Japanese UI via i18n toggle
- Quick prompt buttons for common questions (Experience, Education, Skills, Visa, About Bot)
- XSS protection via HTML escaping before rendering

### CORS
- Origins are validated against `ALLOWED_ORIGINS` env var
- Uses semicolon (`;`) as delimiter for multiple origins

## Deployment

- **Backend**: Push to main triggers `.github/workflows/deploy-backend.yml` -> Cloud Run
- **Frontend**: Push to main triggers `.github/workflows/deploy-ui.yml` -> GitHub Pages
- Cloud Run URL: `https://ai-arda-tr-api-599610058688.asia-northeast1.run.app`
