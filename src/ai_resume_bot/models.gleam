//// Domain types mirroring internal/models/models.go.
////
//// Kept deliberately close to the Go structs so the JSON contract with the
//// frontend and with Gemini stays byte-for-byte compatible during migration.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// Chat wire types
// ---------------------------------------------------------------------------

pub type ChatMessage {
  ChatMessage(role: String, content: String)
}

pub type ChatRequest {
  ChatRequest(message: String, history: List(ChatMessage))
}

pub type ChatResponse {
  ChatResponse(reply: String, error: String)
}

pub fn chat_message_decoder() -> decode.Decoder(ChatMessage) {
  use role <- decode.field("role", decode.string)
  use content <- decode.field("content", decode.string)
  decode.success(ChatMessage(role:, content:))
}

pub fn chat_request_decoder() -> decode.Decoder(ChatRequest) {
  use message <- decode.field("message", decode.string)
  use history <- decode.optional_field(
    "history",
    [],
    decode.list(chat_message_decoder()),
  )
  decode.success(ChatRequest(message:, history:))
}

pub fn chat_response_to_json(resp: ChatResponse) -> json.Json {
  case resp.error {
    "" -> json.object([#("reply", json.string(resp.reply))])
    err ->
      json.object([
        #("reply", json.string(resp.reply)),
        #("error", json.string(err)),
      ])
  }
}

pub fn error_response(message: String) -> json.Json {
  json.object([#("error", json.string(message))])
}

// ---------------------------------------------------------------------------
// Resume data types
// ---------------------------------------------------------------------------

pub type About {
  About(
    title: String,
    paragraph1: String,
    languages: String,
    languages_content: String,
  )
}

pub type Job {
  Job(
    title: String,
    company: String,
    period: String,
    responsibilities: List(String),
  )
}

pub type Experience {
  Experience(title: String, jobs: List(Job))
}

pub type Project {
  Project(title: String, technologies: String, description: String)
}

pub type Projects {
  Projects(title: String, entries: List(Project))
}

pub type Skills {
  Skills(title: String, technical_skills: List(String))
}

pub type AdditionalInfo {
  AdditionalInfo(title: String, items: List(String))
}

pub type EducationEntry {
  EducationEntry(
    degree: String,
    institution: String,
    period: String,
    description: String,
    additional_info: Option(AdditionalInfo),
  )
}

pub type Education {
  Education(title: String, entries: List(EducationEntry))
}

pub type ResumeData {
  ResumeData(
    about: About,
    experience: Experience,
    projects: Projects,
    skills: Skills,
    education: Education,
  )
}

// ---------------------------------------------------------------------------
// Decoders for the JSON shapes served by c0ze/resume
// ---------------------------------------------------------------------------

pub fn about_decoder() -> decode.Decoder(About) {
  use title <- decode.field("title", decode.string)
  use paragraph1 <- decode.field("paragraph1", decode.string)
  use languages <- decode.optional_field("languages", "", decode.string)
  use languages_content <- decode.optional_field(
    "languagesContent",
    "",
    decode.string,
  )
  decode.success(About(title:, paragraph1:, languages:, languages_content:))
}

pub fn job_decoder() -> decode.Decoder(Job) {
  use title <- decode.field("title", decode.string)
  use company <- decode.field("company", decode.string)
  use period <- decode.field("period", decode.string)
  use responsibilities <- decode.optional_field(
    "responsibilities",
    [],
    decode.list(decode.string),
  )
  decode.success(Job(title:, company:, period:, responsibilities:))
}

pub fn experience_decoder() -> decode.Decoder(Experience) {
  use title <- decode.field("title", decode.string)
  use jobs <- decode.optional_field("jobs", [], decode.list(job_decoder()))
  decode.success(Experience(title:, jobs:))
}

pub fn project_decoder() -> decode.Decoder(Project) {
  use title <- decode.field("title", decode.string)
  use technologies <- decode.optional_field("technologies", "", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  decode.success(Project(title:, technologies:, description:))
}

pub fn projects_decoder() -> decode.Decoder(Projects) {
  use title <- decode.field("title", decode.string)
  use entries <- decode.optional_field(
    "entries",
    [],
    decode.list(project_decoder()),
  )
  decode.success(Projects(title:, entries:))
}

pub fn skills_decoder() -> decode.Decoder(Skills) {
  use title <- decode.field("title", decode.string)
  use technical_skills <- decode.optional_field(
    "technicalSkills",
    [],
    decode.list(decode.string),
  )
  decode.success(Skills(title:, technical_skills:))
}

pub fn additional_info_decoder() -> decode.Decoder(AdditionalInfo) {
  use title <- decode.field("title", decode.string)
  use items <- decode.optional_field("items", [], decode.list(decode.string))
  decode.success(AdditionalInfo(title:, items:))
}

pub fn education_entry_decoder() -> decode.Decoder(EducationEntry) {
  use degree <- decode.field("degree", decode.string)
  use institution <- decode.field("institution", decode.string)
  use period <- decode.field("period", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use additional_info <- decode.optional_field(
    "additionalInfo",
    None,
    decode.optional(additional_info_decoder()) |> decode.map(option_flatten),
  )
  decode.success(EducationEntry(
    degree:,
    institution:,
    period:,
    description:,
    additional_info:,
  ))
}

fn option_flatten(o: Option(AdditionalInfo)) -> Option(AdditionalInfo) {
  case o {
    Some(v) -> Some(v)
    None -> None
  }
}

pub fn education_decoder() -> decode.Decoder(Education) {
  use title <- decode.field("title", decode.string)
  use entries <- decode.optional_field(
    "entries",
    [],
    decode.list(education_entry_decoder()),
  )
  decode.success(Education(title:, entries:))
}

// ---------------------------------------------------------------------------
// Email payload (body of a [[SEND_EMAIL]] ... [[/SEND_EMAIL]] block)
// ---------------------------------------------------------------------------

pub type EmailPayload {
  EmailPayload(
    name: String,
    email: String,
    org: String,
    analysis: String,
    job_details: String,
  )
}

pub fn email_payload_decoder() -> decode.Decoder(EmailPayload) {
  use name <- decode.optional_field("name", "", decode.string)
  use email <- decode.optional_field("email", "", decode.string)
  use org <- decode.optional_field("org", "", decode.string)
  use analysis <- decode.optional_field("analysis", "", decode.string)
  use job_details <- decode.optional_field("job_details", "", decode.string)
  decode.success(EmailPayload(name:, email:, org:, analysis:, job_details:))
}
