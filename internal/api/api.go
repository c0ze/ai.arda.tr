package api

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"

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
		allowedOrigins := os.Getenv("ALLOWED_ORIGINS")
		origin := r.Header.Get("Origin")

		// Default to * if not set (for backward compatibility/dev)
		if allowedOrigins == "" {
			w.Header().Set("Access-Control-Allow-Origin", "*")
		} else {
			// Check if the origin is allowed
			origins := strings.Split(allowedOrigins, ",")
			allowed := false
			for _, o := range origins {
				if strings.TrimSpace(o) == origin || strings.TrimSpace(o) == "*" {
					allowed = true
					break
				}
			}

			if allowed {
				w.Header().Set("Access-Control-Allow-Origin", origin)
			}
		}

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
