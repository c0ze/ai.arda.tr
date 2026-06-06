import ai_resume_bot/email
import ai_resume_bot/gemini
import ai_resume_bot/gemini_stream
import ai_resume_bot/models.{
  type ResumeData, About, Education, EducationEntry, Experience, Job, Project,
  Projects, ResumeData, Skills,
}
import ai_resume_bot/prompt
import gleam/http/request
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// prompt.build
// ---------------------------------------------------------------------------

fn fixture_resume() -> ResumeData {
  ResumeData(
    about: About(
      title: "About",
      paragraph1: "Hi, I'm Arda.",
      languages: "Languages:",
      languages_content: "English, Turkish, Japanese",
    ),
    skills: Skills(title: "Skills", technical_skills: ["Go", "Gleam", "Erlang"]),
    experience: Experience(title: "Experience", jobs: [
      Job(
        title: "Engineer",
        company: "Acme",
        period: "2020-now",
        responsibilities: ["Built things", "Shipped things"],
      ),
    ]),
    education: Education(title: "Education", entries: [
      EducationEntry(
        degree: "BSc",
        institution: "University",
        period: "2010-2014",
        description: "CS",
        additional_info: Some(
          models.AdditionalInfo(title: "Honors", items: ["Dean's list"]),
        ),
      ),
    ]),
    projects: Projects(title: "Projects", entries: [
      Project(
        title: "ai.arda.tr",
        technologies: "Gleam, Gemini",
        description: "This bot",
      ),
    ]),
  )
}

pub fn prompt_has_preamble_test() {
  let out = prompt.build(fixture_resume())
  string.contains(out, "You are Arda's AI Assistant.")
  |> should.be_true
}

pub fn prompt_has_all_sections_test() {
  let out = prompt.build(fixture_resume())
  list.each(
    [
      "## About",
      "## Skills",
      "- Go",
      "## Experience",
      "- **Engineer at Acme** [2020-now]:",
      "  Built things",
      "## Education",
      "- **BSc**, University (2010-2014). CS",
      "  **Honors**",
      "  - Dean's list",
      "## Projects",
      "- **ai.arda.tr** (Gleam, Gemini)",
      "  This bot",
      "## Visa Status",
      "Permanent Resident (Japan)",
      "## About this Bot",
    ],
    fn(needle) {
      string.contains(out, needle)
      |> should.be_true
    },
  )
}

pub fn prompt_education_without_additional_info_test() {
  let data = fixture_resume()
  let edu = case data.education.entries {
    [first, ..] -> first
    [] -> panic as "fixture has at least one entry"
  }
  let data =
    ResumeData(
      ..data,
      education: Education(..data.education, entries: [
        EducationEntry(..edu, additional_info: None),
      ]),
    )
  let out = prompt.build(data)
  string.contains(out, "**Honors**")
  |> should.be_false
}

// ---------------------------------------------------------------------------
// email.extract
// ---------------------------------------------------------------------------

pub fn extract_success_test() {
  let reply =
    "Here is my reply.\n[[SEND_EMAIL]]\n"
    <> "{\"name\":\"Taro\",\"email\":\"taro@example.com\",\"org\":\"Acme\","
    <> "\"analysis\":\"good fit\",\"job_details\":\"backend role\"}"
    <> "\n[[/SEND_EMAIL]]\nThanks!"

  let assert Ok(extracted) = email.extract(reply)
  extracted.clean_reply
  |> should.equal("Here is my reply.\n\nThanks!")
  extracted.payload.name
  |> should.equal("Taro")
  extracted.payload.email
  |> should.equal("taro@example.com")
}

pub fn extract_missing_tags_test() {
  case email.extract("just a normal reply") {
    Error(email.MissingTags) -> Nil
    _ -> panic as "expected MissingTags"
  }
}

pub fn extract_empty_payload_test() {
  case email.extract("pre [[SEND_EMAIL]]   [[/SEND_EMAIL]] post") {
    Error(email.EmptyPayload) -> Nil
    _ -> panic as "expected EmptyPayload"
  }
}

pub fn extract_invalid_json_test() {
  case email.extract("[[SEND_EMAIL]]not json[[/SEND_EMAIL]]") {
    Error(email.InvalidJson(_)) -> Nil
    _ -> panic as "expected InvalidJson"
  }
}

pub fn contains_tag_test() {
  email.contains_tag("hello [[SEND_EMAIL]] world")
  |> should.be_true
  email.contains_tag("trailing [[/SEND_EMAIL]] only")
  |> should.be_true
  email.contains_tag("nothing to see here")
  |> should.be_false
}

pub fn sanitize_removes_header_injection_test() {
  email.sanitize("Taro\r\nBcc: evil@example.com")
  |> should.equal("Taro Bcc: evil@example.com")
}

// ---------------------------------------------------------------------------
// gemini request construction — the API key must travel in a header, never in
// the URL (where it would leak into logs / error values).
// ---------------------------------------------------------------------------

pub fn gemini_request_carries_key_in_header_test() {
  let svc = gemini.new("SECRET-KEY-123", "gemini-test", "system prompt")
  let body = gemini.build_request_body("system prompt", [], "hello")
  let assert Ok(req) = gemini.build_request(svc, body)

  request.get_header(req, "x-goog-api-key")
  |> should.equal(Ok("SECRET-KEY-123"))
}

pub fn gemini_request_omits_key_from_url_test() {
  let svc = gemini.new("SECRET-KEY-123", "gemini-test", "system prompt")
  let body = gemini.build_request_body("system prompt", [], "hello")
  let assert Ok(req) = gemini.build_request(svc, body)

  // Assert both the secret value and the `key=` parameter name are absent, so
  // the test also fails if the URL regresses to `?key=` with a different value.
  let in_url =
    string.contains(req.path, "SECRET-KEY-123")
    || string.contains(req.path, "key=")
    || case req.query {
      Some(q) ->
        string.contains(q, "SECRET-KEY-123") || string.contains(q, "key=")
      None -> False
    }
  in_url
  |> should.be_false
}

pub fn gemini_stream_url_omits_key_test() {
  let url = gemini_stream.stream_url("gemini-test")
  string.contains(url, "key=")
  |> should.be_false
  string.contains(url, "alt=sse")
  |> should.be_true
}
