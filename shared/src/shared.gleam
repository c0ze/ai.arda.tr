//// Shared wire types and JSON codecs for the ai.arda.tr chat API.
////
//// Used by both the Erlang backend and the Lustre (JavaScript) frontend
//// so the API contract is enforced by the compiler on both sides.

import gleam/dynamic/decode
import gleam/json.{type Json}

// ---------------------------------------------------------------------------
// Wire types
// ---------------------------------------------------------------------------

/// A single message in the conversation history, as sent over the wire.
/// `role` is "user" or "model".
pub type ChatMessage {
  ChatMessage(role: String, content: String)
}

/// The body of `POST /api/chat`.
pub type ChatRequest {
  ChatRequest(message: String, history: List(ChatMessage))
}

/// The response from `POST /api/chat`.
pub type ChatResponse {
  ChatResponse(reply: String, error: String)
}

// ---------------------------------------------------------------------------
// Decoders (JSON -> Gleam)
// ---------------------------------------------------------------------------

pub fn chat_message_decoder() -> decode.Decoder(ChatMessage) {
  use role <- decode.field("role", decode.string)
  use content <- decode.field("content", decode.string)
  decode.success(ChatMessage(role:, content:))
}

pub fn chat_request_decoder() -> decode.Decoder(ChatRequest) {
  use message <- decode.field("message", decode.string)
  use history <- decode.optional_field(
    "history",
    [],
    decode.list(chat_message_decoder()),
  )
  decode.success(ChatRequest(message:, history:))
}

pub fn chat_response_decoder() -> decode.Decoder(ChatResponse) {
  use reply <- decode.optional_field("reply", "", decode.string)
  use error <- decode.optional_field("error", "", decode.string)
  decode.success(ChatResponse(reply:, error:))
}

// ---------------------------------------------------------------------------
// Encoders (Gleam -> JSON)
// ---------------------------------------------------------------------------

pub fn chat_message_to_json(msg: ChatMessage) -> Json {
  json.object([
    #("role", json.string(msg.role)),
    #("content", json.string(msg.content)),
  ])
}

pub fn chat_request_to_json(req: ChatRequest) -> Json {
  json.object([
    #("message", json.string(req.message)),
    #("history", json.array(req.history, chat_message_to_json)),
  ])
}

pub fn chat_response_to_json(resp: ChatResponse) -> Json {
  case resp.error {
    "" -> json.object([#("reply", json.string(resp.reply))])
    err ->
      json.object([
        #("reply", json.string(resp.reply)),
        #("error", json.string(err)),
      ])
  }
}

pub fn error_response(message: String) -> Json {
  json.object([#("error", json.string(message))])
}
