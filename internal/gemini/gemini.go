package gemini

import (
	"context"
	"sync"

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

func (s *Service) GenerateContent(ctx context.Context, userMessage string) (string, error) {
	client, err := genai.NewClient(ctx, option.WithAPIKey(s.apiKey))
	if err != nil {
		return "", err
	}
	defer client.Close()

	model := client.GenerativeModel("gemini-2.5-flash")

	s.promptMutex.RLock()
	currentPrompt := s.systemPrompt
	s.promptMutex.RUnlock()

	model.SystemInstruction = &genai.Content{
		Parts: []genai.Part{
			genai.Text(currentPrompt),
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
