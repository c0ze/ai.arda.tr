package resume

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"

	"github.com/c0ze/ai-resume-bot/internal/models"
)

var (
	baseURL = "https://raw.githubusercontent.com/c0ze/resume/main/content/en/"
)

// FetchAndBuildPrompt fetches resume data and constructs the system prompt
func FetchAndBuildPrompt() (string, error) {
	var wg sync.WaitGroup
	errChan := make(chan error, 5)

	var about models.About
	var experience models.Experience
	var projects models.Projects
	var skills models.Skills
	var education models.Education

	files := map[string]interface{}{
		"about.json":      &about,
		"experience.json": &experience,
		"projects.json":   &projects,
		"skills.json":     &skills,
		"education.json":  &education,
	}

	for filename, target := range files {
		wg.Add(1)
		go func(f string, t interface{}) {
			defer wg.Done()
			url := baseURL + f
			resp, err := http.Get(url)
			if err != nil {
				errChan <- fmt.Errorf("failed to fetch %s: %v", f, err)
				return
			}
			defer resp.Body.Close()

			if resp.StatusCode != http.StatusOK {
				errChan <- fmt.Errorf("failed to fetch %s: status %d", f, resp.StatusCode)
				return
			}

			body, err := io.ReadAll(resp.Body)
			if err != nil {
				errChan <- fmt.Errorf("failed to read %s: %v", f, err)
				return
			}

			if err := json.Unmarshal(body, t); err != nil {
				errChan <- fmt.Errorf("failed to parse %s: %v", f, err)
				return
			}
		}(filename, target)
	}

	wg.Wait()
	close(errChan)

	if len(errChan) > 0 {
		return "", <-errChan
	}

	// Construct System Prompt
	var sb strings.Builder
	sb.WriteString("You are Arda's AI Assistant. You are professional, polite, and helpful. You answer questions about Arda's career, skills, and experience based on the following resume data. Your goal is to represent Arda in the best possible light to potential employers or recruiters.\n\n")

	// About
	sb.WriteString(fmt.Sprintf("## %s\n%s\n%s %s\n\n", about.Title, about.Paragraph1, about.Languages, about.LanguagesContent))

	// Skills
	sb.WriteString(fmt.Sprintf("## %s\n", skills.Title))
	for _, s := range skills.TechnicalSkills {
		sb.WriteString(fmt.Sprintf("- %s\n", s))
	}
	sb.WriteString("\n")

	// Experience
	sb.WriteString(fmt.Sprintf("## %s\n", experience.Title))
	for _, job := range experience.Jobs {
		sb.WriteString(fmt.Sprintf("- **%s at %s** [%s]:\n", job.Title, job.Company, job.Period))
		for _, resp := range job.Responsibilities {
			sb.WriteString(fmt.Sprintf("  %s\n", resp))
		}
		sb.WriteString("\n")
	}

	// Education
	sb.WriteString(fmt.Sprintf("## %s\n", education.Title))
	for _, edu := range education.Entries {
		sb.WriteString(fmt.Sprintf("- **%s**, %s (%s). %s\n", edu.Degree, edu.Institution, edu.Period, edu.Description))
		if edu.AdditionalInfo != nil {
			sb.WriteString(fmt.Sprintf("  **%s**\n", edu.AdditionalInfo.Title))
			for _, item := range edu.AdditionalInfo.Items {
				sb.WriteString(fmt.Sprintf("  - %s\n", item))
			}
		}
	}
	sb.WriteString("\n")

	// Projects
	sb.WriteString(fmt.Sprintf("## %s\n", projects.Title))
	for _, proj := range projects.Entries {
		sb.WriteString(fmt.Sprintf("- **%s** (%s)\n  %s\n", proj.Title, proj.Technologies, proj.Description))
	}

	// Visa Status (Hardcoded for now)
	sb.WriteString("\n## Visa Status\n")
	sb.WriteString("Permanent Resident (Japan)\n")

	// About this Bot
	sb.WriteString("\n## About this Bot\n")
	sb.WriteString("This bot is an AI construct designed to represent Arda. It is built with Go (Golang) for the backend and vanilla HTML/JS for the frontend. It uses Google's Gemini API for reasoning. Fun fact: This entire project was 'vibe coded' with Gemini 3 in a single weekend. You can view the source code at: https://github.com/c0ze/ai.arda.tr\n")

	return sb.String(), nil
}
