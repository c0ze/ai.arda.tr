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
      with_cors(error_response(429, "Too many requests. Please slow down."))
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
  SseState(accumulated: String, sent_thinking: Bool, config: StreamConfig)
}

fn start_sse(
  req: request.Request(mist.Connection),
  chat_req: shared.ChatRequest,
  config: StreamConfig,
) -> response.Response(ResponseData) {
  let gemini_svc = config.gemini
  let history = chat_req.history

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

      SseState(accumulated: "", sent_thinking: False, config: config)
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
          let deltas = gemini_stream.parse_sse_chunk(data)
          let new_text = list.fold(deltas, "", fn(acc, d) { acc <> d })
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
          let full_reply = state.accumulated
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
              extracted.clean_reply
            }
            Some(cfg) ->
              case smtp.send(cfg, extracted.payload) {
                Error(e) -> {
                  logging.log(
                    logging.Error,
                    "Email send failed: " <> string.inspect(e),
                  )
                  extracted.clean_reply
                }
                Ok(_) -> {
                  logging.log(logging.Info, "Email sent successfully")
                  extracted.clean_reply <> email.contact_success_suffix
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
