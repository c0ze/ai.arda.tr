//// The SSE actor's events, driven without a socket or a model call: the
//// actor's messages are handled with a recording `emit` instead of a
//// connection, and the Gemini stream is faked with `FromGemini` messages.

import ai_resume_bot/gemini
import ai_resume_bot/gemini_stream
import ai_resume_bot/rate_limit
import ai_resume_bot/stream_handler
import ai_resume_bot/tts
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleeunit/should
import shared

fn config(tts_backend: Result(String, Nil)) -> stream_handler.StreamConfig {
  stream_handler.StreamConfig(
    gemini: gemini.new("dummy-key-never-used", "test-model", "prompt"),
    smtp: None,
    allowed_origins: [],
    rate_limit: rate_limit.Config(max_requests: 1000, window_ms: 60_000),
    tts: tts.config_from_env(fn(name) {
      case name {
        "TTS_BACKEND" -> tts_backend
        _ -> Error(Nil)
      }
    }),
  )
}

/// Handle one message and return the events it sent, in order.
fn events_for(state, message) -> List(shared.StreamEvent) {
  let sent = process.new_subject()
  let _ =
    stream_handler.handle_message(state, message, fn(event) {
      process.send(sent, event)
      Ok(Nil)
    })
  drain(sent, [])
}

fn drain(sent, acc) {
  case process.receive(sent, 0) {
    Ok(event) -> drain(sent, [event, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

fn new_state(cfg, voice: Bool) {
  stream_handler.new_state(
    cfg,
    process.new_subject(),
    process.new_subject(),
    shared.VoiceOptions(on: voice, lang: "en"),
  )
}

// `thinking` goes out as soon as the stream starts, before the model has said
// anything: clients then see bytes (and show the construct thinking) during
// the seconds the model takes to answer, instead of everything at once with
// the first chunk.
pub fn thinking_is_sent_when_the_stream_starts_test() {
  events_for(new_state(config(Error(Nil)), False), stream_handler.Start)
  |> should.equal([shared.StreamThinking])
}

pub fn a_voice_request_hears_whether_speech_follows_right_after_thinking_test() {
  events_for(new_state(config(Ok("mock")), True), stream_handler.Start)
  |> should.equal([shared.StreamThinking, shared.StreamVoice(on: True)])
}

pub fn the_first_chunk_does_not_repeat_thinking_test() {
  let chunk =
    "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hi\"}]}}]}\n\n"
  events_for(
    new_state(config(Error(Nil)), False),
    stream_handler.FromGemini(gemini_stream.Chunk(<<chunk:utf8>>)),
  )
  |> should.equal([shared.StreamChunk(text: "Hi")])
}

// A client that has gone already must not leave the paid model request
// running: when the first events cannot be sent, the actor stops (and the
// stream FFI, whose owner it is, cancels the upstream request).
pub fn the_stream_stops_if_thinking_cannot_be_sent_test() {
  stream_handler.handle_message(
    new_state(config(Error(Nil)), False),
    stream_handler.Start,
    fn(_) { Error(Nil) },
  )
  |> should.equal(actor.stop())
}

pub fn the_stream_stops_if_the_voice_event_cannot_be_sent_test() {
  stream_handler.handle_message(
    new_state(config(Ok("mock")), True),
    stream_handler.Start,
    fn(event) {
      case event {
        shared.StreamThinking -> Ok(Nil)
        _ -> Error(Nil)
      }
    },
  )
  |> should.equal(actor.stop())
}

pub fn the_stream_goes_on_when_the_first_events_are_sent_test() {
  stream_handler.handle_message(
    new_state(config(Ok("mock")), True),
    stream_handler.Start,
    fn(_) { Ok(Nil) },
  )
  |> should.not_equal(actor.stop())
}
