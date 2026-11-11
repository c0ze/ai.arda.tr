//// SMTP delivery via Erlang interop.
////
//// We call the `gen_smtp_client` Erlang module directly. gen_smtp is the
//// canonical BEAM SMTP client (used by Bamboo, Swoosh, etc.) and is a direct
//// dependency in gleam.toml, so it is always in the release.
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
  let body =
    email.format_message(
      from: config.user,
      to: config.to,
      date: now_rfc5322(),
      payload: payload,
    )
  do_send(config.user, config.password, config.to, body)
}

// ---------------------------------------------------------------------------
// Erlang FFI
// ---------------------------------------------------------------------------

@external(erlang, "ai_resume_bot_smtp_ffi", "now_rfc5322")
fn now_rfc5322() -> String

@external(erlang, "ai_resume_bot_smtp_ffi", "send")
fn do_send(
  user: String,
  password: String,
  to: String,
  body: String,
) -> Result(Nil, SmtpError)
