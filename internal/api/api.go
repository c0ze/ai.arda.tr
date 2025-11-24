package api

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/c0ze/ai-resume-bot/internal/gemini"
	"github.com/c0ze/ai-resume-bot/internal/models"
)

type Handler struct {
	GeminiService *gemini.Service
}

func NewHandler(geminiService *gemini.Service) *Handler {
	return &Handler{
		GeminiService: geminiService,
	}
}

func (h *Handler) HandleChat(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	// Validate Method
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Parse Body
	var req models.ChatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	// Invoke AI
	reply, err := h.GeminiService.GenerateContent(r.Context(), req.Message)
	if err != nil {
		log.Printf("Gemini API Error: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(models.ChatResponse{Error: "Internal AI Error"})
		return
	}

	// Return Success
	json.NewEncoder(w).Encode(models.ChatResponse{Reply: reply})
}

// CorsMiddleware wraps the handler to enable CORS for all requests
func CorsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Set CORS headers
		w.Header().Set("Access-Control-Allow-Origin", "*") // Allow all origins
		w.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS, PUT, DELETE")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")

		// Handle Preflight OPTIONS request
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusOK)
			return
		}

		// Pass to the next handler
		next.ServeHTTP(w, r)
	})
}
