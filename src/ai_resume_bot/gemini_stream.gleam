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

  let url = stream_url(svc.model)

  do_stream_post(url, svc.api_key, body, subject)
  |> result.map(fn(_) { Nil })
}

/// The streaming generateContent endpoint for a model. As with the
/// non-streaming `gemini.endpoint_url`, the API key is deliberately NOT in the
/// URL — it is sent in the `x-goog-api-key` header by the FFI — so it never
/// leaks into logs or error values.
pub fn stream_url(model: String) -> String {
  "https://generativelanguage.googleapis.com/v1beta/models/"
  <> model
  <> ":streamGenerateContent?alt=sse"
}

@external(erlang, "ai_resume_bot_stream_ffi", "stream_post")
fn do_stream_post(
  url: String,
  api_key: String,
  body: String,
  subject: Subject(StreamMsg),
) -> Result(Nil, String)

/// Feed a streamed chunk through the line buffer. Returns the text deltas from
/// any *complete* `data:` lines, plus the leftover bytes (an incomplete trailing
/// line) to pass back in on the next call.
///
/// httpc delivers the response body as arbitrary byte fragments, so a single
/// `data: {...}` line — or even one multi-byte UTF-8 character (e.g. Japanese)
/// — can straddle two chunks. Buffering at the byte level and only decoding up
/// to the last newline reassembles those instead of silently dropping the delta.
pub fn parse_sse_buffer(
  pending: BitArray,
  raw: BitArray,
) -> #(List(String), BitArray) {
  let combined = bit_array.append(pending, raw)
  let #(complete, rest) = split_after_last_newline(combined)
  let deltas = case bit_array.to_string(complete) {
    Ok(text) -> extract_text_parts(text)
    // `complete` ends on a newline (ASCII, never mid-character), so a decode
    // error means genuinely invalid UTF-8 upstream rather than a split char.
    Error(_) -> []
  }
  #(deltas, rest)
}

/// Drain whatever bytes remain when the stream ends. Gemini terminates each SSE
/// event with a blank line, but flushing guards against a final event arriving
/// without its trailing newline (which would otherwise be stuck in `pending`).
pub fn flush_sse_buffer(pending: BitArray) -> List(String) {
  case bit_array.to_string(pending) {
    Ok(text) -> extract_text_parts(text)
    Error(_) -> []
  }
}

/// Split `data` into the prefix up to and including the last newline (0x0A) and
/// the bytes after it. With no newline, everything is "remaining" (incomplete).
fn split_after_last_newline(data: BitArray) -> #(BitArray, BitArray) {
  case last_newline_index(data, 0, -1) {
    -1 -> #(<<>>, data)
    i -> {
      let size = bit_array.byte_size(data)
      // Offsets are within bounds (0 <= i < size), so both slices succeed.
      let assert Ok(prefix) = bit_array.slice(data, 0, i + 1)
      let assert Ok(rest) = bit_array.slice(data, i + 1, size - i - 1)
      #(prefix, rest)
    }
  }
}

/// Byte offset of the last newline (0x0A) in `data`, or -1 if there is none.
/// 0x0A never appears inside a UTF-8 multi-byte sequence, so this is a safe
/// place to cut without splitting a character.
fn last_newline_index(data: BitArray, pos: Int, last: Int) -> Int {
  case data {
    <<byte, rest:bits>> -> {
      let last = case byte {
        10 -> pos
        _ -> last
      }
      last_newline_index(rest, pos + 1, last)
    }
    _ -> last
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
