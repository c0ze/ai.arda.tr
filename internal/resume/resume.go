package resume

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/c0ze/ai-resume-bot/internal/models"
)

var (
	baseURL = "https://raw.githubusercontent.com/c0ze/resume/main/content/en/"
)

type ResumeData struct {
	About      models.About
	Experience models.Experience
	Projects   models.Projects
	Skills     models.Skills
	Education  models.Education
}

// FetchToDisk fetches resume data from GitHub and saves it to the specified directory
func FetchToDisk(outputDir string) error {
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return fmt.Errorf("failed to create directory %s: %v", outputDir, err)
	}

	var wg sync.WaitGroup
	errChan := make(chan error, 5)

	files := []string{
		"about.json",
		"experience.json",
		"projects.json",
		"skills.json",
		"education.json",
	}

	for _, filename := range files {
		wg.Add(1)
		go func(f string) {
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

			outputPath := filepath.Join(outputDir, f)
			if err := os.WriteFile(outputPath, body, 0644); err != nil {
				errChan <- fmt.Errorf("failed to write %s: %v", f, err)
				return
			}
		}(filename)
	}

	wg.Wait()
	close(errChan)

	if len(errChan) > 0 {
		return <-errChan
	}
	return nil
}

// LoadFromDisk reads resume data from the specified directory
func LoadFromDisk(inputDir string) (*ResumeData, error) {
	data := &ResumeData{}
	files := map[string]interface{}{
		"about.json":      &data.About,
		"experience.json": &data.Experience,
		"projects.json":   &data.Projects,
		"skills.json":     &data.Skills,
		"education.json":  &data.Education,
	}

	for filename, target := range files {
		path := filepath.Join(inputDir, filename)
		body, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("failed to read %s: %v", path, err)
		}

		if err := json.Unmarshal(body, target); err != nil {
			return nil, fmt.Errorf("failed to parse %s: %v", path, err)
		}
	}

	return data, nil
}

// BuildPrompt constructs the system prompt from the loaded resume data
func BuildPrompt(data *ResumeData) string {
	var sb strings.Builder
	sb.WriteString("You are Arda's AI Assistant. You are professional, polite, and helpful. You answer questions about Arda's career, skills, and experience based on the following resume data. Your goal is to represent Arda in the best possible light to potential employers or recruiters.\n\n")

	// About
	sb.WriteString(fmt.Sprintf("## %s\n%s\n%s %s\n\n", data.About.Title, data.About.Paragraph1, data.About.Languages, data.About.LanguagesContent))

	// Skills
	sb.WriteString(fmt.Sprintf("## %s\n", data.Skills.Title))
	for _, s := range data.Skills.TechnicalSkills {
		sb.WriteString(fmt.Sprintf("- %s\n", s))
	}
	sb.WriteString("\n")

	// Experience
	sb.WriteString(fmt.Sprintf("## %s\n", data.Experience.Title))
	for _, job := range data.Experience.Jobs {
		sb.WriteString(fmt.Sprintf("- **%s at %s** [%s]:\n", job.Title, job.Company, job.Period))
		for _, resp := range job.Responsibilities {
			sb.WriteString(fmt.Sprintf("  %s\n", resp))
		}
		sb.WriteString("\n")
	}

	// Education
	sb.WriteString(fmt.Sprintf("## %s\n", data.Education.Title))
	for _, edu := range data.Education.Entries {
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
	sb.WriteString(fmt.Sprintf("## %s\n", data.Projects.Title))
	for _, proj := range data.Projects.Entries {
		sb.WriteString(fmt.Sprintf("- **%s** (%s)\n  %s\n", proj.Title, proj.Technologies, proj.Description))
	}

	// Visa Status (Hardcoded for now)
	sb.WriteString("\n## Visa Status\n")
	sb.WriteString("Permanent Resident (Japan)\n")

	// About this Bot
	sb.WriteString("\n## About this Bot\n")
	sb.WriteString("This bot is an AI construct designed to represent Arda. It is built with Go (Golang) for the backend and vanilla HTML/JS for the frontend. It uses Google's Gemini API for reasoning. Fun fact: This entire project was 'vibe coded' with Gemini 3 in a single weekend. You can view the source code at: https://github.com/c0ze/ai.arda.tr\n")

	return sb.String()
}
