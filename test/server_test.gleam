//// Handler-level tests for the Wisp side of the server. None of these requests
//// may reach Gemini: each one is rejected (or answered) before the model call,
//// so the dummy API key below is never used.

import ai_resume_bot/gemini
import ai_resume_bot/rate_limit
import ai_resume_bot/server.{Config}
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import simplifile
import wisp/simulate

const allowed_origin = "https://ai.arda.tr"

fn config() -> server.Config {
  rate_limit.init()
  Config(
    gemini: gemini.new("dummy-key-never-used", "test-model", "prompt"),
    allowed_origins: [allowed_origin, "https://arda.tr"],
    smtp: None,
    public_dir: "./public",
    log_requests: False,
    rate_limit: rate_limit.Config(max_requests: 1000, window_ms: 60_000),
  )
}

fn chat(body: String) {
  simulate.request(http.Post, "/api/chat")
  |> simulate.string_body(body)
  |> simulate.header("content-type", "application/json")
  |> simulate.header("origin", allowed_origin)
}

fn error_body(message: String) -> String {
  json.to_string(json.object([#("error", json.string(message))]))
}

pub fn empty_message_is_a_400_with_a_json_error_test() {
  let resp =
    server.handle(chat("{\"message\":\"  \",\"history\":[]}"), config())
  resp.status |> should.equal(400)
  simulate.read_body(resp) |> should.equal(error_body("Message is empty"))
}

pub fn over_long_message_is_a_400_with_a_json_error_test() {
  let body =
    json.to_string(
      json.object([#("message", json.string(string.repeat("a", 20_001)))]),
    )
  let resp = server.handle(chat(body), config())
  resp.status |> should.equal(400)
  simulate.read_body(resp)
  |> should.equal(error_body("Message is too long (at most 20000 characters)"))
}

pub fn a_long_conversation_gets_past_the_body_limit_test() {
  // ~300 KB of history: read and parsed (the empty message then stops it
  // before Gemini), not refused with a 413.
  let body =
    "{\"message\":\"\",\"history\":[{\"role\":\"user\",\"content\":\""
    <> string.repeat("語", 100_000)
    <> "\"}]}"
  let resp = server.handle(chat(body), config())
  resp.status |> should.equal(400)
  simulate.read_body(resp) |> should.equal(error_body("Message is empty"))
}

pub fn the_fallback_still_reads_bodies_the_stream_refuses_test() {
  // The sibling widgets retry on /api/chat after the stream's 413, with the
  // same whole history. Over the stream's 1,000,000 bytes /api/chat must
  // still read it (and trim the history), as it always has; the empty
  // message then stops it before Gemini.
  let body =
    "{\"message\":\"\",\"history\":[{\"role\":\"user\",\"content\":\""
    <> string.repeat("語", 400_000)
    <> "\"}]}"
  let resp = server.handle(chat(body), config())
  resp.status |> should.equal(400)
  simulate.read_body(resp) |> should.equal(error_body("Message is empty"))
}

pub fn over_wisps_default_limit_is_a_413_test() {
  let body =
    "{\"message\":\"hi\",\"history\":[{\"role\":\"user\",\"content\":\""
    <> string.repeat("a", 8_000_001)
    <> "\"}]}"
  let resp = server.handle(chat(body), config())
  resp.status |> should.equal(413)
  simulate.read_body(resp) |> should.equal(error_body("Request body too large"))
}

pub fn foreign_origin_is_a_403_test() {
  let req =
    chat("{\"message\":\"hi\"}")
    |> simulate.header("origin", "https://evil.example")
  let resp = server.handle(req, config())
  resp.status |> should.equal(403)
  simulate.read_body(resp) |> should.equal(error_body("Origin not allowed"))
}

pub fn text_plain_post_is_a_415_test() {
  let req =
    chat("{\"message\":\"hi\"}")
    |> simulate.header("content-type", "text/plain")
  let resp = server.handle(req, config())
  resp.status |> should.equal(415)
  simulate.read_body(resp)
  |> should.equal(error_body("Content-Type must be application/json"))
}

pub fn no_origin_json_post_gets_past_the_header_checks_test() {
  // curl and server-side callers send no Origin; the empty message proves the
  // request got as far as the body checks (and never reached Gemini).
  let req =
    simulate.request(http.Post, "/api/chat")
    |> simulate.string_body("{\"message\":\"\"}")
    |> simulate.header("content-type", "application/json; charset=utf-8")
  let resp = server.handle(req, config())
  resp.status |> should.equal(400)
}

// CORS responses depend on the Origin, so caches must key on it; and nothing
// sends Authorization, so it is not advertised.
pub fn cors_responses_vary_on_origin_test() {
  let resp = server.handle(chat("{\"message\":\"\"}"), config())
  list.key_find(resp.headers, "vary") |> should.equal(Ok("origin"))
  list.key_find(resp.headers, "access-control-allow-origin")
  |> should.equal(Ok(allowed_origin))
  list.key_find(resp.headers, "access-control-allow-headers")
  |> should.equal(Ok("Content-Type"))
}

pub fn preflight_varies_on_origin_and_allows_only_content_type_test() {
  let req =
    simulate.request(http.Options, "/api/chat")
    |> simulate.header("origin", allowed_origin)
  let resp = server.handle(req, config())
  resp.status |> should.equal(200)
  list.key_find(resp.headers, "vary") |> should.equal(Ok("origin"))
  list.key_find(resp.headers, "access-control-allow-headers")
  |> should.equal(Ok("Content-Type"))
}

// ---------------------------------------------------------------------------
// A response sent without reading the request's body must close the
// connection: Mist would otherwise parse the unread body as the next request
// on the keep-alive socket, one whose headers (X-Forwarded-For) the sender
// wrote, past the per-IP rate limiter.
// ---------------------------------------------------------------------------

/// A request with a declared body. `simulate` sets no Content-Length itself
/// (and `string_body` sets a text/plain Content-Type, so it comes first).
fn with_body(req, body: String) {
  req
  |> simulate.string_body(body)
  |> with_length(body)
}

fn with_length(req, body: String) {
  simulate.header(req, "content-length", int.to_string(string.byte_size(body)))
}

const smuggled = "GET /health HTTP/1.1\r\nhost: x\r\n\r\n"

fn connection(resp: response.Response(a)) -> Result(String, Nil) {
  list.key_find(resp.headers, "connection")
}

pub fn rejections_before_the_body_is_read_close_the_connection_test() {
  let json_post = fn(method, path) {
    simulate.request(method, path)
    |> with_body(smuggled)
    |> simulate.header("content-type", "application/json")
    |> simulate.header("origin", allowed_origin)
  }
  let limited =
    Config(
      ..config(),
      rate_limit: rate_limit.Config(max_requests: 0, window_ms: 60_000),
    )
  let cases = [
    // 403: foreign origin
    #(
      json_post(http.Post, "/api/chat")
        |> simulate.header("origin", "https://evil.example"),
      config(),
      403,
    ),
    // 415: not JSON
    #(
      json_post(http.Post, "/api/chat")
        |> simulate.header("content-type", "text/plain"),
      config(),
      415,
    ),
    // 429: over the rate limit
    #(json_post(http.Post, "/api/chat"), limited, 429),
    // 405: wrong method on the chat and health routes
    #(json_post(http.Put, "/api/chat"), config(), 405),
    #(json_post(http.Post, "/health"), config(), 405),
    // static routes answer non-GET requests with 404, unread
    #(json_post(http.Post, "/nope"), config(), 404),
  ]
  list.each(cases, fn(c) {
    let #(req, cfg, status) = c
    let resp = server.handle(req, cfg)
    resp.status |> should.equal(status)
    connection(resp) |> should.equal(Ok("close"))
  })
}

pub fn a_body_on_a_get_or_a_preflight_closes_the_connection_test() {
  // Nothing reads these bodies either.
  let get = simulate.request(http.Get, "/health") |> with_body(smuggled)
  let resp = server.handle(get, config())
  resp.status |> should.equal(200)
  connection(resp) |> should.equal(Ok("close"))

  let preflight =
    simulate.request(http.Options, "/api/chat")
    |> simulate.header("origin", allowed_origin)
    |> with_body(smuggled)
  let resp = server.handle(preflight, config())
  resp.status |> should.equal(200)
  connection(resp) |> should.equal(Ok("close"))

  let preflight =
    request.new()
    |> request.set_method(http.Options)
    |> request.set_header("origin", allowed_origin)
    |> request.set_header("content-length", "33")
  let resp = server.cors_preflight(preflight, [allowed_origin])
  connection(resp) |> should.equal(Ok("close"))
}

pub fn a_body_over_the_limit_closes_the_connection_test() {
  let body =
    "{\"message\":\"hi\",\"history\":[{\"role\":\"user\",\"content\":\""
    <> string.repeat("a", 8_000_001)
    <> "\"}]}"
  let resp = server.handle(chat(body) |> with_length(body), config())
  resp.status |> should.equal(413)
  connection(resp) |> should.equal(Ok("close"))
}

pub fn a_body_that_was_read_keeps_the_connection_alive_test() {
  // The empty message is rejected after the whole body was read: nothing is
  // left on the socket, so the connection stays open.
  let body = "{\"message\":\"\"}"
  let resp = server.handle(chat(body) |> with_length(body), config())
  resp.status |> should.equal(400)
  connection(resp) |> should.equal(Error(Nil))
}

pub fn requests_without_a_body_keep_the_connection_alive_test() {
  let resp = server.handle(simulate.request(http.Get, "/health"), config())
  connection(resp) |> should.equal(Error(Nil))
  let resp =
    server.handle(
      simulate.request(http.Get, "/health")
        |> simulate.header("content-length", "0"),
      config(),
    )
  connection(resp) |> should.equal(Error(Nil))
  let preflight =
    simulate.request(http.Options, "/api/chat")
    |> simulate.header("origin", allowed_origin)
  connection(server.handle(preflight, config())) |> should.equal(Error(Nil))
}

// Mist reads a body only for `Transfer-Encoding: chunked` (exactly) or a
// plain decimal Content-Length; any other framing it would read as an empty
// body and leave the real one on the socket. Both headers at once is the
// classic disagreement between a proxy and a server. Such requests are
// refused before anything is read, and the connection is closed.
pub fn requests_with_framing_mist_cannot_read_are_refused_and_closed_test() {
  let body = "{\"message\":\"\"}"
  let framed = fn(headers: List(#(String, String))) {
    list.fold(headers, chat(body), fn(req, h) {
      request.prepend_header(req, h.0, h.1)
    })
  }
  [
    [#("transfer-encoding", "Chunked")],
    [#("transfer-encoding", "CHUNKED")],
    [#("transfer-encoding", "gzip, chunked")],
    [#("transfer-encoding", "gzip")],
    [#("transfer-encoding", "chunked"), #("transfer-encoding", "chunked")],
    [#("transfer-encoding", "chunked"), #("content-length", "14")],
    [#("content-length", "abc")],
    [#("content-length", "+14")],
    [#("content-length", "-1")],
    [#("content-length", "14"), #("content-length", "14")],
  ]
  |> list.each(fn(headers) {
    let resp = server.handle(framed(headers), config())
    resp.status |> should.equal(400)
    simulate.read_body(resp)
    |> should.equal(error_body("Unsupported request framing"))
    connection(resp) |> should.equal(Ok("close"))
  })
}

pub fn chunked_and_content_length_bodies_are_read_as_before_test() {
  // The empty message proves the body was read (and the request got no
  // further than the body checks).
  let body = "{\"message\":\"\"}"
  [
    request.set_header(chat(body), "transfer-encoding", "chunked"),
    with_length(chat(body), body),
  ]
  |> list.each(fn(req) {
    let resp = server.handle(req, config())
    simulate.read_body(resp) |> should.equal(error_body("Message is empty"))
    connection(resp) |> should.equal(Error(Nil))
  })
}

// ---------------------------------------------------------------------------
// Health and HEAD: cheap probes that never touch the model or the limiter.
// ---------------------------------------------------------------------------

pub fn healthz_is_ok_without_a_model_call_or_rate_limit_test() {
  // A limiter that allows nothing: /healthz must not be counted against it.
  let cfg =
    Config(
      ..config(),
      rate_limit: rate_limit.Config(max_requests: 0, window_ms: 1),
    )
  let resp = server.handle(simulate.request(http.Get, "/healthz"), cfg)
  resp.status |> should.equal(200)
  simulate.read_body(resp) |> should.equal("{\"ok\":true}")
  let resp = server.handle(simulate.request(http.Get, "/health"), cfg)
  resp.status |> should.equal(200)
}

pub fn head_on_the_root_is_like_get_without_a_body_test() {
  let dir = "build/test-public"
  let assert Ok(_) = simplifile.create_directory_all(dir)
  let assert Ok(_) =
    simplifile.write(dir <> "/index.html", "<!doctype html><title>t</title>")
  let cfg = Config(..config(), public_dir: dir)
  let get = server.handle(simulate.request(http.Get, "/"), cfg)
  let head = server.handle(simulate.request(http.Head, "/"), cfg)
  get.status |> should.equal(200)
  head.status |> should.equal(200)
  list.key_find(head.headers, "content-type")
  |> should.equal(list.key_find(get.headers, "content-type"))
  simulate.read_body(head) |> should.equal("")
}
