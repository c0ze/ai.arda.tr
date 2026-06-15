//// Entry point for the Gleam backend.
////
//// Two modes, mirroring main.go:
////   - `gleam run -- fetch`     -> fetch resume JSON into ./data and exit
////   - `gleam run`              -> boot the HTTP server on $PORT (default 8080)

import ai_resume_bot/blog
import ai_resume_bot/dotenv
import ai_resume_bot/email
import ai_resume_bot/gemini
import ai_resume_bot/prompt
import ai_resume_bot/rate_limit
import ai_resume_bot/resume
import ai_resume_bot/server.{Config}
import ai_resume_bot/stream_handler.{StreamConfig}
import argv
import envoy
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import logging
import mist
import simplifile
import wisp
import wisp/wisp_mist

const data_dir = "./data"

const job_requirements_path = "job_requirements.md"

const personal_path = "personal.md"

const job_requirements_suffix = "

If a user presents a job opportunity, evaluate it against my requirements.
1. If it's a good match, tell the user I'm interested and ask them to provide their Name, Email, and Organization so I can contact Arda.
2. If they provide this contact info, output a JSON block at the end of your response like this:
[[SEND_EMAIL]]
{
  \"name\": \"User Name\",
  \"email\": \"user@example.com\",
  \"org\": \"Organization Name\",
  \"analysis\": \"Brief analysis of why this is a good match\",
  \"job_details\": \"Summary of the job offer\"
}
[[/SEND_EMAIL]]

If the user specifically asks \"Can you contact him?\" or \"How can I reach him?\", tell them: \"I can contact Arda directly on your behalf if you have a job opportunity that matches his interests. Please paste the job description here, and I will evaluate it.\"
"

pub fn main() {
  wisp.configure_logger()
  logging.configure()

  // Load .env if present. Real process env vars take precedence; see
  // ai_resume_bot/dotenv.gleam. Missing file is not an error.
  dotenv.load_default()

  case argv.load().arguments {
    ["fetch"] -> run_fetch()
    _ -> run_server()
  }
}

// ---------------------------------------------------------------------------
// Fetch mode
// ---------------------------------------------------------------------------

fn run_fetch() -> Nil {
  logging.log(logging.Info, "Fetching resume data...")
  case resume.fetch_to_disk(data_dir) {
    Ok(_) -> logging.log(logging.Info, "Resume data fetched successfully.")
    Error(err) -> {
      logging.log(
        logging.Error,
        "Failed to fetch resume data: " <> string.inspect(err),
      )
      halt(1)
    }
  }
}

// ---------------------------------------------------------------------------
// Server mode
// ---------------------------------------------------------------------------

fn run_server() -> Nil {
  maybe_build_frontend()

  let api_key = require_env("GEMINI_API_KEY")
  let allowed_origins_raw = require_env("ALLOWED_ORIGINS")
  let allowed_origins = parse_origins(allowed_origins_raw)

  ensure_data_dir()

  let resume_data = case resume.load_from_disk(data_dir) {
    Ok(d) -> d
    Error(err) -> {
      logging.log(
        logging.Error,
        "Failed to load resume data: " <> string.inspect(err),
      )
      halt(1)
      panic as "unreachable"
    }
  }

  let system_prompt =
    prompt.build(resume_data)
    |> maybe_append_personal
    |> maybe_append_job_requirements

  let model_name = case envoy.get("GEMINI_MODEL") {
    Ok(v) if v != "" -> v
    _ -> "gemini-3.5-flash"
  }

  let gemini_service = gemini.new(api_key, model_name, system_prompt)

  let smtp_config =
    email.config_from_env(
      envoy_opt("GMAIL_USER"),
      envoy_opt("GMAIL_APP_PASSWORD"),
      envoy_opt("CONTACT_ADDRESS"),
    )

  let public_dir = case envoy.get("PUBLIC_DIR") {
    Ok(v) if v != "" -> v
    _ -> "./public"
  }

  // Per-request logging is opt-in via LOG_REQUESTS so prod stays silent
  // on Cloud Run unless explicitly enabled. Local `.env` sets it to true.
  let log_requests = case envoy.get("LOG_REQUESTS") {
    Ok(v) ->
      case string.lowercase(v) {
        "true" | "1" | "yes" | "on" -> True
        _ -> False
      }
    Error(_) -> False
  }

  // Per-IP rate limiting for the public chat endpoints (configurable via
  // RATE_LIMIT_REQUESTS / RATE_LIMIT_WINDOW_SECONDS; defaults 30 req / 60s).
  let rate_limit_config =
    rate_limit.config_from_env(
      envoy.get("RATE_LIMIT_REQUESTS"),
      envoy.get("RATE_LIMIT_WINDOW_SECONDS"),
    )
  rate_limit.init()

  // Recent blog posts are fetched in the background (default every 6h) and
  // injected into the prompt on demand so "what's Arda working on lately?"
  // works. Configurable via BLOG_FEED_URL / BLOG_REFRESH_SECONDS; failures
  // degrade gracefully (the section is simply omitted).
  let blog_feed_url = case envoy.get("BLOG_FEED_URL") {
    Ok(v) if v != "" -> v
    _ -> blog.default_feed_url
  }
  let blog_refresh_ms = case envoy.get("BLOG_REFRESH_SECONDS") {
    Ok(v) ->
      case int.parse(v) {
        Ok(n) if n > 0 -> n * 1000
        _ -> 21_600_000
      }
    Error(_) -> 21_600_000
  }
  blog.start(blog_feed_url, blog_refresh_ms)

  let config =
    Config(
      gemini: gemini_service,
      allowed_origins: allowed_origins,
      smtp: smtp_config,
      public_dir: public_dir,
      log_requests: log_requests,
      rate_limit: rate_limit_config,
    )

  let port = case envoy.get("PORT") {
    Ok(v) ->
      case int.parse(v) {
        Ok(n) -> n
        Error(_) -> 8080
      }
    Error(_) -> 8080
  }

  let secret = wisp.random_string(64)

  let stream_config =
    StreamConfig(
      gemini: gemini_service,
      smtp: smtp_config,
      allowed_origins: allowed_origins,
      rate_limit: rate_limit_config,
    )

  let wisp_handler =
    wisp_mist.handler(fn(req) { server.handle(req, config) }, secret)

  logging.log(logging.Info, "Server listening on port " <> int.to_string(port))

  let assert Ok(_) =
    fn(req: request.Request(mist.Connection)) {
      // Intercept /api/chat/stream at the Mist level for SSE streaming.
      // Everything else falls through to the Wisp handler.
      case req.method, request.path_segments(req) {
        http.Post, ["api", "chat", "stream"] ->
          stream_handler.handle_stream(req, stream_config)
        http.Options, ["api", "chat", "stream"] ->
          server.cors_preflight(req, allowed_origins)
        _, _ -> wisp_handler(req)
      }
    }
    |> mist.new
    |> mist.port(port)
    |> mist.bind("0.0.0.0")
    |> mist.start

  process.sleep_forever()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn require_env(name: String) -> String {
  case envoy.get(name) {
    Ok(v) if v != "" -> v
    _ -> {
      // Write to stdout (not stderr) and use halt_flush so the message is
      // actually visible before the BEAM tears down. Without flush, the
      // async logger / io device gets truncated by halt(1) and the user
      // just sees "Running ai_resume_bot.main" then an empty prompt.
      io.println("")
      io.println("ERROR: " <> name <> " environment variable is required.")
      io.println(
        "Set it in your shell, or put it in a .env file at the repo root",
      )
      io.println("or in gleam_backend/. Example:")
      io.println("")
      io.println("  GEMINI_API_KEY=your_key")
      io.println("  ALLOWED_ORIGINS=https://ai.arda.tr;http://localhost:8080")
      io.println("")
      halt_flush(1)
      ""
    }
  }
}

fn envoy_opt(name: String) -> option.Option(String) {
  case envoy.get(name) {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

fn parse_origins(raw: String) -> List(String) {
  raw
  |> string.split(";")
  |> list.map(string.trim)
  |> list.filter(fn(s) { s != "" })
}

fn ensure_data_dir() -> Nil {
  case simplifile.is_directory(data_dir) {
    Ok(True) -> Nil
    _ -> {
      logging.log(logging.Info, "Data directory not found. Fetching data...")
      case resume.fetch_to_disk(data_dir) {
        Ok(_) -> Nil
        Error(err) -> {
          logging.log(
            logging.Error,
            "Failed to fetch resume data: " <> string.inspect(err),
          )
          halt(1)
        }
      }
    }
  }
}

/// Build the Lustre frontend bundle into ./public if the `frontend/` sub-project
/// is present. This lets `gleam run` be a single command in local dev: the
/// backend compiles the frontend before starting the HTTP server. In the
/// production Docker image the `frontend/` directory is not copied into the
/// runtime stage, so this check is a no-op and we rely on the Dockerfile's
/// earlier build stage to have already produced the bundle.
fn maybe_build_frontend() -> Nil {
  case simplifile.is_file("frontend/gleam.toml") {
    Ok(True) -> {
      logging.log(logging.Info, "Building Lustre frontend bundle...")
      let cmd = "gleam run -m lustre/dev build --minify --outdir=../public"
      case shell("frontend", cmd) {
        Ok(_) -> logging.log(logging.Info, "Frontend build complete.")
        Error(code) -> {
          logging.log(
            logging.Error,
            "Frontend build failed with exit code "
              <> int.to_string(code)
              <> ". Aborting startup.",
          )
          halt_flush(1)
        }
      }
    }
    _ -> Nil
  }
}

/// Append the curated personal.md (interests, music, hobbies) to the system
/// prompt if present, so the bot can speak to who Arda is beyond the résumé.
/// As with the résumé data, a missing file is not an error.
fn maybe_append_personal(base: String) -> String {
  case simplifile.read(personal_path) {
    Ok(contents) -> base <> "\n\n" <> contents
    Error(_) -> base
  }
}

fn maybe_append_job_requirements(base: String) -> String {
  case simplifile.read(job_requirements_path) {
    Ok(contents) -> base <> "\n\n" <> contents <> job_requirements_suffix
    Error(_) -> base
  }
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

// erlang:halt/2 with `{flush, true}` waits for stdio buffers to drain before
// shutting the VM down. Required for error messages printed right before
// exit to actually reach the terminal.
@external(erlang, "ai_resume_bot_ffi", "halt_flush")
fn halt_flush(code: Int) -> Nil

@external(erlang, "ai_resume_bot_ffi", "shell")
fn shell(cwd: String, cmd: String) -> Result(Nil, Int)
