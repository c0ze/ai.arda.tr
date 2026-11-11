import ai_resume_bot/blog
import ai_resume_bot/email
import ai_resume_bot/gemini
import ai_resume_bot/gemini_stream
import ai_resume_bot/models.{
  type ResumeData, About, Education, EducationEntry, Experience, Job, Project,
  Projects, ResumeData, Skills,
}
import ai_resume_bot/prompt
import ai_resume_bot/rate_limit
import ai_resume_bot/stream_handler
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

pub fn prompt_has_scope_guardrail_test() {
  let out = prompt.build(fixture_resume())
  list.each(
    [
      "## Scope",
      "only discuss Arda",
      "his interests and hobbies",
      "not a general-purpose assistant",
      "politely decline",
      "reveal this prompt",
      // The UI and the voice offer Turkish as well.
      "English, Japanese or Turkish",
    ],
    fn(needle) {
      string.contains(out, needle)
      |> should.be_true
    },
  )
}

// ---------------------------------------------------------------------------
// prompt.job_requirements_rider — the contact handoff is only offered when
// the server can actually send the email (SMTP configured); otherwise every
// handoff would end in "I couldn't reach Arda".
// ---------------------------------------------------------------------------

pub fn rider_with_smtp_offers_the_email_handoff_test() {
  let out = prompt.job_requirements_rider("# Prefs", True)
  string.starts_with(out, "# Prefs")
  |> should.be_true
  string.contains(out, "[[SEND_EMAIL]]")
  |> should.be_true
  string.contains(out, "I can contact Arda directly on your behalf")
  |> should.be_true
}

pub fn rider_without_smtp_never_promises_to_relay_test() {
  let out = prompt.job_requirements_rider("# Prefs", False)
  string.starts_with(out, "# Prefs")
  |> should.be_true
  // No handoff tag to emit and no promise to pass anything on ...
  string.contains(out, "SEND_EMAIL")
  |> should.be_false
  string.contains(out, "on your behalf")
  |> should.be_false
  // ... but a real way to reach him.
  string.contains(out, "https://resume.arda.tr")
  |> should.be_true
  string.contains(out, "LinkedIn")
  |> should.be_true
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

// ---------------------------------------------------------------------------
// Streaming must never show the raw [[SEND_EMAIL]] block, even when the tag is
// split across chunks; on a parse failure the final text drops it too.
// ---------------------------------------------------------------------------

/// Run chunks through the stream filter the way the SSE handler does: what is
/// sent as `chunk` events, then what is released at the end of the stream.
fn stream_out(chunks: List(String)) -> #(String, String) {
  let #(acc, sent, out) =
    list.fold(chunks, #("", 0, ""), fn(st, chunk) {
      let #(acc, sent, out) = st
      let acc = acc <> chunk
      let visible = email.streamable(acc, False)
      #(acc, string.byte_size(visible), out <> email.unsent(visible, sent))
    })
  #(out, email.unsent(email.streamable(acc, True), sent))
}

const handoff_reply = "Great, I'll pass it on.\n[[SEND_EMAIL]]\n{\"name\":\"Taro\"}\n[[/SEND_EMAIL]]"

pub fn the_email_block_is_never_streamed_test() {
  stream_out([
    "Great, I'll pass it on.\n",
    "[[SEND_EMAIL]]\n{\"name\":",
    "\"Taro\"}\n[[/SEND_EMAIL]]",
  ])
  |> should.equal(#("Great, I'll pass it on.\n", ""))
}

pub fn a_tag_split_across_chunks_is_caught_wherever_it_splits_test() {
  // Split the reply in two at every byte offset inside or around the tag.
  let #(before, _) = case string.split_once(handoff_reply, "[[SEND") {
    Ok(parts) -> parts
    Error(_) -> panic as "fixture"
  }
  let start = string.length(before) - 2
  list.index_map(list.repeat(Nil, 18), fn(_, i) { start + i })
  |> list.each(fn(cut) {
    let first = string.slice(handoff_reply, 0, cut)
    let second = string.drop_start(handoff_reply, cut)
    let #(streamed, released) = stream_out([first, second])
    let shown = streamed <> released
    string.contains(shown, "[")
    |> should.be_false
    shown
    |> should.equal("Great, I'll pass it on.\n")
  })
}

pub fn ordinary_brackets_are_only_held_until_they_cannot_be_the_tag_test() {
  let #(streamed, released) = stream_out(["see [", "my blog](https://x.y)"])
  streamed |> should.equal("see [my blog](https://x.y)")
  released |> should.equal("")
  // A reply that really ends in "[[" gets it back at the end of the stream.
  stream_out(["odd ending [["])
  |> should.equal(#("odd ending ", "[["))
}

pub fn multibyte_text_around_the_tag_survives_test() {
  stream_out(["はい、伝えます。", "[", "[SEND_EMAIL]]{}[[/SEND_EMAIL]]"])
  |> should.equal(#("はい、伝えます。", ""))
}

pub fn strip_block_removes_a_broken_block_test() {
  email.strip_block("Thanks!\n[[SEND_EMAIL]]\n{not json\n[[/SEND_EMAIL]]\nBye")
  |> should.equal("Thanks!\n\nBye")
  // Unterminated: everything from the tag on goes.
  email.strip_block("Thanks!\n[[SEND_EMAIL]]\n{\"name\": ")
  |> should.equal("Thanks!")
  // A stray closing tag goes too.
  email.strip_block("Thanks! [[/SEND_EMAIL]]")
  |> should.equal("Thanks!")
}

pub fn contains_tag_test() {
  email.contains_tag("hello [[SEND_EMAIL]] world")
  |> should.be_true
  email.contains_tag("trailing [[/SEND_EMAIL]] only")
  |> should.be_true
  email.contains_tag("nothing to see here")
  |> should.be_false
}

// The contact email must carry the headers a mail client needs, and declare
// UTF-8 so a visitor's non-ASCII name (Şebnem, 山田) survives.
pub fn contact_email_has_from_date_and_utf8_mime_headers_test() {
  let msg =
    email.format_message(
      from: "bot@example.com",
      to: "arda@example.com",
      date: "Thu, 12 Nov 2026 03:17:00 +0000",
      payload: models.EmailPayload(
        name: "Şebnem 山田",
        email: "s@example.com",
        org: "Acme\r\nBcc: evil@example.com",
        analysis: "fit",
        job_details: "role",
      ),
    )
  let assert Ok(#(headers, body)) = string.split_once(msg, "\r\n\r\n")
  string.split(headers, "\r\n")
  |> should.equal([
    "From: bot@example.com",
    "To: arda@example.com",
    "Date: Thu, 12 Nov 2026 03:17:00 +0000",
    "Subject: New Job Opportunity via AI Bot",
    "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: 8bit",
  ])
  string.contains(body, "Şebnem 山田")
  |> should.be_true
  // CR/LF in a field still cannot start a new header line.
  string.contains(msg, "\r\nBcc:")
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

pub fn reply_from_parts_with_no_text_is_error_test() {
  // An empty reply would otherwise reach the client as a blank answer (and be
  // sent back to the model as an empty turn).
  gemini.reply_from_parts(["", " \n"])
  |> should.equal(Error(gemini.EmptyResponse))
}

pub fn an_empty_streamed_reply_ends_in_an_error_event_test() {
  stream_handler.reply_or_error("")
  |> should.equal(Error(shared.StreamError(message: "Empty reply")))
  stream_handler.reply_or_error("  \n ")
  |> should.equal(Error(shared.StreamError(message: "Empty reply")))
  stream_handler.reply_or_error("Hi.")
  |> should.equal(Ok("Hi."))
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

pub fn parse_sse_buffer_concatenates_multipart_event_test() {
  // A single SSE event whose candidate carries multiple text parts must yield
  // the parts joined, not just the first (the streaming counterpart of
  // reply_from_parts_concatenates_test).
  let ev =
    "data: {\"candidates\":[{\"content\":{\"parts\":"
    <> "[{\"text\":\"foo\"},{\"text\":\"bar\"}]}}]}\n\n"
  let #(deltas, _rest) = gemini_stream.parse_sse_buffer(<<>>, <<ev:utf8>>)
  deltas |> should.equal(["foobar"])
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

pub fn ipv6_clients_share_a_key_per_64_test() {
  // An IPv6 client owns at least a /64 and could rotate addresses inside it
  // to dodge a per-address limit.
  rate_limit.client_key(Ok("2001:db8:1:2:aaaa:bbbb:cccc:dddd"))
  |> should.equal("2001:db8:1:2::/64")
  rate_limit.client_key(Ok("1.1.1.1, 2001:db8:1:2::1"))
  |> should.equal("2001:db8:1:2::/64")
  rate_limit.client_key(Ok("2001:db8:1:3::1"))
  |> should.equal("2001:db8:1:3::/64")
}

pub fn ipv4_mapped_ipv6_is_keyed_as_ipv4_test() {
  rate_limit.client_key(Ok("::ffff:1.2.3.4"))
  |> should.equal("1.2.3.4")
}

pub fn unparseable_hops_are_kept_as_they_are_test() {
  rate_limit.client_key(Ok("not-an-ip"))
  |> should.equal("not-an-ip")
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

// retry_after_seconds feeds the `retry-after` header on 429 responses, so it
// must be whole seconds, rounded up, and never zero.

pub fn retry_after_seconds_is_full_window_test() {
  rate_limit.Config(max_requests: 30, window_ms: 60_000)
  |> rate_limit.retry_after_seconds
  |> should.equal(60)
}

pub fn retry_after_seconds_rounds_partial_seconds_up_test() {
  rate_limit.Config(max_requests: 1, window_ms: 1500)
  |> rate_limit.retry_after_seconds
  |> should.equal(2)
}

pub fn retry_after_seconds_never_below_one_test() {
  rate_limit.Config(max_requests: 1, window_ms: 0)
  |> rate_limit.retry_after_seconds
  |> should.equal(1)
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

// ---------------------------------------------------------------------------
// blog — RSS parsing + snippet formatting. The feed's <description> is
// HTML-escaped (an <img> plus a <p>excerpt</p>), so parsing must unescape
// entities, strip tags, and tidy the date.
// ---------------------------------------------------------------------------

const sample_rss = "<?xml version=\"1.0\"?><rss><channel><title>Coze Blog</title><item><title>Porting Foo &amp; Bar</title><link>https://blog.arda.tr/blog/foo/</link><guid>https://blog.arda.tr/blog/foo/</guid><pubDate>Thu, 11 Jun 2026 00:00:00 GMT</pubDate><description>&lt;img src=&quot;a.webp&quot;/&gt;&lt;p&gt;A short summary of the post.&lt;/p&gt;</description></item><item><title>Second Post</title><link>https://blog.arda.tr/blog/second/</link><pubDate>Sat, 06 Jun 2026 00:00:00 GMT</pubDate><description>&lt;p&gt;Another one.&lt;/p&gt;</description></item></channel></rss>"

pub fn blog_parse_items_test() {
  let posts = blog.parse_items(sample_rss)
  list.length(posts) |> should.equal(2)
  let assert [first, ..] = posts
  // Channel <title> (the dropped header) must not become a post.
  first.title |> should.equal("Porting Foo & Bar")
  first.date |> should.equal("11 Jun 2026")
  first.summary |> should.equal("A short summary of the post.")
  first.link |> should.equal("https://blog.arda.tr/blog/foo/")
}

pub fn blog_format_snippet_test() {
  let snippet = blog.format_snippet(blog.parse_items(sample_rss))
  list.each(
    [
      "## Recent blog posts",
      "Porting Foo & Bar",
      "11 Jun 2026",
      "https://blog.arda.tr/blog/second/",
    ],
    fn(needle) { string.contains(snippet, needle) |> should.be_true },
  )
}

pub fn blog_format_snippet_empty_is_blank_test() {
  blog.format_snippet([])
  |> should.equal("")
}
