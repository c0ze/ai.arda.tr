//// Shared wire types and JSON codecs for the ai.arda.tr chat API.
////
//// Used by both the Erlang backend and the Lustre (JavaScript) frontend
//// so the API contract is enforced by the compiler on both sides.

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list

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

/// Default cap on how many past messages travel with a chat request. Applied
/// on the client before sending and re-applied on the server, which must not
/// trust a client to bound its own payload (and Gemini token cost). ~10 turns.
pub const default_max_history = 20

/// Keep only the most recent `max` messages of a conversation history, so a
/// long chat doesn't grow the request payload (and token cost) without bound.
/// A non-positive `max` keeps everything.
pub fn cap_history(history: List(ChatMessage), max: Int) -> List(ChatMessage) {
  case max <= 0 {
    True -> history
    False -> {
      let len = list.length(history)
      case len > max {
        True -> list.drop(history, len - max)
        False -> history
      }
    }
  }
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

// ---------------------------------------------------------------------------
// SSE stream event types
// ---------------------------------------------------------------------------

/// Events sent over the SSE `/api/chat/stream` connection.
pub type StreamEvent {
  /// Server is waiting for the first token from Gemini.
  StreamThinking
  /// A text delta from Gemini.
  StreamChunk(text: String)
  /// Generation complete. `text` is the full accumulated reply.
  StreamDone(text: String)
  /// Something went wrong.
  StreamError(message: String)
}

pub fn stream_event_to_json(evt: StreamEvent) -> Json {
  case evt {
    StreamThinking -> json.object([#("type", json.string("thinking"))])
    StreamChunk(text) ->
      json.object([
        #("type", json.string("chunk")),
        #("text", json.string(text)),
      ])
    StreamDone(text) ->
      json.object([
        #("type", json.string("done")),
        #("text", json.string(text)),
      ])
    StreamError(message) ->
      json.object([
        #("type", json.string("error")),
        #("message", json.string(message)),
      ])
  }
}

pub fn stream_event_decoder() -> decode.Decoder(StreamEvent) {
  use event_type <- decode.field("type", decode.string)
  case event_type {
    "thinking" -> decode.success(StreamThinking)
    "chunk" -> {
      use text <- decode.field("text", decode.string)
      decode.success(StreamChunk(text:))
    }
    "done" -> {
      use text <- decode.field("text", decode.string)
      decode.success(StreamDone(text:))
    }
    "error" -> {
      use message <- decode.field("message", decode.string)
      decode.success(StreamError(message:))
    }
    _ -> decode.failure(StreamThinking, "StreamEvent")
  }
}
