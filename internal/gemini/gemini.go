package gemini

import (
	"context"
	"strings"
	"sync"

	"github.com/c0ze/ai-resume-bot/internal/models"
	"github.com/google/generative-ai-go/genai"
	"google.golang.org/api/option"
)

// defaultModel is the Gemini model used for chat completions.
const defaultModel = "gemini-3-flash-preview"

// jobEvalInstructions is appended to the system prompt when job requirements
// are configured. It tells the model how to evaluate opportunities and how to
// emit the [[SEND_EMAIL]] block that the API layer looks for.
const jobEvalInstructions = `

If a user presents a job opportunity, evaluate it against my requirements.
1. If it's a good match, tell the user I'm interested and ask them to provide their Name, Email, and Organization so I can contact Arda.
2. If they provide this contact info, output a JSON block at the end of your response like this:
[[SEND_EMAIL]]
{
  "name": "User Name",
  "email": "user@example.com",
  "org": "Organization Name",
  "analysis": "Brief analysis of why this is a good match",
  "job_details": "Summary of the job offer"
}
[[/SEND_EMAIL]]

If the user specifically asks "Can you contact him?" or "How can I reach him?", tell them: "I can contact Arda directly on your behalf if you have a job opportunity that matches his interests. Please paste the job description here, and I will evaluate it."
`

// ComposeSystemPrompt folds optional job requirements (and the evaluation
// instructions) into the base resume prompt. When requirements is blank the
// base prompt is returned unchanged.
func ComposeSystemPrompt(base, requirements string) string {
	if strings.TrimSpace(requirements) == "" {
		return base
	}
	return base + "\n\n" + requirements + jobEvalInstructions
}

// toGenaiHistory converts the wire-format chat history into Gemini's content
// type, normalizing roles to the "user"/"model" values the API expects.
func toGenaiHistory(history []models.ChatMessage) []*genai.Content {
	out := make([]*genai.Content, len(history))
	for i, msg := range history {
		role := "user"
		if msg.Role == "model" || msg.Role == "bot" {
			role = "model"
		}
		out[i] = &genai.Content{
			Role:  role,
			Parts: []genai.Part{genai.Text(msg.Content)},
		}
	}
	return out
}

type Service struct {
	client       *genai.Client
	modelName    string
	systemPrompt string
	promptMutex  sync.RWMutex
}

// NewService creates a Gemini-backed service. The underlying genai client is
// created once here and reused for every request for the lifetime of the
// service, so callers must Close it on shutdown. initialPrompt is used as the
// model's system instruction.
func NewService(ctx context.Context, apiKey, initialPrompt string) (*Service, error) {
	client, err := genai.NewClient(ctx, option.WithAPIKey(apiKey))
	if err != nil {
		return nil, err
	}
	return &Service{
		client:       client,
		modelName:    defaultModel,
		systemPrompt: initialPrompt,
	}, nil
}

// Close releases the underlying client's resources.
func (s *Service) Close() error {
	return s.client.Close()
}

func (s *Service) SetSystemPrompt(prompt string) {
	s.promptMutex.Lock()
	defer s.promptMutex.Unlock()
	s.systemPrompt = prompt
}

func (s *Service) GenerateContent(ctx context.Context, userMessage string, history []models.ChatMessage) (string, error) {
	// GenerativeModel is a cheap, allocation-only struct over the shared
	// client, so it's safe to build a fresh (un-shared) one per request and
	// set its system instruction without racing other goroutines.
	model := s.client.GenerativeModel(s.modelName)

	s.promptMutex.RLock()
	currentPrompt := s.systemPrompt
	s.promptMutex.RUnlock()

	model.SystemInstruction = &genai.Content{
		Parts: []genai.Part{genai.Text(currentPrompt)},
	}

	cs := model.StartChat()
	cs.History = toGenaiHistory(history)

	resp, err := cs.SendMessage(ctx, genai.Text(userMessage))
	if err != nil {
		return "", err
	}

	if len(resp.Candidates) == 0 || len(resp.Candidates[0].Content.Parts) == 0 {
		return "No response generated.", nil
	}

	// Extract text from the first part.
	if textPart, ok := resp.Candidates[0].Content.Parts[0].(genai.Text); ok {
		return string(textPart), nil
	}

	return "Received non-text response.", nil
}
