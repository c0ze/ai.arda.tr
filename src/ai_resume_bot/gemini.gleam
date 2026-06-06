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

/// Append a suffix (e.g. job_requirements.md) to the system prompt.
pub fn with_prompt_suffix(svc: Service, suffix: String) -> Service {
  Service(..svc, system_prompt: svc.system_prompt <> suffix)
}

pub fn generate(
  svc: Service,
  user_message: String,
  history: List(ChatMessage),
) -> Result(String, GeminiError) {
  let body = build_request_body(svc.system_prompt, history, user_message)
  let url =
    "https://generativelanguage.googleapis.com/v1beta/models/"
    <> svc.model
    <> ":generateContent?key="
    <> svc.api_key

  use req <- result.try(
    request.to(url) |> result.map_error(fn(_) { RequestBuildError(url) }),
  )
  let req =
    req
    |> request.set_method(Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(json.to_string(body))

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
  |> result.try(fn(parts) {
    case parts {
      [] -> Error(EmptyResponse)
      [first, ..] -> Ok(first)
    }
  })
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
