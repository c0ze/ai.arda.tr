package gemini

import (
	"context"
	"os"
	"sync"

	"github.com/c0ze/ai-resume-bot/internal/models"
	"github.com/google/generative-ai-go/genai"
	"google.golang.org/api/option"
)

type Service struct {
	apiKey       string
	systemPrompt string
	promptMutex  sync.RWMutex
}

func NewService(apiKey string, initialPrompt string) *Service {
	return &Service{
		apiKey:       apiKey,
		systemPrompt: initialPrompt,
	}
}

func (s *Service) SetSystemPrompt(prompt string) {
	s.promptMutex.Lock()
	defer s.promptMutex.Unlock()
	s.systemPrompt = prompt
}

func (s *Service) GenerateContent(ctx context.Context, userMessage string, history []models.ChatMessage) (string, error) {
	client, err := genai.NewClient(ctx, option.WithAPIKey(s.apiKey))
	if err != nil {
		return "", err
	}
	defer client.Close()

	model := client.GenerativeModel("gemini-3-flash-preview")

	s.promptMutex.RLock()
	currentPrompt := s.systemPrompt
	s.promptMutex.RUnlock()

	// Append job requirements if available
	// We ignore errors here as the file might not exist yet
	if reqData, err := os.ReadFile("data/job_requirements.md"); err == nil {
		currentPrompt += "\n\n" + string(reqData)
		currentPrompt += `

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
`
	}

	model.SystemInstruction = &genai.Content{
		Parts: []genai.Part{
			genai.Text(currentPrompt),
		},
	}

	// Start a chat session
	cs := model.StartChat()

	// Populate history
	cs.History = make([]*genai.Content, len(history))
	for i, msg := range history {
		role := "user"
		if msg.Role == "model" || msg.Role == "bot" {
			role = "model"
		}
		cs.History[i] = &genai.Content{
			Role: role,
			Parts: []genai.Part{
				genai.Text(msg.Content),
			},
		}
	}

	resp, err := cs.SendMessage(ctx, genai.Text(userMessage))
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
