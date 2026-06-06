package gemini

import (
	"strings"
	"testing"

	"github.com/c0ze/ai-resume-bot/internal/models"
	"github.com/google/generative-ai-go/genai"
)

func TestComposeSystemPrompt_NoRequirements(t *testing.T) {
	base := "BASE PROMPT"
	if got := ComposeSystemPrompt(base, ""); got != base {
		t.Fatalf("expected base unchanged, got %q", got)
	}
}

func TestComposeSystemPrompt_BlankRequirements(t *testing.T) {
	base := "BASE PROMPT"
	if got := ComposeSystemPrompt(base, "  \n\t "); got != base {
		t.Fatalf("expected base unchanged for blank requirements, got %q", got)
	}
}

func TestComposeSystemPrompt_WithRequirements(t *testing.T) {
	base := "BASE PROMPT"
	req := "## Job Preferences\n- Remote preferred"
	got := ComposeSystemPrompt(base, req)

	if !strings.HasPrefix(got, base) {
		t.Errorf("expected prompt to start with base, got %q", got)
	}
	if !strings.Contains(got, req) {
		t.Errorf("expected prompt to contain the requirements text")
	}
	if !strings.Contains(got, "[[SEND_EMAIL]]") {
		t.Errorf("expected prompt to contain the job-evaluation instructions")
	}
}

func TestToGenaiHistory_RoleMapping(t *testing.T) {
	in := []models.ChatMessage{
		{Role: "user", Content: "hi"},
		{Role: "model", Content: "hello"},
		{Role: "bot", Content: "still the assistant"},
		{Role: "something-else", Content: "treated as user"},
	}
	got := toGenaiHistory(in)

	if len(got) != len(in) {
		t.Fatalf("expected %d entries, got %d", len(in), len(got))
	}

	wantRoles := []string{"user", "model", "model", "user"}
	for i, c := range got {
		if c.Role != wantRoles[i] {
			t.Errorf("entry %d: expected role %q, got %q", i, wantRoles[i], c.Role)
		}
		if len(c.Parts) != 1 {
			t.Fatalf("entry %d: expected 1 part, got %d", i, len(c.Parts))
		}
		txt, ok := c.Parts[0].(genai.Text)
		if !ok {
			t.Fatalf("entry %d: expected a genai.Text part", i)
		}
		if string(txt) != in[i].Content {
			t.Errorf("entry %d: expected content %q, got %q", i, in[i].Content, string(txt))
		}
	}
}

func TestToGenaiHistory_Empty(t *testing.T) {
	if got := toGenaiHistory(nil); len(got) != 0 {
		t.Fatalf("expected empty history, got %d entries", len(got))
	}
}
