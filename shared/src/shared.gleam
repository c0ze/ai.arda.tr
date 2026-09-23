//// Shared wire types and JSON codecs for the ai.arda.tr chat API.
////
//// Used by both the Erlang backend and the Lustre (JavaScript) frontend
//// so the API contract is enforced by the compiler on both sides.

import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}

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

/// Optional voice opt-in, read from the same `/api/chat/stream` body as
/// `ChatRequest`: `"voice": true` asks the server to also stream speech for
/// the reply, `"lang"` is the UI language (`"en"`, `"ja"` or `"tr"`). Both are
/// optional; a body without `voice: true` gets exactly the text-only stream.
pub type VoiceOptions {
  VoiceOptions(on: Bool, lang: String)
}

pub fn voice_options_decoder() -> decode.Decoder(VoiceOptions) {
  use on <- decode.optional_field("voice", False, decode.bool)
  use lang <- decode.optional_field("lang", "en", decode.string)
  decode.success(VoiceOptions(on:, lang:))
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

/// The `/api/chat/stream` body. With voice off it is byte-identical to
/// `chat_request_to_json`, so text-only requests look exactly as they always
/// have.
pub fn stream_request_to_json(req: ChatRequest, voice: VoiceOptions) -> Json {
  let fields = [
    #("message", json.string(req.message)),
    #("history", json.array(req.history, chat_message_to_json)),
  ]
  case voice.on {
    False -> json.object(fields)
    True ->
      json.object(
        list.append(fields, [
          #("voice", json.bool(True)),
          #("lang", json.string(voice.lang)),
        ]),
      )
  }
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
///
/// Text-only order: `thinking` → `chunk`* → `done` | `error`.
///
/// With `"voice": true` in the request, speech events interleave with the
/// chunks, and all of them arrive before `done`:
///   `thinking` → `voice` → (`chunk` | `speech`)* → `speech_end` → `done`
/// If voice is disabled or TTS is unavailable, `voice` says `on: false` and no
/// speech events follow, so clients never wait for audio.
///
/// Offsets (`start`, `end`, mark `o`, `upto`) index the RAW reply text, i.e.
/// the concatenated `chunk` texts, in UTF-16 code units so they match
/// JavaScript string indexing (`raw.slice(0, offset)`).
pub type StreamEvent {
  /// Server is waiting for the first token from Gemini.
  StreamThinking
  /// A text delta from Gemini.
  StreamChunk(text: String)
  /// Generation complete. `text` is the full accumulated reply.
  StreamDone(text: String)
  /// Something went wrong.
  StreamError(message: String)
  /// Voice replies: whether speech will follow for this reply.
  StreamVoice(on: Bool)
  /// One spoken sentence, in order (`seq` counts from 0). It covers
  /// `raw[start..end)`. `audio` is base64 (`mime`, normally `audio/mpeg`), or
  /// `None` when the sentence failed to synthesise: reveal it at its turn,
  /// silently. `marks` map playback time to how far the text is spoken; empty
  /// when the voice returned no timepoints (reveal linearly over the clip).
  StreamSpeech(
    seq: Int,
    start: Int,
    end: Int,
    audio: Option(String),
    mime: String,
    marks: List(SpeechMark),
  )
  /// No more speech for this reply. `upto` is the end of the last voiced
  /// sentence; text past it (over the voicing cap, or unspeakable) is
  /// revealed once the audio up to `upto` has played.
  StreamSpeechEnd(upto: Int)
}

/// By `t` seconds into the clip, the raw text up to offset `offset` has been
/// spoken. JSON: `{"o": offset, "t": seconds}`.
pub type SpeechMark {
  SpeechMark(offset: Int, time: Float)
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
    StreamVoice(on) ->
      json.object([#("type", json.string("voice")), #("on", json.bool(on))])
    StreamSpeech(seq:, start:, end:, audio:, mime:, marks:) ->
      json.object([
        #("type", json.string("speech")),
        #("seq", json.int(seq)),
        #("start", json.int(start)),
        #("end", json.int(end)),
        #("audio", json.nullable(audio, json.string)),
        #("mime", json.string(mime)),
        #(
          "marks",
          json.array(marks, fn(m) {
            json.object([#("o", json.int(m.offset)), #("t", json.float(m.time))])
          }),
        ),
      ])
    StreamSpeechEnd(upto) ->
      json.object([
        #("type", json.string("speech_end")),
        #("upto", json.int(upto)),
      ])
  }
}

fn speech_mark_decoder() -> decode.Decoder(SpeechMark) {
  use offset <- decode.field("o", decode.int)
  use time <- decode.field(
    "t",
    decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)]),
  )
  decode.success(SpeechMark(offset:, time:))
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
    "voice" -> {
      use on <- decode.field("on", decode.bool)
      decode.success(StreamVoice(on:))
    }
    "speech" -> {
      use seq <- decode.field("seq", decode.int)
      use start <- decode.field("start", decode.int)
      use end <- decode.field("end", decode.int)
      use audio <- decode.field("audio", decode.optional(decode.string))
      use mime <- decode.optional_field("mime", "audio/mpeg", decode.string)
      use marks <- decode.optional_field(
        "marks",
        [],
        decode.list(speech_mark_decoder()),
      )
      decode.success(StreamSpeech(seq:, start:, end:, audio:, mime:, marks:))
    }
    "speech_end" -> {
      use upto <- decode.field("upto", decode.int)
      decode.success(StreamSpeechEnd(upto:))
    }
    _ -> decode.failure(StreamThinking, "StreamEvent")
  }
}
