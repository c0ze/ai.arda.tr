//// Handler-level tests for the Wisp side of the server. None of these requests
//// may reach Gemini: each one is rejected (or answered) before the model call,
//// so the dummy API key below is never used.

import ai_resume_bot/gemini
import ai_resume_bot/rate_limit
import ai_resume_bot/server.{Config}
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
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
      json.object([#("message", json.string(string.repeat("a", 4001)))]),
    )
  let resp = server.handle(chat(body), config())
  resp.status |> should.equal(400)
  simulate.read_body(resp)
  |> should.equal(error_body("Message is too long (at most 4000 characters)"))
}

pub fn over_large_body_is_a_413_test() {
  let body =
    "{\"message\":\"hi\",\"history\":[{\"role\":\"user\",\"content\":\""
    <> string.repeat("a", 300_000)
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
