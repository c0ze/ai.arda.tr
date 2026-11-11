//// A reply with more than one [[SEND_EMAIL]] block: only the first is sent,
//// and no block (or stray tag) reaches the visitor on either endpoint. The
//// sender is a fake; nothing is mailed.

import ai_resume_bot/email
import ai_resume_bot/models.{type EmailPayload}
import ai_resume_bot/server
import ai_resume_bot/smtp
import ai_resume_bot/stream_handler
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import wisp/simulate

const two_blocks = "Thanks.\n[[SEND_EMAIL]]{\"name\":\"First\",\"email\":\"a@x.y\"}[[/SEND_EMAIL]]\nMore.\n[[SEND_EMAIL]]{\"name\":\"Second\",\"email\":\"b@x.y\"}[[/SEND_EMAIL]] [[/SEND_EMAIL]]"

/// Succeeds only for the first block's payload.
fn send_first_only(payload: EmailPayload) -> Result(Nil, smtp.SmtpError) {
  case payload.name {
    "First" -> Ok(Nil)
    other -> Error(smtp.SendFailed("sent the wrong block: " <> other))
  }
}

fn assert_clean(text: String) {
  string.contains(text, "SEND_EMAIL") |> should.be_false
  string.contains(text, "Second") |> should.be_false
  string.contains(text, "b@x.y") |> should.be_false
}

pub fn extract_strips_every_block_from_the_clean_reply_test() {
  let assert Ok(extracted) = email.extract(two_blocks)
  extracted.payload.name |> should.equal("First")
  extracted.clean_reply |> should.equal("Thanks.\n\nMore.")
}

pub fn the_streamed_done_text_has_no_block_test() {
  let text = stream_handler.final_reply(two_blocks, Some(send_first_only))
  assert_clean(text)
  text
  |> should.equal(email.reply_with_outcome("Thanks.\n\nMore.", True))
}

pub fn the_chat_json_reply_has_no_block_test() {
  let resp = server.email_reply_response(two_blocks, Some(send_first_only))
  resp.status |> should.equal(200)
  let assert Ok(reply) =
    json.parse(
      simulate.read_body(resp),
      decode.field("reply", decode.string, decode.success),
    )
  assert_clean(reply)
  reply |> should.equal(email.reply_with_outcome("Thanks.\n\nMore.", True))
}
