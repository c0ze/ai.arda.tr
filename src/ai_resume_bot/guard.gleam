//// Request checks shared by `POST /api/chat` and `POST /api/chat/stream`.
////
//// Both endpoints are public and every accepted request is a paid Gemini
//// call, so the body is bounded before it is parsed, and the parsed request is
//// bounded before it reaches the model. The handlers turn a `Rejection` into a
//// JSON `{"error": message}` response with its status.

import gleam/int
import gleam/json
import gleam/list
import gleam/string
import shared.{type ChatRequest, ChatMessage, ChatRequest}

/// Largest request body either endpoint reads, in bytes. The siblings'
/// widgets (arda.tr, resume.arda.tr) send their whole conversation, uncapped,
/// and the server only trims it to the last `default_max_history` messages
/// after parsing, so this is sized for a long Japanese conversation (UTF-8,
/// three bytes a character), not for a single 20-message request.
pub const max_body_bytes = 262_144

pub type Rejection {
  Rejection(status: Int, message: String)
}

/// Decode a chat request body and bound it. See `check_chat_request`.
pub fn parse_chat_request(body: String) -> Result(ChatRequest, Rejection) {
  case json.parse(body, shared.chat_request_decoder()) {
    Error(_) -> Error(Rejection(400, "Invalid JSON"))
    Ok(req) -> check_chat_request(req)
  }
}

/// Reject an empty (or whitespace-only) message and one over
/// `shared.max_message_chars`; keep the last `default_max_history` history
/// items and cut each to `shared.max_history_item_chars`.
///
/// Over-long history items are cut rather than rejected: the sibling widgets
/// keep a rejected message in their history and send it again with every
/// later question, so rejecting it would wedge their conversation.
pub fn check_chat_request(req: ChatRequest) -> Result(ChatRequest, Rejection) {
  case string.trim(req.message) {
    "" -> Error(Rejection(400, "Message is empty"))
    _ ->
      case string.length(req.message) > shared.max_message_chars {
        True ->
          Error(Rejection(
            400,
            "Message is too long (at most "
              <> int.to_string(shared.max_message_chars)
              <> " characters)",
          ))
        False ->
          Ok(ChatRequest(
            message: req.message,
            history: req.history
              |> shared.cap_history(shared.default_max_history)
              |> list.map(fn(m) {
                ChatMessage(
                  ..m,
                  content: string.slice(
                    m.content,
                    0,
                    shared.max_history_item_chars,
                  ),
                )
              }),
          ))
      }
  }
}
