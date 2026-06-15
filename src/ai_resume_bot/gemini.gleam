//// Gemini REST client, ported from internal/gemini/gemini.go.
////
//// Calls generativelanguage.googleapis.com directly (no SDK), so the
//// dependency surface stays small and the request/response shape stays
//// easy to snapshot-test.

import ai_resume_bot/models.{type ChatMessage}
import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type GeminiError {
  RequestBuildError(String)
  TransportError(String)
  HttpStatusError(status: Int, body: String)
  DecodeError(String)
  EmptyResponse
}

pub type Service {
  Service(api_key: String, model: String, system_prompt: String)
}

pub fn new(api_key: String, model: String, system_prompt: String) -> Service {
  Service(api_key:, model:, system_prompt:)
}

/// The (non-streaming) generateContent endpoint for a model. The API key is
/// deliberately NOT part of the URL — it is sent in a header (see
/// `build_request`) so it never lands in logs or error values.
pub fn endpoint_url(model: String) -> String {
  "https://generativelanguage.googleapis.com/v1beta/models/"
  <> model
  <> ":generateContent"
}

/// Build the HTTP request for a generateContent call. The key travels in the
/// `x-goog-api-key` header rather than the `?key=` query string.
pub fn build_request(
  svc: Service,
  body: json.Json,
) -> Result(request.Request(String), GeminiError) {
  let url = endpoint_url(svc.model)
  request.to(url)
  |> result.map_error(fn(_) { RequestBuildError(url) })
  |> result.map(fn(req) {
    req
    |> request.set_method(Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("x-goog-api-key", svc.api_key)
    |> request.set_body(json.to_string(body))
  })
}

/// Append a per-request dynamic context block (e.g. recent blog posts) to the
/// base system prompt. Empty context leaves the prompt unchanged.
pub fn with_context(system_prompt: String, extra: String) -> String {
  case extra {
    "" -> system_prompt
    _ -> system_prompt <> "\n\n" <> extra
  }
}

pub fn generate(
  svc: Service,
  recent_context: String,
  user_message: String,
  history: List(ChatMessage),
) -> Result(String, GeminiError) {
  let system = with_context(svc.system_prompt, recent_context)
  let body = build_request_body(system, history, user_message)

  use req <- result.try(build_request(svc, body))

  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(e) { TransportError(string.inspect(e)) }),
  )

  case resp.status {
    200 -> decode_reply(resp.body)
    code -> Error(HttpStatusError(code, resp.body))
  }
}

// ---------------------------------------------------------------------------
// Request body construction
//
// Gemini's generateContent wire format:
//   { "system_instruction": { "parts": [{"text": ...}] },
//     "contents": [ { "role": "user"|"model", "parts": [{"text": ...}] }, ... ] }
// ---------------------------------------------------------------------------

pub fn build_request_body(
  system_prompt: String,
  history: List(ChatMessage),
  user_message: String,
) -> json.Json {
  let history_contents =
    list.map(history, fn(msg) {
      let role = case msg.role {
        "model" | "bot" -> "model"
        _ -> "user"
      }
      content_json(role, msg.content)
    })

  let contents =
    list.append(history_contents, [content_json("user", user_message)])

  json.object([
    #(
      "system_instruction",
      json.object([
        #(
          "parts",
          json.preprocessed_array([
            json.object([#("text", json.string(system_prompt))]),
          ]),
        ),
      ]),
    ),
    #("contents", json.preprocessed_array(contents)),
  ])
}

fn content_json(role: String, text: String) -> json.Json {
  json.object([
    #("role", json.string(role)),
    #(
      "parts",
      json.preprocessed_array([json.object([#("text", json.string(text))])]),
    ),
  ])
}

// ---------------------------------------------------------------------------
// Response decoding
// ---------------------------------------------------------------------------

fn decode_reply(body: String) -> Result(String, GeminiError) {
  json.parse(body, response_decoder())
  |> result.map_error(fn(e) { DecodeError(string.inspect(e)) })
  |> result.try(reply_from_parts)
}

/// Join a candidate's text parts into a single reply. Gemini can split one
/// candidate's text across several parts; taking only the first would truncate
/// the reply, so concatenate them all. An empty part list means no content.
pub fn reply_from_parts(parts: List(String)) -> Result(String, GeminiError) {
  case parts {
    [] -> Error(EmptyResponse)
    _ -> Ok(string.concat(parts))
  }
}

pub fn response_decoder() -> decode.Decoder(List(String)) {
  use candidates <- decode.field("candidates", decode.list(candidate_decoder()))
  // Flatten the candidate -> parts -> text structure, keeping only the first
  // candidate (matches the Go implementation which reads candidates[0]).
  case candidates {
    [] -> decode.success([])
    [first, ..] -> decode.success(first)
  }
}

fn candidate_decoder() -> decode.Decoder(List(String)) {
  use parts <- decode.subfield(
    ["content", "parts"],
    decode.list(part_decoder()),
  )
  decode.success(parts)
}

fn part_decoder() -> decode.Decoder(String) {
  decode.field("text", decode.string, decode.success)
}
