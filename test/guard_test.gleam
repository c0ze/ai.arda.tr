import ai_resume_bot/guard.{Rejection}
import gleam/list
import gleam/string
import gleeunit/should
import shared.{ChatMessage, ChatRequest}

// Every accepted request is a paid Gemini call, so the request must be bounded
// before it reaches the model.

pub fn empty_message_is_rejected_test() {
  guard.check_chat_request(ChatRequest(message: "", history: []))
  |> should.equal(Error(Rejection(400, "Message is empty")))
}

pub fn whitespace_only_message_is_rejected_test() {
  guard.check_chat_request(ChatRequest(message: " \n\t ", history: []))
  |> should.equal(Error(Rejection(400, "Message is empty")))
}

pub fn message_at_the_limit_is_accepted_test() {
  let msg = string.repeat("a", shared.max_message_chars)
  guard.check_chat_request(ChatRequest(message: msg, history: []))
  |> should.equal(Ok(ChatRequest(message: msg, history: [])))
}

pub fn message_over_the_limit_is_rejected_test() {
  let msg = string.repeat("a", shared.max_message_chars + 1)
  guard.check_chat_request(ChatRequest(message: msg, history: []))
  |> should.equal(
    Error(Rejection(400, "Message is too long (at most 4000 characters)")),
  )
}

pub fn the_message_limit_counts_characters_not_bytes_test() {
  // 4000 Japanese characters are 12000 bytes of UTF-8 and still fine.
  let msg = string.repeat("語", shared.max_message_chars)
  guard.check_chat_request(ChatRequest(message: msg, history: []))
  |> should.be_ok
}

pub fn over_long_history_items_are_cut_not_rejected_test() {
  // The sibling widgets resend a rejected message as history with every later
  // question; rejecting it would wedge their conversation.
  let long = string.repeat("b", shared.max_history_item_chars + 500)
  let assert Ok(req) =
    guard.check_chat_request(
      ChatRequest(message: "hi", history: [
        ChatMessage("user", long),
        ChatMessage("model", "short"),
      ]),
    )
  req.history
  |> list.map(fn(m) { string.length(m.content) })
  |> should.equal([shared.max_history_item_chars, 5])
}

pub fn history_is_capped_to_the_most_recent_messages_test() {
  let history =
    list.repeat(Nil, shared.default_max_history + 5)
    |> list.index_map(fn(_, i) { ChatMessage("user", string.inspect(i + 1)) })
  let assert Ok(req) =
    guard.check_chat_request(ChatRequest(message: "hi", history: history))
  list.length(req.history)
  |> should.equal(shared.default_max_history)
  list.first(req.history)
  |> should.equal(Ok(ChatMessage("user", "6")))
}

pub fn invalid_json_is_rejected_test() {
  guard.parse_chat_request("{not json")
  |> should.equal(Error(Rejection(400, "Invalid JSON")))
}

pub fn parse_applies_the_same_checks_test() {
  guard.parse_chat_request("{\"message\":\"   \",\"history\":[]}")
  |> should.equal(Error(Rejection(400, "Message is empty")))
  guard.parse_chat_request("{\"message\":\"hello\"}")
  |> should.equal(Ok(ChatRequest(message: "hello", history: [])))
}
