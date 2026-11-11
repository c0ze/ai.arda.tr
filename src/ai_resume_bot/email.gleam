//// SEND_EMAIL tag extraction + contact payload handling,
//// ported from internal/api/api.go.

import ai_resume_bot/models.{type EmailPayload}
import gleam/bit_array
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const start_tag = "[[SEND_EMAIL]]"

pub const end_tag = "[[/SEND_EMAIL]]"

pub const contact_failure_message = "I couldn't reach Arda at this moment. Please try again later or reach him through the contact details on his website, resume, or LinkedIn."

pub const contact_success_suffix = "\n\n(Note: I have sent the email to Arda with your details.)"

/// Compose the user-facing reply after a contact-email attempt. Used by both
/// the streaming and non-streaming paths so they report success/failure
/// consistently: a failed or unconfigured send appends the failure message
/// rather than silently implying success.
pub fn reply_with_outcome(clean_reply: String, sent: Bool) -> String {
  case sent {
    True -> clean_reply <> contact_success_suffix
    False -> clean_reply <> "\n\n" <> contact_failure_message
  }
}

pub type ExtractError {
  MissingTags
  EmptyPayload
  InvalidJson(String)
}

pub type Extracted {
  Extracted(clean_reply: String, payload: EmailPayload)
}

/// Returns `Some(...)` if the reply contains either SEND_EMAIL tag; otherwise
/// `None`. The Go handler triggers the contact path whenever *either* tag is
/// present, so this mirrors that behaviour.
pub fn contains_tag(reply: String) -> Bool {
  string.contains(reply, start_tag) || string.contains(reply, end_tag)
}

pub fn extract(reply: String) -> Result(Extracted, ExtractError) {
  case string.split_once(reply, start_tag) {
    Error(_) -> Error(MissingTags)
    Ok(#(before, after_start)) ->
      case string.split_once(after_start, end_tag) {
        Error(_) -> Error(MissingTags)
        Ok(#(inner, after_end)) -> {
          let json_str = string.trim(inner)
          case json_str {
            "" -> Error(EmptyPayload)
            _ ->
              case json.parse(json_str, models.email_payload_decoder()) {
                Error(e) -> Error(InvalidJson(string.inspect(e)))
                Ok(payload) ->
                  Ok(Extracted(
                    clean_reply: string.trim(before <> after_end),
                    payload: payload,
                  ))
              }
          }
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Streaming: the machine-readable block must never reach the visitor.
// ---------------------------------------------------------------------------

/// The part of a reply streamed so far that may be shown: everything before a
/// `[[SEND_EMAIL]]` tag. Until the stream is `final`, a trailing `[`, `[[`,
/// `[[S`, ... is held back too, since it may be the start of a tag split across
/// chunks. Each call's result extends the previous one's, so the stream handler
/// sends only what is new (`unsent`).
pub fn streamable(reply: String, final: Bool) -> String {
  case string.split_once(reply, start_tag), final {
    Ok(#(before, _)), _ -> before
    Error(_), True -> reply
    Error(_), False -> drop_partial_tag(reply, string.length(start_tag) - 1)
  }
}

fn drop_partial_tag(text: String, n: Int) -> String {
  case n {
    0 -> text
    _ ->
      case string.ends_with(text, string.slice(start_tag, 0, n)) {
        True -> string.drop_end(text, n)
        False -> drop_partial_tag(text, n - 1)
      }
  }
}

/// The part of `visible` after its first `sent_bytes` bytes. Cuts fall where
/// chunks were joined or before a `[`, so they never split a character.
pub fn unsent(visible: String, sent_bytes: Int) -> String {
  let bits = bit_array.from_string(visible)
  let size = bit_array.byte_size(bits)
  case sent_bytes >= size {
    True -> ""
    False ->
      bit_array.slice(bits, sent_bytes, size - sent_bytes)
      |> result.try(bit_array.to_string)
      |> result.unwrap("")
  }
}

/// A reply whose block could not be parsed, without the block: from
/// `[[SEND_EMAIL]]` to `[[/SEND_EMAIL]]` (or to the end, if unterminated),
/// and any stray closing tag.
pub fn strip_block(reply: String) -> String {
  let without = case string.split_once(reply, start_tag) {
    Error(_) -> reply
    Ok(#(before, after_start)) ->
      case string.split_once(after_start, end_tag) {
        Ok(#(_, after_end)) -> before <> after_end
        Error(_) -> before
      }
  }
  case string.contains(without, start_tag) {
    True -> strip_block(without)
    False -> string.replace(without, end_tag, "") |> string.trim
  }
}

/// Strip CR and replace LF with a space. Matches sanitizeEmailField in the Go
/// implementation (prevents SMTP header injection via user-controlled fields).
pub fn sanitize(s: String) -> String {
  s
  |> string.replace(each: "\r\n", with: " ")
  |> string.replace(each: "\n", with: " ")
  |> string.replace(each: "\r", with: " ")
}

// ---------------------------------------------------------------------------
// Message body formatter. Kept pure so it is trivially unit-testable.
// ---------------------------------------------------------------------------

/// The whole message, headers included. `date` is an RFC 5322 date (see
/// `smtp.send`). The body is UTF-8 sent as 8bit, so a visitor's non-ASCII
/// name or company survives.
pub fn format_message(
  from from: String,
  to to: String,
  date date: String,
  payload payload: EmailPayload,
) -> String {
  let name = sanitize(payload.name)
  let org = sanitize(payload.org)
  let email = sanitize(payload.email)
  let analysis = sanitize(payload.analysis)
  let job_details = sanitize(payload.job_details)
  "From: "
  <> sanitize(from)
  <> "\r\nTo: "
  <> sanitize(to)
  <> "\r\nDate: "
  <> sanitize(date)
  <> "\r\nSubject: New Job Opportunity via AI Bot"
  <> "\r\nMIME-Version: 1.0"
  <> "\r\nContent-Type: text/plain; charset=UTF-8"
  <> "\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
  <> "Hello,\r\n\r\n"
  <> "Today I got an interesting position from "
  <> name
  <> " from "
  <> org
  <> ".\r\n\r\n"
  <> "Here are the details:\r\n"
  <> job_details
  <> "\r\n\r\n"
  <> "My Analysis:\r\n"
  <> analysis
  <> "\r\n\r\n"
  <> "You can reach them via "
  <> email
  <> "\r\n\r\n"
  <> "Best regards,\r\nArda's AI Assistant\r\n"
}

// ---------------------------------------------------------------------------
// Configuration loaded from environment variables.
// ---------------------------------------------------------------------------

pub type SmtpConfig {
  SmtpConfig(user: String, password: String, to: String)
}

pub fn config_from_env(
  gmail_user: Option(String),
  gmail_password: Option(String),
  contact_address: Option(String),
) -> Option(SmtpConfig) {
  case gmail_user, gmail_password {
    Some(user), Some(password) if user != "" && password != "" -> {
      let to = case contact_address {
        Some(addr) if addr != "" -> addr
        _ -> user
      }
      Some(SmtpConfig(user:, password:, to:))
    }
    _, _ -> None
  }
}
