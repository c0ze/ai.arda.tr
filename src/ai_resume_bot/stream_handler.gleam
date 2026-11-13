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
import ai_resume_bot/guard
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
import gleam/result
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
  let with_cors = with_cors(_, req, config)
  use <- check_before_body(req, config)
  case read_body(req, guard.max_stream_body_bytes) {
    Error(mist.ExcessBody) ->
      with_cors(error_response(413, "Request body too large"))
      // The rest of the body is still on the socket: don't reuse it.
      |> response.set_header("connection", "close")
    Error(mist.MalformedBody) ->
      with_cors(error_response(400, "Failed to read request body"))
      // Where the body ends is unknown: don't reuse the socket either.
      |> response.set_header("connection", "close")
    Ok(body) ->
      case bit_array.to_string(body) {
        Error(_) ->
          with_cors(error_response(400, "Invalid UTF-8 in request body"))
        Ok(body_str) ->
          case guard.parse_chat_request(body_str) {
            Error(guard.Rejection(status, message)) ->
              with_cors(error_response(status, message))
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

/// Error responses must carry CORS headers too, otherwise the browser hides
/// the 429/400 body from the (cross-origin) frontend.
fn with_cors(
  resp: response.Response(ResponseData),
  req: request.Request(a),
  config: StreamConfig,
) -> response.Response(ResponseData) {
  let origin = case request.get_header(req, "origin") {
    Ok(v) -> v
    Error(_) -> ""
  }
  let resp =
    resp
    |> response.set_header("access-control-allow-methods", "POST, GET, OPTIONS")
    |> response.set_header("access-control-allow-headers", "Content-Type")
    |> response.set_header("vary", "origin")
  case list.contains(config.allowed_origins, origin) {
    True -> response.set_header(resp, "access-control-allow-origin", origin)
    False -> resp
  }
}

/// The checks made before the body is read: the headers, then the rate
/// limit (header checks come first, so a foreign page can't use up a
/// visitor's quota either). Their rejections leave the body unread, so they
/// close the connection (`guard.close_if_body_unread`). `next` reads the body.
pub fn check_before_body(
  req: request.Request(a),
  config: StreamConfig,
  next: fn() -> response.Response(ResponseData),
) -> response.Response(ResponseData) {
  let reject = fn(resp) {
    with_cors(resp, req, config) |> guard.close_if_body_unread(req)
  }
  case
    guard.check_headers(
      origin: request.get_header(req, "origin"),
      host: request.get_header(req, "host"),
      content_type: request.get_header(req, "content-type"),
      allowed: config.allowed_origins,
    )
  {
    Error(guard.Rejection(status, message)) ->
      reject(error_response(status, message))
    Ok(_) ->
      case
        rate_limit.check(
          config.rate_limit,
          request.get_header(req, "x-forwarded-for"),
        )
      {
        False ->
          reject(
            error_response(429, "Too many requests. Please slow down.")
            |> response.set_header(
              "retry-after",
              int.to_string(rate_limit.retry_after_seconds(config.rate_limit)),
            ),
          )
        True -> next()
      }
  }
}

/// Read the whole request body, at most `limit` bytes. `mist.read_body` only
/// checks Content-Length and accumulates a chunked body without a limit, so
/// the body is streamed and counted instead; a declared length over the limit
/// is refused before anything is read.
///
/// Known limitation of the pinned Mist (6.0.2): it assembles each HTTP chunk
/// of a chunked body whole before handing it over, so one chunk far larger
/// than `limit` is buffered in memory once before this count rejects it. The
/// limit is enforced between chunks, not inside one.
fn read_body(
  req: request.Request(mist.Connection),
  limit: Int,
) -> Result(BitArray, mist.ReadError) {
  let declared =
    request.get_header(req, "content-length")
    |> result.try(int.parse)
    |> result.unwrap(0)
  case declared > limit {
    True -> Error(mist.ExcessBody)
    False -> {
      use consume <- result.try(mist.stream(req))
      collect_body(consume, limit)
    }
  }
}

/// Pull chunks from a `mist.stream` consumer until it is done, failing with
/// `ExcessBody` as soon as more than `limit` bytes have arrived.
pub fn collect_body(
  consume: fn(Int) -> Result(mist.Chunk, mist.ReadError),
  limit: Int,
) -> Result(BitArray, mist.ReadError) {
  do_collect_body(consume, limit, <<>>)
}

fn do_collect_body(
  consume: fn(Int) -> Result(mist.Chunk, mist.ReadError),
  limit: Int,
  acc: BitArray,
) -> Result(BitArray, mist.ReadError) {
  case consume(body_read_size) {
    Error(e) -> Error(e)
    Ok(mist.Done) -> Ok(acc)
    Ok(mist.Chunk(data, next)) -> {
      let acc = bit_array.append(acc, data)
      case bit_array.byte_size(acc) > limit {
        True -> Error(mist.ExcessBody)
        False -> do_collect_body(next, limit, acc)
      }
    }
  }
}

/// Bytes asked of the socket per read while collecting a body.
const body_read_size = 65_536

/// Messages to the SSE actor. Gemini's stream arrives on its own subject and
/// is mapped in once the actor has installed its selector (`Start`).
pub type SseMsg {
  Start
  FromGemini(StreamMsg)
  ClipReady(Job, Result(tts.Clip, String))
}

pub opaque type SseState {
  SseState(
    // The whole reply from Gemini so far, [[SEND_EMAIL]] block included.
    accumulated: String,
    // Bytes of `email.streamable(accumulated)` already sent as chunks (and fed
    // to the voice): the block, and a possible partial tag, are held back.
    sent_bytes: Int,
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
  // `guard.check_chat_request` has already capped the history server-side:
  // a direct API caller can't be trusted to bound its own payload.
  let history = chat_req.history
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
    |> response.set_header("vary", "origin")
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
      new_state(config, subject, gemini_subject, voice_opts)
    },
    loop: fn(state, message, conn) {
      handle_message(state, message, fn(evt) { send_sse_event(conn, evt) })
    },
  )
}

/// The actor's state before its first message.
pub fn new_state(
  config: StreamConfig,
  self: Subject(SseMsg),
  gemini: Subject(StreamMsg),
  voice_opts: shared.VoiceOptions,
) -> SseState {
  SseState(
    accumulated: "",
    sent_bytes: 0,
    pending: <<>>,
    config: config,
    self: self,
    gemini: gemini,
    voice_opts: voice_opts,
    voice: None,
    final: None,
  )
}

/// Sends one event to the client; an `Error` means the client has gone.
pub type Emit =
  fn(shared.StreamEvent) -> Result(Nil, Nil)

/// One message to the SSE actor; `emit` sends an event to the client.
pub fn handle_message(
  state: SseState,
  message: SseMsg,
  emit: Emit,
) -> actor.Next(SseState, SseMsg) {
  case message {
    // Sent once, by `init`, before any of Gemini's messages can arrive: tell
    // the client at once that the model is thinking (and whether a voice will
    // follow), so bytes reach it while it waits for the first chunk.
    Start -> {
      let _ = emit(shared.StreamThinking)
      actor.continue(start_voice(state, emit))
      |> actor.with_selector(
        process.new_selector()
        |> process.select(state.self)
        |> process.select_map(state.gemini, FromGemini),
      )
    }
    FromGemini(message) -> on_gemini(state, message, emit)
    ClipReady(job, result) ->
      case state.voice {
        None -> actor.continue(state)
        Some(session) -> {
          case result {
            Error(e) -> logging.log(logging.Warning, e)
            Ok(_) -> Nil
          }
          apply_voice(state, voice.on_clip(session, job, result), emit)
        }
      }
  }
}

fn on_gemini(
  state: SseState,
  message: StreamMsg,
  emit: Emit,
) -> actor.Next(SseState, SseMsg) {
  case message {
    Chunk(data) -> {
      let #(deltas, pending) =
        gemini_stream.parse_sse_buffer(state.pending, data)
      let new_text = list.fold(deltas, "", fn(acc, d) { acc <> d })
      // Always carry the updated buffer forward, even with no new text yet.
      let state = SseState(..state, pending: pending)
      // Only text before a [[SEND_EMAIL]] tag is streamed (or voiced); the
      // block itself is machine-readable and goes no further than `done`.
      let accumulated = state.accumulated <> new_text
      let visible = email.streamable(accumulated, False)
      let to_send = email.unsent(visible, state.sent_bytes)
      let state =
        SseState(
          ..state,
          accumulated: accumulated,
          sent_bytes: string.byte_size(visible),
        )
      case to_send {
        "" -> actor.continue(state)
        _ ->
          case emit(shared.StreamChunk(text: to_send)) {
            Ok(_) ->
              case state.voice {
                None -> actor.continue(state)
                Some(session) ->
                  apply_voice(state, voice.on_text(session, to_send), emit)
              }
            Error(_) -> actor.stop()
          }
      }
    }

    Done -> {
      // Drain any bytes still buffered (final event without a trailing
      // newline) so the complete reply isn't missing its tail.
      let tail = gemini_stream.flush_sse_buffer(state.pending)
      let tail_text = list.fold(tail, "", fn(acc, d) { acc <> d })
      let full_reply = state.accumulated <> tail_text
      use full_reply <- end_if_empty(full_reply, emit)
      // Text held back in case it began a tag (and the stream's tail): the
      // voice still gets it; the client gets it with `done`.
      let rest =
        email.unsent(email.streamable(full_reply, True), state.sent_bytes)
      let final_reply = final_reply(full_reply, smtp.sender(state.config.smtp))
      case state.voice {
        None -> {
          let _ = emit(shared.StreamDone(text: final_reply))
          actor.stop()
        }
        Some(session) ->
          apply_voice(
            SseState(..state, final: Some(final_reply)),
            voice.on_text_done(session, rest),
            emit,
          )
      }
    }

    StreamError(reason) -> {
      logging.log(logging.Error, "Gemini stream error: " <> reason)
      let _ = emit(shared.StreamError(message: "Internal AI Error"))
      actor.stop()
    }
  }
}

/// A reply with no text (Gemini finished without any, e.g. blocked or cut
/// off) is an error, not a blank `done` the client would show and send back
/// to the model as an empty turn.
pub fn reply_or_error(full_reply: String) -> Result(String, shared.StreamEvent) {
  case string.trim(full_reply) {
    "" -> Error(shared.StreamError(message: "Empty reply"))
    _ -> Ok(full_reply)
  }
}

fn end_if_empty(
  full_reply: String,
  emit: Emit,
  next: fn(String) -> actor.Next(SseState, SseMsg),
) -> actor.Next(SseState, SseMsg) {
  case reply_or_error(full_reply) {
    Ok(reply) -> next(reply)
    Error(event) -> {
      logging.log(logging.Warning, "Gemini returned an empty reply")
      let _ = emit(event)
      actor.stop()
    }
  }
}

/// Right after `thinking`: tell a voice client whether speech will follow.
fn start_voice(state: SseState, emit: Emit) -> SseState {
  case state.voice_opts.on {
    False -> state
    True -> {
      let cfg = state.config.tts
      let on = tts.available(cfg)
      let _ = emit(shared.StreamVoice(on:))
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
  emit: Emit,
) -> actor.Next(SseState, SseMsg) {
  let cfg = state.config.tts
  let reply_to = state.self
  list.each(step.start, fn(job) {
    process.spawn_unlinked(fn() {
      process.send(reply_to, ClipReady(job, tts.synthesize(cfg, job)))
    })
  })
  let sent = list.try_each(step.emit, emit)
  let state = SseState(..state, voice: Some(step.session))
  case sent, voice.ended(step.session), state.final {
    Error(_), _, _ -> actor.stop()
    Ok(_), True, Some(final_reply) -> {
      let _ = emit(shared.StreamDone(text: final_reply))
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

/// The `done` text for a finished reply: as is, or, if it carries a
/// `[[SEND_EMAIL]]` block, the reply without any block plus the outcome of
/// sending the first block with `send`.
pub fn final_reply(reply: String, send: Option(smtp.Sender)) -> String {
  case email.contains_tag(reply) {
    False -> reply
    True ->
      case email.extract(reply) {
        Error(e) -> {
          logging.log(
            logging.Error,
            "Failed to parse email: " <> string.inspect(e),
          )
          // Never show the broken block; say that nothing was sent.
          email.reply_with_outcome(email.strip_block(reply), False)
        }
        Ok(extracted) ->
          case send {
            None -> {
              logging.log(
                logging.Warning,
                "SMTP not configured; skipping email",
              )
              email.reply_with_outcome(extracted.clean_reply, False)
            }
            Some(send) ->
              case send(extracted.payload) {
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
