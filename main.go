package main

import (
	"flag"
	"log"
	"net/http"
	"os"

	"github.com/c0ze/ai-resume-bot/internal/api"
	"github.com/c0ze/ai-resume-bot/internal/gemini"
	"github.com/c0ze/ai-resume-bot/internal/resume"
	"github.com/joho/godotenv"
)

func main() {
	fetchMode := flag.Bool("fetch", false, "Fetch resume data and exit")
	flag.Parse()

	// Load .env file if it exists (optional, ignored in production)
	_ = godotenv.Load()

	dataDir := "./data"

	// Handle Fetch Mode
	if *fetchMode {
		log.Println("Fetching resume data...")
		if err := resume.FetchToDisk(dataDir); err != nil {
			log.Fatalf("Failed to fetch resume data: %v", err)
		}
		log.Println("Resume data fetched successfully.")
		return
	}

	// Validate required environment variables
	apiKey := os.Getenv("GEMINI_API_KEY")
	if apiKey == "" {
		log.Fatal("GEMINI_API_KEY environment variable is required")
	}
	if os.Getenv("ALLOWED_ORIGINS") == "" {
		log.Fatal("ALLOWED_ORIGINS environment variable is required")
	}

	// Ensure data exists
	if _, err := os.Stat(dataDir); os.IsNotExist(err) {
		log.Println("Data directory not found. Fetching data...")
		if err := resume.FetchToDisk(dataDir); err != nil {
			log.Fatalf("Failed to fetch resume data: %v", err)
		}
	}

	// Load Resume Data
	resumeData, err := resume.LoadFromDisk(dataDir)
	var systemPrompt string
	if err != nil {
		log.Fatalf("Failed to load resume data: %v", err)
	}
	systemPrompt = resume.BuildPrompt(resumeData)

	// Initialize Gemini Service
	geminiService, err := gemini.NewService(apiKey, systemPrompt)
	if err != nil {
		log.Fatalf("Failed to initialize Gemini service: %v", err)
	}

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
