Project Plan: AI Resume Chatbot Implementation

1. Project Overview

Objective: Develop and deploy a serverless AI chatbot (ai-resume-bot) that serves as an interactive resume.
Domain: ai.arda.tr (Managed via Cloud Run mapping)
Stack:

Runtime: Go 1.23+

Cloud Provider: Google Cloud Platform (Cloud Run)

AI Model: Google Gemini 1.5 Flash

Frontend: Vanilla HTML/CSS/JS (Static files served by Go)

Architecture: Single-container monolith (Static file server + API Proxy)

2. Environment Prerequisites

Ensure the following tools are installed and authenticated:

Go: Version 1.23 or higher.

Docker: For local container builds.

Google Cloud CLI (gcloud): Authenticated with gcloud auth login.

VS Code: With "Go" and "Google Cloud Code" extensions installed.

3. Repository Initialization

Execute the following commands to scaffold the project structure:

# Create directory
mkdir ai-resume-bot
cd ai-resume-bot

# Initialize Go Module
go mod init [github.com/c0ze/ai-resume-bot](https://github.com/c0ze/ai-resume-bot)

# Create Standard Directories and Files
mkdir public
touch main.go Dockerfile public/index.html public/style.css public/script.js

# Install Gemini SDK dependencies
go get google.golang.org/genai


4. Backend Implementation (main.go)

Role: Acts as a secure proxy. It serves the static frontend and forwards chat requests to the Gemini API, injecting the system persona and API key server-side.

File: main.go

package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"

	"google.golang.org/genai"
)

// Request payload structure
type ChatRequest struct {
	Message string `json:"message"`
}

// Response payload structure
type ChatResponse struct {
	Reply string `json:"reply"`
	Error string `json:"error,omitempty"`
}

func main() {
	// Cloud Run injects the PORT environment variable
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// 1. Static File Server (Frontend)
	fs := http.FileServer(http.Dir("./public"))
	http.Handle("/", fs)

	// 2. Chat API Endpoint
	http.HandleFunc("/api/chat", handleChat)

	log.Printf("Server listening on port %s", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}

func handleChat(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	// Validate Method
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Parse Body
	var req ChatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	// Invoke AI
	reply, err := callGemini(req.Message)
	if err != nil {
		log.Printf("Gemini API Error: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(ChatResponse{Error: "Internal AI Error"})
		return
	}

	// Return Success
	json.NewEncoder(w).Encode(ChatResponse{Reply: reply})
}

func callGemini(userMessage string) (string, error) {
	ctx := context.Background()
	// API Key retrieved from Cloud Run Environment Variable
	apiKey := os.Getenv("GEMINI_API_KEY")

	client, err := genai.NewClient(ctx, &genai.ClientConfig{
		APIKey:  apiKey,
		Backend: genai.BackendGeminiAPI,
	})
	if err != nil {
		return "", err
	}

	// Model Configuration
	model := "gemini-1.5-flash"
	
	// Generate Content Request
	resp, err := client.Models.GenerateContent(ctx, model, genai.Text(userMessage), &genai.GenerateContentConfig{
		SystemInstruction: &genai.Content{
			Parts: []genai.Part{
				genai.Text("You are Arda's Resume Bot. You are cynical, sarcastic, into heavy metal, and Linux. You answer questions about Arda's career."),
			},
		},
	})
	if err != nil {
		return "", err
	}

	// Extract Text Response
	if len(resp.Candidates) > 0 && len(resp.Candidates[0].Content.Parts) > 0 {
		if txt, ok := resp.Candidates[0].Content.Parts[0].(genai.Text); ok {
			return string(txt), nil
		}
	}

	return "No response generated.", nil
}


5. Containerization (Dockerfile)

Role: Multi-stage build to create a minimal, secure production image using distroless.

File: Dockerfile

# Stage 1: Builder
FROM golang:1.23-alpine AS builder
WORKDIR /app

# Dependency Caching
COPY go.mod go.sum ./
RUN go mod download

# Build Binary
COPY . .
# CGO_ENABLED=0 ensures a static binary
RUN CGO_ENABLED=0 GOOS=linux go build -o server main.go

# Stage 2: Runtime
FROM gcr.io/distroless/static-debian12
WORKDIR /

# Copy Binary and Static Assets
COPY --from=builder /app/server /server
COPY --from=builder /app/public /public

# Cloud Run expects 8080 by default
EXPOSE 8080

ENTRYPOINT ["/server"]


6. Frontend Scaffolding (public/)

Create basic placeholder files for the UI logic.

File: public/index.html

<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Arda's AI Construct</title>
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <div id="chat-container">
        <div id="messages"></div>
        <div id="input-area">
            <input type="text" id="user-input" placeholder="Query the system..." autofocus>
            <button onclick="sendMessage()">Send</button>
        </div>
    </div>
    <script src="script.js"></script>
</body>
</html>


File: public/script.js

async function sendMessage() {
    const input = document.getElementById("user-input");
    const text = input.value;
    if (!text) return;

    // Clear input
    input.value = "";
    
    // Display User Message
    addMessage(text, "user");

    try {
        const response = await fetch("/api/chat", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ message: text })
        });
        
        const data = await response.json();
        
        if (data.error) {
            addMessage("Error: " + data.error, "bot");
        } else {
            addMessage(data.reply, "bot");
        }
    } catch (e) {
        addMessage("System Malfunction: Network Error", "bot");
    }
}

function addMessage(text, sender) {
    const div = document.createElement("div");
    div.className = "message " + sender;
    div.innerText = text;
    document.getElementById("messages").appendChild(div);
}


7. Deployment Strategy (Google Cloud Run)

Deployment via CLI (Recommended for Speed)

Run these commands in the terminal:

Set Project:

gcloud config set project [YOUR_PROJECT_ID]


Deploy Command: Replace [YOUR_GEMINI_API_KEY] with the actual key.

gcloud run deploy ai-resume-bot \
  --source . \
  --platform managed \
  --region us-central1 \
  --allow-unauthenticated \
  --set-env-vars GEMINI_API_KEY=[YOUR_GEMINI_API_KEY]


Verify: The console will output a Service URL (e.g., https://ai-resume-bot-xyz.a.run.app).

Deployment via VS Code (Cloud Code Extension)

Open the Cloud Run explorer in VS Code.

Select Deploy to Cloud Run.

In the configuration panel:

Service Name: ai-resume-bot

Authentication: Allow unauthenticated invocations

Environment Variables: Add GEMINI_API_KEY with your key value.

Build Environment: Local Docker build (uses the Dockerfile).

8. Integration

Add the following entry point to the main hub website (arda-nexus-hub):

<a href="[https://ai.arda.tr](https://ai.arda.tr)" target="_blank" rel="noopener noreferrer">
    <button>Initialize AI Construct</button>
</a>
