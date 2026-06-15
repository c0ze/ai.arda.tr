import ai_resume_bot/email
import ai_resume_bot/gemini
import ai_resume_bot/gemini_stream
import ai_resume_bot/models.{
  type ResumeData, About, Education, EducationEntry, Experience, Job, Project,
  Projects, ResumeData, Skills,
}
import ai_resume_bot/prompt
import ai_resume_bot/rate_limit
import gleam/bit_array
import gleam/http/request
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import shared

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

// ---------------------------------------------------------------------------
// gemini.reply_from_parts — a candidate's text parts must be concatenated, not
// truncated to the first part.
// ---------------------------------------------------------------------------

pub fn reply_from_parts_concatenates_test() {
  gemini.reply_from_parts(["Hello, ", "world", "!"])
  |> should.equal(Ok("Hello, world!"))
}

pub fn reply_from_parts_empty_is_error_test() {
  case gemini.reply_from_parts([]) {
    Error(gemini.EmptyResponse) -> Nil
    _ -> panic as "expected EmptyResponse"
  }
}

// ---------------------------------------------------------------------------
// gemini_stream SSE buffering — a `data:` line (or a multi-byte character)
// split across chunk boundaries must be reassembled, not dropped.
// ---------------------------------------------------------------------------

/// Build a Gemini SSE `data:` event carrying a single text delta. `text` must
/// not contain characters that need JSON escaping.
fn sse_event(text: String) -> String {
  "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\""
  <> text
  <> "\"}]}}]}\n\n"
}

pub fn parse_sse_buffer_reassembles_split_line_test() {
  let prefix = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hel"
  let suffix = "lo world\"}]}}]}\n\n"
  // First fragment has no newline yet, so nothing is emitted and it is buffered.
  let #(d1, pending) = gemini_stream.parse_sse_buffer(<<>>, <<prefix:utf8>>)
  d1 |> should.equal([])
  // The completing fragment yields the full delta.
  let #(d2, rest) = gemini_stream.parse_sse_buffer(pending, <<suffix:utf8>>)
  d2 |> should.equal(["hello world"])
  rest |> should.equal(<<>>)
}

pub fn parse_sse_buffer_reassembles_split_multibyte_char_test() {
  // "あ" is UTF-8 E3 81 82; split it across the two fragments. Decoding the
  // first fragment alone would fail, so a byte-level buffer is required.
  let prefix = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\""
  let suffix = "\"}]}}]}\n\n"
  let frag1 = bit_array.append(<<prefix:utf8>>, <<227>>)
  let frag2 = bit_array.append(<<129, 130>>, <<suffix:utf8>>)
  let #(d1, pending) = gemini_stream.parse_sse_buffer(<<>>, frag1)
  d1 |> should.equal([])
  let #(d2, _rest) = gemini_stream.parse_sse_buffer(pending, frag2)
  d2 |> should.equal(["あ"])
}

pub fn parse_sse_buffer_handles_multiple_events_in_one_chunk_test() {
  let chunk = sse_event("a") <> sse_event("b")
  let #(deltas, rest) = gemini_stream.parse_sse_buffer(<<>>, <<chunk:utf8>>)
  deltas |> should.equal(["a", "b"])
  rest |> should.equal(<<>>)
}

pub fn flush_sse_buffer_drains_trailing_event_without_newline_test() {
  // A final event that never gets its terminating newline stays buffered ...
  let partial =
    "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"bye\"}]}}]}"
  let #(deltas, pending) =
    gemini_stream.parse_sse_buffer(<<>>, <<partial:utf8>>)
  deltas |> should.equal([])
  // ... until flushed at stream end.
  gemini_stream.flush_sse_buffer(pending)
  |> should.equal(["bye"])
}

// ---------------------------------------------------------------------------
// rate_limit
// ---------------------------------------------------------------------------

pub fn client_key_takes_last_forwarded_ip_test() {
  // Cloud Run appends the real client IP as the right-most hop; the left hops
  // are client-spoofable and must be ignored.
  rate_limit.client_key(Ok("9.9.9.9, 5.6.7.8, 1.2.3.4"))
  |> should.equal("1.2.3.4")
}

pub fn client_key_trims_whitespace_test() {
  rate_limit.client_key(Ok("  1.2.3.4  "))
  |> should.equal("1.2.3.4")
}

pub fn client_key_falls_back_when_absent_test() {
  rate_limit.client_key(Error(Nil))
  |> should.equal("unknown")
}

pub fn client_key_falls_back_when_blank_test() {
  rate_limit.client_key(Ok("   "))
  |> should.equal("unknown")
}

pub fn rate_limit_allows_up_to_limit_then_denies_test() {
  rate_limit.init()
  let cfg = rate_limit.Config(max_requests: 3, window_ms: 1000)
  rate_limit.allow_at(cfg, "rl-a", 0) |> should.be_true
  rate_limit.allow_at(cfg, "rl-a", 100) |> should.be_true
  rate_limit.allow_at(cfg, "rl-a", 200) |> should.be_true
  rate_limit.allow_at(cfg, "rl-a", 300) |> should.be_false
}

pub fn rate_limit_resets_in_next_window_test() {
  rate_limit.init()
  let cfg = rate_limit.Config(max_requests: 1, window_ms: 1000)
  rate_limit.allow_at(cfg, "rl-b", 500) |> should.be_true
  rate_limit.allow_at(cfg, "rl-b", 700) |> should.be_false
  // 1500 ms falls in the next 1000ms window, so the counter resets.
  rate_limit.allow_at(cfg, "rl-b", 1500) |> should.be_true
}

pub fn rate_limit_isolates_keys_test() {
  rate_limit.init()
  let cfg = rate_limit.Config(max_requests: 1, window_ms: 1000)
  rate_limit.allow_at(cfg, "rl-c1", 0) |> should.be_true
  rate_limit.allow_at(cfg, "rl-c1", 1) |> should.be_false
  // A different key has its own independent bucket.
  rate_limit.allow_at(cfg, "rl-c2", 1) |> should.be_true
}

pub fn config_from_env_defaults_test() {
  let cfg = rate_limit.config_from_env(Error(Nil), Error(Nil))
  cfg.max_requests |> should.equal(30)
  cfg.window_ms |> should.equal(60_000)
}

pub fn config_from_env_parses_values_test() {
  let cfg = rate_limit.config_from_env(Ok("10"), Ok("5"))
  cfg.max_requests |> should.equal(10)
  cfg.window_ms |> should.equal(5000)
}

pub fn config_from_env_ignores_invalid_test() {
  let cfg = rate_limit.config_from_env(Ok("abc"), Ok("-5"))
  cfg.max_requests |> should.equal(30)
  cfg.window_ms |> should.equal(60_000)
}

// ---------------------------------------------------------------------------
// email.reply_with_outcome — the streaming and non-streaming paths must report
// the contact-email result to the user consistently.
// ---------------------------------------------------------------------------

pub fn reply_with_outcome_sent_test() {
  email.reply_with_outcome("Thanks!", True)
  |> should.equal("Thanks!" <> email.contact_success_suffix)
}

pub fn reply_with_outcome_failed_surfaces_failure_test() {
  let out = email.reply_with_outcome("Thanks!", False)
  // A failed/unconfigured send must surface the failure message ...
  string.contains(out, email.contact_failure_message)
  |> should.be_true
  // ... and must never claim success.
  string.contains(out, email.contact_success_suffix)
  |> should.be_false
}

// ---------------------------------------------------------------------------
// shared.cap_history — bound the conversation history sent to the backend
// ---------------------------------------------------------------------------

pub fn cap_history_keeps_most_recent_test() {
  let h = [
    shared.ChatMessage("user", "1"),
    shared.ChatMessage("model", "2"),
    shared.ChatMessage("user", "3"),
    shared.ChatMessage("model", "4"),
  ]
  shared.cap_history(h, 2)
  |> should.equal([
    shared.ChatMessage("user", "3"),
    shared.ChatMessage("model", "4"),
  ])
}

pub fn cap_history_shorter_than_max_is_unchanged_test() {
  let h = [shared.ChatMessage("user", "1"), shared.ChatMessage("model", "2")]
  shared.cap_history(h, 10)
  |> should.equal(h)
}

pub fn cap_history_nonpositive_keeps_all_test() {
  let h = [shared.ChatMessage("user", "1"), shared.ChatMessage("model", "2")]
  shared.cap_history(h, 0)
  |> should.equal(h)
}
