//// HTTP server: POST /api/chat handler with CORS, JSON decode/encode and
//// the contact-email tag handoff. Mirrors internal/api/api.go.

import ai_resume_bot/email.{type SmtpConfig}
import ai_resume_bot/gemini
import ai_resume_bot/models.{type ChatRequest}
import ai_resume_bot/smtp
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import logging
import wisp.{type Request, type Response}

pub type Config {
  Config(
    gemini: gemini.Service,
    allowed_origins: List(String),
    smtp: Option(SmtpConfig),
    public_dir: String,
    log_requests: Bool,
  )
}

/// Top-level wisp handler. Applies CORS + routing.
///
/// Route table mirrors main.go:
///   POST /api/chat  -> Gemini
///   GET  /*         -> static files from `public_dir` (falls through to
///                      index.html on the root for SPA-ish behaviour)
pub fn handle(req: Request, config: Config) -> Response {
  use <- maybe_log_request(req, config.log_requests)
  use <- cors_middleware(req, config.allowed_origins)
  case wisp.path_segments(req) {
    ["api", "chat"] -> handle_chat(req, config)
    _ -> serve_frontend(req, config)
  }
}

fn maybe_log_request(
  req: Request,
  enabled: Bool,
  next: fn() -> Response,
) -> Response {
  case enabled {
    True -> wisp.log_request(req, next)
    False -> next()
  }
}

fn serve_frontend(req: Request, config: Config) -> Response {
  // Rewrite bare `/` to `/index.html` so serve_static picks it up (Go's
  // http.FileServer does this automatically, wisp's serve_static does not).
  let req = case req.path {
    "/" | "" -> request.set_path(req, "/index.html")
    _ -> req
  }
  use <- wisp.serve_static(req, under: "/", from: config.public_dir)
  wisp.not_found()
}

// ---------------------------------------------------------------------------
// CORS middleware. Mirrors api.CorsMiddleware in the Go backend:
//   - echoes Origin back only if it is listed in ALLOWED_ORIGINS
//   - always sets Allow-Methods / Allow-Headers
//   - short-circuits OPTIONS preflight with 200
// ---------------------------------------------------------------------------

fn cors_middleware(
  req: Request,
  allowed: List(String),
  next: fn() -> Response,
) -> Response {
  let origin = case request.get_header(req, "origin") {
    Ok(value) -> value
    Error(_) -> ""
  }

  let allow_origin = case list.contains(allowed, origin) {
    True -> Some(origin)
    False -> None
  }

  let base = case req.method {
    http.Options -> wisp.ok()
    _ -> next()
  }

  base
  |> maybe_set_header("access-control-allow-origin", allow_origin)
  |> set_header("access-control-allow-methods", "POST, GET, OPTIONS, PUT, DELETE")
  |> set_header("access-control-allow-headers", "Content-Type, Authorization")
}

fn set_header(resp: Response, key: String, value: String) -> Response {
  response.set_header(resp, key, value)
}

fn maybe_set_header(
  resp: Response,
  key: String,
  value: Option(String),
) -> Response {
  case value {
    Some(v) -> set_header(resp, key, v)
    None -> resp
  }
}

// ---------------------------------------------------------------------------
// POST /api/chat handler
// ---------------------------------------------------------------------------

fn handle_chat(req: Request, config: Config) -> Response {
  case req.method {
    http.Post -> do_chat(req, config)
    _ ->
      json_response(
        405,
        models.error_response("Method not allowed"),
      )
  }
}

fn do_chat(req: Request, config: Config) -> Response {
  use body <- wisp.require_string_body(req)
  case json.parse(body, models.chat_request_decoder()) {
    Error(_) -> json_response(400, models.error_response("Invalid JSON"))
    Ok(chat_req) -> dispatch(chat_req, config)
  }
}

fn dispatch(req: ChatRequest, config: Config) -> Response {
  case gemini.generate(config.gemini, req.message, req.history) {
    Error(err) -> {
      logging.log(logging.Error, "Gemini error: " <> string.inspect(err))
      json_response(500, models.error_response("Internal AI Error"))
    }
    Ok(reply) -> maybe_handle_email(reply, config)
  }
}

fn maybe_handle_email(reply: String, config: Config) -> Response {
  case email.contains_tag(reply) {
    False ->
      json_response(
        200,
        models.chat_response_to_json(models.ChatResponse(
          reply: reply,
          error: "",
        )),
      )
    True -> {
      case email.extract(reply) {
        Error(e) -> {
          logging.log(
            logging.Error,
            "Failed to parse email payload: " <> string.inspect(e),
          )
          json_response(
            502,
            models.error_response(email.contact_failure_message),
          )
        }
        Ok(extracted) -> send_and_respond(extracted, config)
      }
    }
  }
}

fn send_and_respond(
  extracted: email.Extracted,
  config: Config,
) -> Response {
  case config.smtp {
    None -> {
      logging.log(
        logging.Warning,
        "Email delivery is not configured; skipping contact send",
      )
      json_response(
        502,
        models.error_response(email.contact_failure_message),
      )
    }
    Some(cfg) ->
      case smtp.send(cfg, extracted.payload) {
        Error(e) -> {
          logging.log(
            logging.Error,
            "Failed to send email: " <> string.inspect(e),
          )
          json_response(
            502,
            models.error_response(email.contact_failure_message),
          )
        }
        Ok(_) -> {
          logging.log(logging.Info, "Email notification sent successfully")
          let final_reply = extracted.clean_reply <> email.contact_success_suffix
          json_response(
            200,
            models.chat_response_to_json(models.ChatResponse(
              reply: final_reply,
              error: "",
            )),
          )
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn json_response(status: Int, body: json.Json) -> Response {
  wisp.json_response(json.to_string(body), status)
}
