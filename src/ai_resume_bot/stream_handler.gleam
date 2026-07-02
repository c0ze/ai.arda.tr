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

import ai_resume_bot/blog
import ai_resume_bot/email.{type SmtpConfig}
import ai_resume_bot/gemini
import ai_resume_bot/gemini_stream.{Chunk, Done, StreamError}
import ai_resume_bot/rate_limit
import ai_resume_bot/smtp
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
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
  )
}

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
                Ok(chat_req) -> start_sse(req, chat_req, config)
              }
          }
      }
  }
}

type SseState {
  SseState(
    accumulated: String,
    sent_thinking: Bool,
    // Bytes from an incomplete trailing SSE line, carried between Chunk
    // messages so a `data:` line split across chunks isn't dropped.
    pending: BitArray,
    config: StreamConfig,
  )
}

fn start_sse(
  req: request.Request(mist.Connection),
  chat_req: shared.ChatRequest,
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
      // values directly to this actor's subject.
      case
        gemini_stream.stream_generate(
          gemini_svc,
          recent,
          chat_req.message,
          history,
          subject,
        )
      {
        Ok(_) -> Nil
        Error(err) -> {
          logging.log(logging.Error, "Failed to start stream: " <> err)
          process.send(subject, StreamError(err))
        }
      }

      SseState(
        accumulated: "",
        sent_thinking: False,
        pending: <<>>,
        config: config,
      )
    },
    loop: fn(state, message, conn) {
      // Send thinking event on first message if not yet sent
      let state = case state.sent_thinking {
        True -> state
        False -> {
          let _ = send_sse_event(conn, shared.StreamThinking)
          SseState(..state, sent_thinking: True)
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
                Ok(_) ->
                  actor.continue(
                    SseState(..state, accumulated: new_accumulated),
                  )
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
          let _ = send_sse_event(conn, shared.StreamDone(text: final_reply))
          actor.stop()
        }

        StreamError(reason) -> {
          logging.log(logging.Error, "Gemini stream error: " <> reason)
          let _ =
            send_sse_event(
              conn,
              shared.StreamError(message: "Internal AI Error"),
            )
          actor.stop()
        }
      }
    },
  )
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
