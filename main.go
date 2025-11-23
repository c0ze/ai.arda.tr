package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"

	"github.com/google/generative-ai-go/genai"
	"github.com/joho/godotenv"
	"google.golang.org/api/option"
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
	// Load .env file if it exists
	_ = godotenv.Load()

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
	// Set CORS headers to allow requests from any origin (e.g. your GitHub Pages site)
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")

	// Handle Preflight OPTIONS request
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)
		return
	}

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
	apiKey := os.Getenv("GEMINI_API_KEY")

	client, err := genai.NewClient(ctx, option.WithAPIKey(apiKey))
	if err != nil {
		return "", err
	}
	defer client.Close()

	model := client.GenerativeModel("gemini-1.5-flash") // 1.5-flash is the stable one in this SDK
	model.SystemInstruction = &genai.Content{
		Parts: []genai.Part{
			genai.Text("You are Arda's Resume Bot. You are cynical, sarcastic, into heavy metal, and Linux. You answer questions about Arda's career."),
		},
	}

	resp, err := model.GenerateContent(ctx, genai.Text(userMessage))
	if err != nil {
		return "", err
	}

	if len(resp.Candidates) == 0 || len(resp.Candidates[0].Content.Parts) == 0 {
		return "No response generated.", nil
	}

	// Extract text from the first part
	if textPart, ok := resp.Candidates[0].Content.Parts[0].(genai.Text); ok {
		return string(textPart), nil
	}

	return "Received non-text response.", nil
}
