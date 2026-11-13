//// The stream path reads its body itself: mist.read_body only checks
//// Content-Length, so a chunked request could otherwise send any amount.

import ai_resume_bot/gemini
import ai_resume_bot/rate_limit
import ai_resume_bot/stream_handler
import ai_resume_bot/tts
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None}
import gleeunit/should
import mist

/// A fake `mist.stream` consumer over a fixed list of chunks. `calls` counts
/// how many chunks were pulled, so a test can see that reading stops early.
fn chunks(
  parts: List(BitArray),
) -> fn(Int) -> Result(mist.Chunk, mist.ReadError) {
  fn(_size) {
    case parts {
      [] -> Ok(mist.Done)
      [part, ..rest] -> Ok(mist.Chunk(part, chunks(rest)))
    }
  }
}

pub fn a_chunked_body_under_the_limit_is_read_whole_test() {
  stream_handler.collect_body(chunks([<<"ab":utf8>>, <<"cd":utf8>>]), 4)
  |> should.equal(Ok(<<"abcd":utf8>>))
}

pub fn a_chunked_body_over_the_limit_is_excess_test() {
  stream_handler.collect_body(
    chunks([<<"ab":utf8>>, <<"cd":utf8>>, <<"e":utf8>>]),
    4,
  )
  |> should.equal(Error(mist.ExcessBody))
}

pub fn reading_stops_as_soon_as_the_limit_is_passed_test() {
  // The chunk after the one that crosses the limit is never pulled.
  let boom = fn(_size) -> Result(mist.Chunk, mist.ReadError) {
    panic as "read past the limit"
  }
  let consume = fn(_size) { Ok(mist.Chunk(<<"too long":utf8>>, boom)) }
  stream_handler.collect_body(consume, 4)
  |> should.equal(Error(mist.ExcessBody))
}

pub fn a_malformed_body_stays_malformed_test() {
  let consume = fn(_size) -> Result(mist.Chunk, mist.ReadError) {
    Error(mist.MalformedBody)
  }
  stream_handler.collect_body(consume, 4)
  |> should.equal(Error(mist.MalformedBody))
}

// ---------------------------------------------------------------------------
// Rejections made before the body is read close the connection: Mist would
// otherwise parse the unread body as the next request on the keep-alive
// socket, one whose X-Forwarded-For the sender wrote, past the rate limiter.
// ---------------------------------------------------------------------------

fn stream_config(max_requests: Int) -> stream_handler.StreamConfig {
  rate_limit.init()
  stream_handler.StreamConfig(
    gemini: gemini.new("dummy-key-never-used", "test-model", "prompt"),
    smtp: None,
    allowed_origins: ["https://ai.arda.tr"],
    rate_limit: rate_limit.Config(max_requests:, window_ms: 60_000),
    tts: tts.config_from_env(fn(_) { Error(Nil) }),
  )
}

fn post(content_type: String, origin: String) -> request.Request(String) {
  request.new()
  |> request.set_method(http.Post)
  |> request.set_path("/api/chat/stream")
  |> request.set_header("content-type", content_type)
  |> request.set_header("origin", origin)
  |> request.set_header("content-length", "33")
}

fn never_read_the_body() -> response.Response(mist.ResponseData) {
  panic as "the body must not be read after a rejection"
}

pub fn stream_rejections_before_the_body_close_the_connection_test() {
  let cases = [
    #(
      post("application/json", "https://evil.example"),
      stream_config(1000),
      403,
    ),
    #(post("text/plain", "https://ai.arda.tr"), stream_config(1000), 415),
    #(post("application/json", "https://ai.arda.tr"), stream_config(0), 429),
  ]
  list.each(cases, fn(c) {
    let #(req, cfg, status) = c
    let resp = stream_handler.check_before_body(req, cfg, never_read_the_body)
    resp.status |> should.equal(status)
    list.key_find(resp.headers, "connection") |> should.equal(Ok("close"))
    // Still readable by the cross-origin widgets.
    case status {
      403 -> Nil
      _ ->
        list.key_find(resp.headers, "access-control-allow-origin")
        |> should.equal(Ok("https://ai.arda.tr"))
    }
  })
}

pub fn a_request_that_passes_goes_on_to_read_its_body_test() {
  let req = post("application/json", "https://ai.arda.tr")
  let resp =
    stream_handler.check_before_body(req, stream_config(1000), fn() {
      response.new(204) |> response.set_body(mist.Bytes(bytes_tree.new()))
    })
  resp.status |> should.equal(204)
}
