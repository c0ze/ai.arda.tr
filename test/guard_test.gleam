import ai_resume_bot/guard.{Rejection}
import gleam/list
import gleam/string
import gleeunit/should
import shared.{ChatMessage, ChatRequest}

// Every accepted request is a paid Gemini call, so the request must be bounded
// before it reaches the model.

pub fn empty_message_is_rejected_test() {
  guard.check_chat_request(ChatRequest(message: "", history: []))
  |> should.equal(Error(Rejection(400, "Message is empty")))
}

pub fn whitespace_only_message_is_rejected_test() {
  guard.check_chat_request(ChatRequest(message: " \n\t ", history: []))
  |> should.equal(Error(Rejection(400, "Message is empty")))
}

pub fn invisible_only_message_is_rejected_test() {
  // Characters that show nothing would otherwise reach the paid model call:
  // NBSP, ideographic space, zero-width space, NEL, NUL, BOM, soft hyphen,
  // word joiner, a bidi mark, a Hangul filler, and a mix of them.
  [
    "\u{00A0}", "\u{3000}", "\u{200B}", "\u{0085}", "\u{0000}", "\u{FEFF}",
    "\u{00AD}", "\u{2060}", "\u{200F}", "\u{3164}",
    " \u{00A0}\u{200B}\u{3000}\t\u{0000}\u{2028}",
  ]
  |> list.each(fn(message) {
    guard.check_chat_request(ChatRequest(message:, history: []))
    |> should.equal(Error(Rejection(400, "Message is empty")))
  })
}

pub fn a_message_with_visible_text_is_forwarded_as_sent_test() {
  // Only the emptiness test ignores the invisible characters; the message
  // itself goes on unchanged.
  let message = "\u{200B}\u{00A0}hi\u{3000}"
  guard.check_chat_request(ChatRequest(message:, history: []))
  |> should.equal(Ok(ChatRequest(message:, history: [])))
  // Emoji built with joiners and selectors are visible.
  let message = "👩\u{200D}💻\u{FE0F}"
  guard.check_chat_request(ChatRequest(message:, history: []))
  |> should.be_ok
  guard.check_chat_request(ChatRequest(message: "日本語", history: []))
  |> should.be_ok
}

pub fn a_pasted_job_description_fits_test() {
  // The sibling widgets have no maxlength, and a pasted job description is
  // often longer than a few thousand characters.
  shared.max_message_chars |> should.equal(20_000)
}

pub fn message_at_the_limit_is_accepted_test() {
  let msg = string.repeat("a", shared.max_message_chars)
  guard.check_chat_request(ChatRequest(message: msg, history: []))
  |> should.equal(Ok(ChatRequest(message: msg, history: [])))
}

pub fn message_over_the_limit_is_rejected_test() {
  let msg = string.repeat("a", shared.max_message_chars + 1)
  guard.check_chat_request(ChatRequest(message: msg, history: []))
  |> should.equal(
    Error(Rejection(400, "Message is too long (at most 20000 characters)")),
  )
}

pub fn the_message_limit_counts_characters_not_bytes_test() {
  // 20000 Japanese characters are 60000 bytes of UTF-8 and still fine.
  let msg = string.repeat("語", shared.max_message_chars)
  guard.check_chat_request(ChatRequest(message: msg, history: []))
  |> should.be_ok
}

pub fn over_long_history_items_are_cut_not_rejected_test() {
  // The sibling widgets resend a rejected message as history with every later
  // question; rejecting it would wedge their conversation.
  let long = string.repeat("b", shared.max_history_item_chars + 500)
  let assert Ok(req) =
    guard.check_chat_request(
      ChatRequest(message: "hi", history: [
        ChatMessage("user", long),
        ChatMessage("model", "short"),
      ]),
    )
  req.history
  |> list.map(fn(m) { string.length(m.content) })
  |> should.equal([shared.max_history_item_chars, 5])
}

pub fn history_is_capped_to_the_most_recent_messages_test() {
  let history =
    list.repeat(Nil, shared.default_max_history + 5)
    |> list.index_map(fn(_, i) { ChatMessage("user", string.inspect(i + 1)) })
  let assert Ok(req) =
    guard.check_chat_request(ChatRequest(message: "hi", history: history))
  list.length(req.history)
  |> should.equal(shared.default_max_history)
  list.first(req.history)
  |> should.equal(Ok(ChatMessage("user", "6")))
}

pub fn the_stream_body_limit_is_its_old_allowance_test() {
  // A long conversation resends its whole history from the sibling widgets
  // (18 turns of 2500 Japanese characters is ~271 KB); it must get as far as
  // the history trimming instead of a 413 it could never recover from.
  guard.max_stream_body_bytes |> should.equal(1_000_000)
}

pub fn invalid_json_is_rejected_test() {
  guard.parse_chat_request("{not json")
  |> should.equal(Error(Rejection(400, "Invalid JSON")))
}

pub fn parse_applies_the_same_checks_test() {
  guard.parse_chat_request("{\"message\":\"   \",\"history\":[]}")
  |> should.equal(Error(Rejection(400, "Message is empty")))
  guard.parse_chat_request("{\"message\":\"hello\"}")
  |> should.equal(Ok(ChatRequest(message: "hello", history: [])))
}

// ---------------------------------------------------------------------------
// Header checks: a browser page on a foreign origin must not be able to spend
// the model budget, and only JSON bodies (what all three clients send) count.
// ---------------------------------------------------------------------------

const allowed = ["https://ai.arda.tr", "https://arda.tr"]

const host = Ok("ai-arda-tr-api.example.run.app")

pub fn allowed_origin_passes_test() {
  guard.check_headers(
    Ok("https://arda.tr"),
    host,
    Ok("application/json"),
    allowed,
  )
  |> should.equal(Ok(Nil))
}

pub fn no_origin_passes_for_curl_and_server_side_callers_test() {
  guard.check_headers(Error(Nil), host, Ok("application/json"), allowed)
  |> should.equal(Ok(Nil))
}

pub fn foreign_origin_is_forbidden_test() {
  guard.check_headers(
    Ok("https://evil.example"),
    host,
    Ok("application/json"),
    allowed,
  )
  |> should.equal(Error(Rejection(403, "Origin not allowed")))
}

pub fn null_origin_is_forbidden_test() {
  guard.check_headers(Ok("null"), host, Ok("application/json"), allowed)
  |> should.equal(Error(Rejection(403, "Origin not allowed")))
}

pub fn same_origin_page_passes_even_if_not_listed_test() {
  // The bundle is also served by the backend itself (the run.app URL, or
  // localhost on any port); its requests carry that origin.
  guard.check_headers(
    Ok("https://ai-arda-tr-api.example.run.app"),
    host,
    Ok("application/json"),
    allowed,
  )
  |> should.equal(Ok(Nil))
  guard.check_headers(
    Ok("http://localhost:9123"),
    Ok("localhost:9123"),
    Ok("application/json"),
    allowed,
  )
  |> should.equal(Ok(Nil))
}

pub fn json_with_a_charset_passes_test() {
  guard.check_headers(
    Error(Nil),
    host,
    Ok("Application/JSON; charset=UTF-8"),
    allowed,
  )
  |> should.equal(Ok(Nil))
}

pub fn text_plain_is_unsupported_test() {
  guard.check_headers(Error(Nil), host, Ok("text/plain"), allowed)
  |> should.equal(
    Error(Rejection(415, "Content-Type must be application/json")),
  )
}

pub fn missing_content_type_is_unsupported_test() {
  guard.check_headers(Error(Nil), host, Error(Nil), allowed)
  |> should.equal(
    Error(Rejection(415, "Content-Type must be application/json")),
  )
}

pub fn same_origin_ignores_default_ports_and_case_test() {
  let ok = fn(origin, host) {
    guard.check_headers(Ok(origin), Ok(host), Ok("application/json"), allowed)
  }
  ok("https://api.example", "api.example:443") |> should.equal(Ok(Nil))
  ok("https://api.example:443", "api.example") |> should.equal(Ok(Nil))
  ok("http://api.example", "api.example:80") |> should.equal(Ok(Nil))
  ok("https://API.Example", "api.example") |> should.equal(Ok(Nil))
  ok("http://[::1]:8080", "[::1]:8080") |> should.equal(Ok(Nil))
  // Different ports are different origins.
  ok("https://api.example", "api.example:80")
  |> should.equal(Error(Rejection(403, "Origin not allowed")))
  ok("https://api.example:8443", "api.example")
  |> should.equal(Error(Rejection(403, "Origin not allowed")))
  ok("https://api.example.evil", "api.example")
  |> should.equal(Error(Rejection(403, "Origin not allowed")))
}

// ---------------------------------------------------------------------------
// A response sent without reading a declared body closes the connection, or
// Mist would parse that body as the next request on it.
// ---------------------------------------------------------------------------

pub fn a_content_length_or_transfer_encoding_declares_a_body_test() {
  guard.declares_body([#("content-length", "12")]) |> should.be_true
  guard.declares_body([#("Transfer-Encoding", "chunked")]) |> should.be_true
  // Anything Mist might still read as a length counts as a body.
  guard.declares_body([#("content-length", "+0")]) |> should.be_true
  guard.declares_body([#("content-length", "0"), #("content-length", "5")])
  |> should.be_true
}

pub fn no_body_or_a_zero_length_declares_none_test() {
  guard.declares_body([]) |> should.be_false
  guard.declares_body([#("host", "x"), #("content-length", "0")])
  |> should.be_false
  guard.declares_body([#("content-length", " 0 ")]) |> should.be_false
}
