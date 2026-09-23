//// SSE endpoint for `/api/chat/stream`.
////
//// Handles the streaming path at the raw Mist level (Wisp cannot do
//// streaming responses). The flow:
////   1. Parse the POST body (same ChatRequest JSON as `/api/chat`)
////   2. Start a streaming Gemini request via the Erlang FFI
////   3. Send a `thinking` SSE event while waiting for first token
////   4. Forward text deltas as `chunk` SSE events
////   5. On completion, send `done` with the full reply
////   6. Handle email tags if present
////
//// Voice (opt-in with `"voice": true`): right after `thinking` the handler
//// says whether speech will follow (`voice`), then feeds every chunk to a
//// speech session (`voice.gleam`). Sentences are synthesised by unlinked
//// worker processes, at most 3 at a time, whose results come back to this
//// actor as `ClipReady`; `speech` events go out in order as they become
//// ready, interleaved with the text chunks. `done` is held back until
//// `speech_end` has been sent, because clients stop reading at `done`. TTS
//// failures only silence a sentence; the text always arrives.

import ai_resume_bot/blog
import ai_resume_bot/email.{type SmtpConfig}
import ai_resume_bot/gemini
import ai_resume_bot/gemini_stream.{type StreamMsg, Chunk, Done, StreamError}
import ai_resume_bot/rate_limit
import ai_resume_bot/smtp
import ai_resume_bot/speech.{type Job}
import ai_resume_bot/tts
import ai_resume_bot/voice
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import gleam/string_tree
import logging
import mist.{type ResponseData, type SSEConnection}
import shared

pub type StreamConfig {
  StreamConfig(
    gemini: gemini.Service,
    smtp: Option(SmtpConfig),
    allowed_origins: List(String),
    rate_limit: rate_limit.Config,
    tts: tts.Config,
  )
}

/// Sentences synthesised concurrently per reply.
const max_clips_in_flight = 3

/// Handle an SSE request. Must be called with a raw Mist request (not Wisp).
pub fn handle_stream(
  req: request.Request(mist.Connection),
  config: StreamConfig,
) -> response.Response(ResponseData) {
  let origin = case request.get_header(req, "origin") {
    Ok(v) -> v
    Error(_) -> ""
  }
  // Error responses must carry CORS headers too, otherwise the browser hides
  // the 429/400 body from the (cross-origin) frontend.
  let with_cors = fn(resp: response.Response(ResponseData)) {
    let resp =
      resp
      |> response.set_header(
        "access-control-allow-methods",
        "POST, GET, OPTIONS",
      )
      |> response.set_header("access-control-allow-headers", "Content-Type")
    case list.contains(config.allowed_origins, origin) {
      True -> response.set_header(resp, "access-control-allow-origin", origin)
      False -> resp
    }
  }

  case
    rate_limit.check(
      config.rate_limit,
      request.get_header(req, "x-forwarded-for"),
    )
  {
    False ->
      with_cors(
        error_response(429, "Too many requests. Please slow down.")
        |> response.set_header(
          "retry-after",
          int.to_string(rate_limit.retry_after_seconds(config.rate_limit)),
        ),
      )
    True ->
      // Read the request body
      case mist.read_body(req, 1_000_000) {
        Error(_) ->
          with_cors(error_response(400, "Failed to read request body"))
        Ok(req_with_body) ->
          case bit_array.to_string(req_with_body.body) {
            Error(_) ->
              with_cors(error_response(400, "Invalid UTF-8 in request body"))
            Ok(body_str) ->
              case json.parse(body_str, shared.chat_request_decoder()) {
                Error(_) -> with_cors(error_response(400, "Invalid JSON"))
                Ok(chat_req) -> {
                  // Voice fields are optional; a malformed one means no voice.
                  let voice_opts = case
                    json.parse(body_str, shared.voice_options_decoder())
                  {
                    Ok(v) -> v
                    Error(_) -> shared.VoiceOptions(on: False, lang: "en")
                  }
                  start_sse(req, chat_req, voice_opts, config)
                }
              }
          }
      }
  }
}

/// Messages to the SSE actor. Gemini's stream arrives on its own subject and
/// is mapped in once the actor has installed its selector (`Start`).
type SseMsg {
  Start
  FromGemini(StreamMsg)
  ClipReady(Job, Result(tts.Clip, String))
}

type SseState {
  SseState(
    accumulated: String,
    sent_thinking: Bool,
    // Bytes from an incomplete trailing SSE line, carried between Chunk
    // messages so a `data:` line split across chunks isn't dropped.
    pending: BitArray,
    config: StreamConfig,
    self: Subject(SseMsg),
    gemini: Subject(StreamMsg),
    voice_opts: shared.VoiceOptions,
    // Present while this reply is being voiced.
    voice: Option(voice.Session),
    // The final reply, held back until the speech has been sent.
    final: Option(String),
  )
}

fn start_sse(
  req: request.Request(mist.Connection),
  chat_req: shared.ChatRequest,
  voice_opts: shared.VoiceOptions,
  config: StreamConfig,
) -> response.Response(ResponseData) {
  let gemini_svc = config.gemini
  // Re-cap server-side: the client caps too, but a direct API caller can't be
  // trusted to bound its own history (and the Gemini token cost it drives).
  let history = shared.cap_history(chat_req.history, shared.default_max_history)
  // Recent blog posts (if cached) so "what's Arda working on lately?" works.
  let recent = blog.current()

  let origin = case request.get_header(req, "origin") {
    Ok(v) -> v
    Error(_) -> ""
  }
  let resp =
    response.new(200)
    |> response.set_header("access-control-allow-methods", "POST, GET, OPTIONS")
    |> response.set_header("access-control-allow-headers", "Content-Type")
  let resp = case list.contains(config.allowed_origins, origin) {
    True -> response.set_header(resp, "access-control-allow-origin", origin)
    False -> resp
  }

  mist.server_sent_events(
    request: req,
    initial_response: resp,
    init: fn(subject) {
      // Start streaming from Gemini — the FFI process sends StreamMsg
      // values directly to this subject, owned by this actor.
      let gemini_subject = process.new_subject()
      case
        gemini_stream.stream_generate(
          gemini_svc,
          recent,
          chat_req.message,
          history,
          gemini_subject,
        )
      {
        Ok(_) -> Nil
        Error(err) -> {
          logging.log(logging.Error, "Failed to start stream: " <> err)
          process.send(gemini_subject, StreamError(err))
        }
      }
      process.send(subject, Start)

      SseState(
        accumulated: "",
        sent_thinking: False,
        pending: <<>>,
        config: config,
        self: subject,
        gemini: gemini_subject,
        voice_opts: voice_opts,
        voice: None,
        final: None,
      )
    },
    loop: fn(state, message, conn) {
      case message {
        Start ->
          actor.continue(state)
          |> actor.with_selector(
            process.new_selector()
            |> process.select(state.self)
            |> process.select_map(state.gemini, FromGemini),
          )
        FromGemini(message) -> on_gemini(state, message, conn)
        ClipReady(job, result) ->
          case state.voice {
            None -> actor.continue(state)
            Some(session) -> {
              case result {
                Error(e) -> logging.log(logging.Warning, e)
                Ok(_) -> Nil
              }
              apply_voice(state, voice.on_clip(session, job, result), conn)
            }
          }
      }
    },
  )
}

fn on_gemini(
  state: SseState,
  message: StreamMsg,
  conn: SSEConnection,
) -> actor.Next(SseState, SseMsg) {
  // Send thinking event on first message if not yet sent
  let state = case state.sent_thinking {
    True -> state
    False -> {
      let _ = send_sse_event(conn, shared.StreamThinking)
      start_voice(SseState(..state, sent_thinking: True), conn)
    }
  }

  case message {
    Chunk(data) -> {
      let #(deltas, pending) =
        gemini_stream.parse_sse_buffer(state.pending, data)
      let new_text = list.fold(deltas, "", fn(acc, d) { acc <> d })
      // Always carry the updated buffer forward, even with no new text yet.
      let state = SseState(..state, pending: pending)
      case new_text {
        "" -> actor.continue(state)
        _ -> {
          let new_accumulated = state.accumulated <> new_text
          case send_sse_event(conn, shared.StreamChunk(text: new_text)) {
            Ok(_) -> {
              let state = SseState(..state, accumulated: new_accumulated)
              case state.voice {
                None -> actor.continue(state)
                Some(session) ->
                  apply_voice(state, voice.on_text(session, new_text), conn)
              }
            }
            Error(_) -> actor.stop()
          }
        }
      }
    }

    Done -> {
      // Drain any bytes still buffered (final event without a trailing
      // newline) so the complete reply isn't missing its tail.
      let tail = gemini_stream.flush_sse_buffer(state.pending)
      let tail_text = list.fold(tail, "", fn(acc, d) { acc <> d })
      let full_reply = state.accumulated <> tail_text
      let final_reply = handle_email_if_needed(full_reply, state.config)
      case state.voice {
        None -> {
          let _ = send_sse_event(conn, shared.StreamDone(text: final_reply))
          actor.stop()
        }
        Some(session) ->
          apply_voice(
            SseState(..state, final: Some(final_reply)),
            voice.on_text_done(session, tail_text),
            conn,
          )
      }
    }

    StreamError(reason) -> {
      logging.log(logging.Error, "Gemini stream error: " <> reason)
      let _ =
        send_sse_event(conn, shared.StreamError(message: "Internal AI Error"))
      actor.stop()
    }
  }
}

/// Right after `thinking`: tell a voice client whether speech will follow.
fn start_voice(state: SseState, conn: SSEConnection) -> SseState {
  case state.voice_opts.on {
    False -> state
    True -> {
      let cfg = state.config.tts
      let on = tts.available(cfg)
      let _ = send_sse_event(conn, shared.StreamVoice(on:))
      case on {
        False -> state
        True ->
          SseState(
            ..state,
            voice: Some(voice.new_capped(
              state.voice_opts.lang,
              cfg.max_chars,
              cfg.max_chars_ja,
              max_clips_in_flight,
            )),
          )
      }
    }
  }
}

/// Start the step's synthesis jobs, send its events, and send the held-back
/// `done` once the speech has ended.
fn apply_voice(
  state: SseState,
  step: voice.Step,
  conn: SSEConnection,
) -> actor.Next(SseState, SseMsg) {
  let cfg = state.config.tts
  let reply_to = state.self
  list.each(step.start, fn(job) {
    process.spawn_unlinked(fn() {
      process.send(reply_to, ClipReady(job, tts.synthesize(cfg, job)))
    })
  })
  let sent = list.try_each(step.emit, fn(evt) { send_sse_event(conn, evt) })
  let state = SseState(..state, voice: Some(step.session))
  case sent, voice.ended(step.session), state.final {
    Error(_), _, _ -> actor.stop()
    Ok(_), True, Some(final_reply) -> {
      let _ = send_sse_event(conn, shared.StreamDone(text: final_reply))
      actor.stop()
    }
    Ok(_), _, _ -> actor.continue(state)
  }
}

fn send_sse_event(
  conn: SSEConnection,
  evt: shared.StreamEvent,
) -> Result(Nil, Nil) {
  let data =
    shared.stream_event_to_json(evt)
    |> json.to_string
    |> string_tree.from_string

  mist.event(data)
  |> mist.event_name("message")
  |> mist.send_event(conn, _)
}

fn handle_email_if_needed(reply: String, config: StreamConfig) -> String {
  case email.contains_tag(reply) {
    False -> reply
    True ->
      case email.extract(reply) {
        Error(e) -> {
          logging.log(
            logging.Error,
            "Failed to parse email: " <> string.inspect(e),
          )
          reply
        }
        Ok(extracted) ->
          case config.smtp {
            None -> {
              logging.log(
                logging.Warning,
                "SMTP not configured; skipping email",
              )
              email.reply_with_outcome(extracted.clean_reply, False)
            }
            Some(cfg) ->
              case smtp.send(cfg, extracted.payload) {
                Error(e) -> {
                  logging.log(
                    logging.Error,
                    "Email send failed: " <> string.inspect(e),
                  )
                  email.reply_with_outcome(extracted.clean_reply, False)
                }
                Ok(_) -> {
                  logging.log(logging.Info, "Email sent successfully")
                  email.reply_with_outcome(extracted.clean_reply, True)
                }
              }
          }
      }
  }
}

fn error_response(
  status: Int,
  message: String,
) -> response.Response(ResponseData) {
  let body =
    json.object([#("error", json.string(message))])
    |> json.to_string
    |> bytes_tree.from_string

  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(body))
}
