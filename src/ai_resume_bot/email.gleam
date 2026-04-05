//// SEND_EMAIL tag extraction + contact payload handling,
//// ported from internal/api/api.go.

import ai_resume_bot/models.{type EmailPayload}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string

pub const start_tag = "[[SEND_EMAIL]]"

pub const end_tag = "[[/SEND_EMAIL]]"

pub const contact_failure_message = "I couldn't reach Arda at this moment. Please try again later or reach him through the contact details on his website, resume, or LinkedIn."

pub const contact_success_suffix = "\n\n(Note: I have sent the email to Arda with your details.)"

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

pub fn format_message(to: String, payload: EmailPayload) -> String {
  let name = sanitize(payload.name)
  let org = sanitize(payload.org)
  let email = sanitize(payload.email)
  let analysis = sanitize(payload.analysis)
  let job_details = sanitize(payload.job_details)
  "To: "
  <> to
  <> "\r\nSubject: New Job Opportunity via AI Bot\r\n\r\n"
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
