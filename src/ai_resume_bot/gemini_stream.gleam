//// Streaming Gemini client.
////
//// Uses the Erlang FFI in `ai_resume_bot_stream_ffi.erl` to make a streaming
//// HTTP POST to Gemini's `streamGenerateContent` endpoint, then parses the
//// SSE data lines to extract text deltas.

import ai_resume_bot/gemini
import ai_resume_bot/models.{type ChatMessage}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// Messages received from the streaming FFI process.
pub type StreamMsg {
  Chunk(data: BitArray)
  Done
  StreamError(reason: String)
}

/// Parsed text deltas forwarded to the SSE handler.
pub type TextEvent {
  TextDelta(String)
  TextDone
  TextError(String)
}

/// Start a streaming request to Gemini. Spawns a background process that
/// sends `StreamMsg` values to `subject`. Returns immediately.
pub fn stream_generate(
  svc: gemini.Service,
  user_message: String,
  history: List(ChatMessage),
  subject: Subject(StreamMsg),
) -> Result(Nil, String) {
  let body =
    gemini.build_request_body(svc.system_prompt, history, user_message)
    |> json.to_string

  let url =
    "https://generativelanguage.googleapis.com/v1beta/models/"
    <> svc.model
    <> ":streamGenerateContent?key="
    <> svc.api_key
    <> "&alt=sse"

  do_stream_post(url, body, subject)
  |> result.map(fn(_) { Nil })
}

@external(erlang, "ai_resume_bot_stream_ffi", "stream_post")
fn do_stream_post(
  url: String,
  body: String,
  subject: Subject(StreamMsg),
) -> Result(Nil, String)

/// Parse a raw SSE chunk (which may contain multiple `data: {...}` lines)
/// into a list of text deltas. Returns empty list if no text parts found.
pub fn parse_sse_chunk(raw: BitArray) -> List(String) {
  case bit_array_to_string(raw) {
    Error(_) -> []
    Ok(text) -> extract_text_parts(text)
  }
}

fn extract_text_parts(raw: String) -> List(String) {
  raw
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    case string.starts_with(line, "data: ") {
      True -> {
        let json_str = string.drop_start(line, 6)
        parse_gemini_json(json_str)
      }
      False -> Error(Nil)
    }
  })
}

/// Parse a single Gemini response JSON and extract the text from the first
/// candidate's first part — same structure as non-streaming, but each SSE
/// event typically has just one part with the delta text.
fn parse_gemini_json(body: String) -> Result(String, Nil) {
  json.parse(body, gemini.response_decoder())
  |> result.replace_error(Nil)
  |> result.try(fn(parts) {
    case parts {
      [] -> Error(Nil)
      [first, ..] -> Ok(first)
    }
  })
}

fn bit_array_to_string(bits: BitArray) -> Result(String, Nil) {
  bit_array.to_string(bits)
}
