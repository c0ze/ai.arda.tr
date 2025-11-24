package main

import (
	"log"
	"net/http"
	"os"

	"github.com/c0ze/ai-resume-bot/internal/api"
	"github.com/c0ze/ai-resume-bot/internal/gemini"
	"github.com/c0ze/ai-resume-bot/internal/resume"
	"github.com/joho/godotenv"
)

func main() {
	// Load .env file if it exists
	_ = godotenv.Load()

	// Fetch resume data at startup
	systemPrompt, err := resume.FetchAndBuildPrompt()
	if err != nil {
		log.Printf("Warning: Failed to fetch resume data: %v", err)
		systemPrompt = "You are Arda's Resume Bot. I couldn't load the resume data, so I'm a bit useless right now."
	}

	// Initialize Gemini Service
	apiKey := os.Getenv("GEMINI_API_KEY")
	geminiService := gemini.NewService(apiKey, systemPrompt)

	// Initialize API Handler
	apiHandler := api.NewHandler(geminiService)

	// Cloud Run injects the PORT environment variable
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// Create a new ServeMux to avoid global state issues
	mux := http.NewServeMux()

	// 1. Static File Server (Frontend)
	// We handle the root path LAST to ensure specific API routes take precedence
	fs := http.FileServer(http.Dir("./public"))
	mux.Handle("/", fs)

	// 2. Chat API Endpoint
	mux.HandleFunc("/api/chat", apiHandler.HandleChat)

	// 3. Wrap everything in CORS middleware
	handler := api.CorsMiddleware(mux)

	log.Printf("Server listening on port %s", port)
	if err := http.ListenAndServe(":"+port, handler); err != nil {
		log.Fatal(err)
	}
}
