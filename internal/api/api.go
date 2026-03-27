package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/smtp"
	"os"
	"strings"

	"github.com/c0ze/ai-resume-bot/internal/gemini"
	"github.com/c0ze/ai-resume-bot/internal/models"
)

type Handler struct {
	GeminiService *gemini.Service
}

var errEmailNotConfigured = errors.New("email delivery is not configured")

const (
	sendEmailStartTag     = "[[SEND_EMAIL]]"
	sendEmailEndTag       = "[[/SEND_EMAIL]]"
	contactFailureMessage = "I couldn't reach Arda at this moment. Please try again later or reach him through the contact details on his website, resume, or LinkedIn."
	contactSuccessSuffix  = "\n\n(Note: I have sent the email to Arda with your details.)"
)

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

	// Invoked AI
	reply, err := h.GeminiService.GenerateContent(r.Context(), req.Message, req.History)
	if err != nil {
		log.Printf("Gemini API Error: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(models.ChatResponse{Error: "Internal AI Error"})
		return
	}

	// Check for [[SEND_EMAIL]] tag
	if strings.Contains(reply, sendEmailStartTag) || strings.Contains(reply, sendEmailEndTag) {
		cleanReply, jsonStr, err := extractEmailPayload(reply)
		if err != nil {
			log.Printf("Failed to parse email payload: %v", err)
			w.WriteHeader(http.StatusBadGateway)
			json.NewEncoder(w).Encode(models.ChatResponse{Error: contactFailureMessage})
			return
		}

		if err := h.sendEmail(jsonStr); err != nil {
			log.Printf("Failed to send email: %v", err)
			w.WriteHeader(http.StatusBadGateway)
			json.NewEncoder(w).Encode(models.ChatResponse{Error: contactFailureMessage})
			return
		}

		log.Println("Email notification sent successfully")
		reply = cleanReply + contactSuccessSuffix
	}

	// Return Success
	json.NewEncoder(w).Encode(models.ChatResponse{Reply: reply})
}

func (h *Handler) sendEmail(jsonStr string) error {
	var data struct {
		Name       string `json:"name"`
		Email      string `json:"email"`
		Org        string `json:"org"`
		Analysis   string `json:"analysis"`
		JobDetails string `json:"job_details"`
	}

	if err := json.Unmarshal([]byte(jsonStr), &data); err != nil {
		return err
	}

	gmailUser := os.Getenv("GMAIL_USER")
	gmailPass := os.Getenv("GMAIL_APP_PASSWORD")
	contactAddr := os.Getenv("CONTACT_ADDRESS")

	if gmailUser == "" || gmailPass == "" {
		return errEmailNotConfigured
	}

	// Default to sending to self if contact address is not set
	toAddr := gmailUser
	if contactAddr != "" {
		toAddr = contactAddr
	}

	auth := smtp.PlainAuth("", gmailUser, gmailPass, "smtp.gmail.com")

	to := []string{toAddr}
	msg := []byte("To: " + toAddr + "\r\n" +
		"Subject: New Job Opportunity via AI Bot\r\n" +
		"\r\n" +
		"Hello,\r\n\r\n" +
		"Today I got an interesting position from " + data.Name + " from " + data.Org + ".\r\n\r\n" +
		"Here are the details:\r\n" + data.JobDetails + "\r\n\r\n" +
		"My Analysis:\r\n" + data.Analysis + "\r\n\r\n" +
		"You can reach them via " + data.Email + "\r\n\r\n" +
		"Best regards,\r\n" +
		"Arda's AI Assistant\r\n")

	return smtp.SendMail("smtp.gmail.com:587", auth, gmailUser, to, msg)
}

func extractEmailPayload(reply string) (string, string, error) {
	start := strings.Index(reply, sendEmailStartTag)
	end := strings.Index(reply, sendEmailEndTag)
	if start == -1 || end == -1 || end < start {
		return "", "", errors.New("invalid SEND_EMAIL tag block")
	}

	jsonStr := strings.TrimSpace(reply[start+len(sendEmailStartTag) : end])
	if jsonStr == "" {
		return "", "", errors.New("empty SEND_EMAIL payload")
	}

	cleanReply := strings.TrimSpace(reply[:start] + reply[end+len(sendEmailEndTag):])
	return cleanReply, jsonStr, nil
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
			origins := strings.Split(allowedOrigins, ";")
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
