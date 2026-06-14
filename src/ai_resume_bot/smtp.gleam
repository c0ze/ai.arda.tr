//// SMTP delivery via Erlang interop.
////
//// We call the `gen_smtp_client` Erlang module directly. gen_smtp is the
//// canonical BEAM SMTP client (used by Bamboo, Swoosh, etc.) and is pulled
//// in transitively by common Gleam email packages; if it is not already
//// present in the release, add it to the `erlang.applications` list in
//// gleam.toml or vendor it.
////
//// Falls back gracefully when not configured (see email.config_from_env).

import ai_resume_bot/email.{type SmtpConfig}
import ai_resume_bot/models.{type EmailPayload}

pub type SmtpError {
  NotConfigured
  SendFailed(reason: String)
}

/// Send the contact email. The message body is formatted by `email.format_message`.
pub fn send(config: SmtpConfig, payload: EmailPayload) -> Result(Nil, SmtpError) {
  let body = email.format_message(config.to, payload)
  do_send(config.user, config.password, config.to, body)
}

// ---------------------------------------------------------------------------
// Erlang FFI
// ---------------------------------------------------------------------------

@external(erlang, "ai_resume_bot_smtp_ffi", "send")
fn do_send(
  user: String,
  password: String,
  to: String,
  body: String,
) -> Result(Nil, SmtpError)
