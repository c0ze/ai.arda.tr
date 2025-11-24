package models

// Request payload structure
type ChatRequest struct {
	Message string `json:"message"`
}

// Response payload structure
type ChatResponse struct {
	Reply string `json:"reply"`
	Error string `json:"error,omitempty"`
}

// Resume Data Structures
type About struct {
	Title            string `json:"title"`
	Paragraph1       string `json:"paragraph1"`
	Languages        string `json:"languages"`
	LanguagesContent string `json:"languagesContent"`
}

type Job struct {
	Title            string   `json:"title"`
	Company          string   `json:"company"`
	Period           string   `json:"period"`
	Responsibilities []string `json:"responsibilities"`
}

type Experience struct {
	Title string `json:"title"`
	Jobs  []Job  `json:"jobs"`
}

type Project struct {
	Title        string `json:"title"`
	Technologies string `json:"technologies"`
	Description  string `json:"description"`
}

type Projects struct {
	Title   string    `json:"title"`
	Entries []Project `json:"entries"`
}

type Skills struct {
	Title           string   `json:"title"`
	TechnicalSkills []string `json:"technicalSkills"`
}

type AdditionalInfo struct {
	Title string   `json:"title"`
	Items []string `json:"items"`
}

type EducationEntry struct {
	Degree         string          `json:"degree"`
	Institution    string          `json:"institution"`
	Period         string          `json:"period"`
	Description    string          `json:"description"`
	AdditionalInfo *AdditionalInfo `json:"additionalInfo,omitempty"`
}

type Education struct {
	Title   string           `json:"title"`
	Entries []EducationEntry `json:"entries"`
}
