//// Request checks shared by `POST /api/chat` and `POST /api/chat/stream`.
////
//// Both endpoints are public and every accepted request is a paid Gemini
//// call, so the parsed request is bounded before it reaches the model. The
//// body sizes they read are the ones they always had (see
//// `max_stream_body_bytes`); what reaches the model is bounded by
//// `check_chat_request`, not by those. The handlers turn a `Rejection` into a
//// JSON `{"error": message}` response with its status.

import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import shared.{type ChatRequest, ChatMessage, ChatRequest}

/// Largest body `/api/chat/stream` reads, in bytes: its long-standing
/// allowance. `/api/chat` keeps Wisp's default limit (8,000,000 bytes), as it
/// always had: the sibling widgets (arda.tr, resume.arda.tr) send their whole
/// conversation, uncapped, with every question, and fall back to `/api/chat`
/// when the stream fails, so a conversation too long for the stream is still
/// answered there instead of being refused for good. The server trims the
/// history to the last `default_max_history` messages (each cut to
/// `shared.max_history_item_chars`) after parsing; that, not the body limit,
/// bounds what reaches the model.
pub const max_stream_body_bytes = 1_000_000

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

/// Reject an empty message (nothing but whitespace and other invisible
/// characters, see `is_blank`) and one over `shared.max_message_chars`; keep
/// the last `default_max_history` history items and cut each to
/// `shared.max_history_item_chars`. An accepted message goes on as sent.
///
/// Over-long history items are cut rather than rejected: the sibling widgets
/// keep a rejected message in their history and send it again with every
/// later question, so rejecting it would wedge their conversation.
pub fn check_chat_request(req: ChatRequest) -> Result(ChatRequest, Rejection) {
  case is_blank(req.message) {
    True -> Error(Rejection(400, "Message is empty"))
    False ->
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

/// A message that shows nothing: only Unicode whitespace (NBSP, the
/// ideographic space...), control characters (NUL, NEL...), and invisible
/// format or default-ignorable characters (zero-width space, joiners, BOM,
/// bidi marks, soft hyphen, variation selectors, Hangul fillers, tags).
/// `string.trim` alone lets these through to the paid model call. The three
/// clients trim with JavaScript's `String.prototype.trim` first.
fn is_blank(message: String) -> Bool {
  message
  |> string.to_utf_codepoints
  |> list.all(fn(c) { invisible(string.utf_codepoint_to_int(c)) })
}

fn invisible(c: Int) -> Bool {
  // Control characters (Cc), \t \n \r and NEL among them.
  c <= 0x20
  || { c >= 0x7F && c <= 0xA0 }
  // Whitespace (Zs, Zl, Zp), with the zero-width and bidi format characters
  // that sit between them.
  || c == 0x1680
  || { c >= 0x2000 && c <= 0x200F }
  || { c >= 0x2028 && c <= 0x202F }
  || { c >= 0x205F && c <= 0x206F }
  || c == 0x3000
  // Format characters (Cf) and other default-ignorable code points: soft
  // hyphen, combining grapheme joiner, Arabic letter mark, Hangul fillers,
  // Khmer inherent vowels, Mongolian selectors, variation selectors, BOM,
  // interlinear annotation, shorthand format, musical format, tags.
  || c == 0xAD
  || c == 0x34F
  || c == 0x61C
  || c == 0x115F
  || c == 0x1160
  || c == 0x17B4
  || c == 0x17B5
  || { c >= 0x180B && c <= 0x180F }
  || c == 0x3164
  || { c >= 0xFE00 && c <= 0xFE0F }
  || c == 0xFEFF
  || c == 0xFFA0
  || { c >= 0xFFF0 && c <= 0xFFFB }
  || { c >= 0x13430 && c <= 0x1343F }
  || { c >= 0x1BCA0 && c <= 0x1BCA3 }
  || { c >= 0x1D173 && c <= 0x1D17A }
  || { c >= 0xE0000 && c <= 0xE0FFF }
}

/// Header checks for a chat POST, made before the rate limiter and before the
/// body is read.
///
/// - A request with an `Origin` that is neither in `allowed` nor the backend's
///   own origin (its `Host`) gets 403: a browser page elsewhere must not spend
///   the model budget, even though it could never read the reply. Requests
///   without an `Origin` (curl, server-side callers) pass.
/// - Anything but an `application/json` body (a charset parameter is fine)
///   gets 415. All three clients send JSON; a "simple" `text/plain` POST,
///   which browsers send cross-origin without a preflight, does not count.
pub fn check_headers(
  origin origin: Result(String, Nil),
  host host: Result(String, Nil),
  content_type content_type: Result(String, Nil),
  allowed allowed: List(String),
) -> Result(Nil, Rejection) {
  use _ <- result.try(check_origin(origin, host, allowed))
  check_content_type(content_type)
}

fn check_origin(
  origin: Result(String, Nil),
  host: Result(String, Nil),
  allowed: List(String),
) -> Result(Nil, Rejection) {
  case origin {
    Error(_) -> Ok(Nil)
    Ok(o) ->
      case list.contains(allowed, o) || same_origin(o, host) {
        True -> Ok(Nil)
        False -> Error(Rejection(403, "Origin not allowed"))
      }
  }
}

/// The page was served by this backend (the run.app URL, or localhost on any
/// port), so its requests are same-origin and need no CORS allowance.
fn same_origin(origin: String, host: Result(String, Nil)) -> Bool {
  // An absent port is the scheme's default, so `https://api.example` and
  // `Host: api.example:443` are the same; host names compare without case.
  let origin_authority = case string.lowercase(origin) {
    "https://" <> rest -> Ok(#(rest, "443"))
    "http://" <> rest -> Ok(#(rest, "80"))
    _ -> Error(Nil)
  }
  case origin_authority, host {
    Ok(#(authority, default_port)), Ok(host) ->
      authority != ""
      && host_and_port(authority, default_port)
      == host_and_port(string.lowercase(host), default_port)
    _, _ -> False
  }
}

/// `host[:port]` (or `[v6]:port`) as a host and a port, `default_port` when
/// none is given.
fn host_and_port(authority: String, default_port: String) -> #(String, String) {
  let #(host, port) = case authority {
    "[" <> _ ->
      case string.split_once(authority, "]:") {
        Ok(#(v6, port)) -> #(v6 <> "]", port)
        Error(_) -> #(authority, "")
      }
    _ ->
      case string.split_once(authority, ":") {
        Ok(#(host, port)) -> #(host, port)
        Error(_) -> #(authority, "")
      }
  }
  case port {
    "" -> #(host, default_port)
    _ -> #(host, port)
  }
}

/// For a response sent without reading the request's body (a rejection made
/// on the headers alone, a preflight, a GET): close the connection after it
/// if the request declared a body. Mist would otherwise parse the unread body
/// as the next request on the keep-alive socket, one whose headers (its
/// X-Forwarded-For too) the sender wrote, so it would get past the per-IP rate
/// limit. Mist closes the socket after a response carrying
/// `connection: close`. Requests without a body keep the connection alive.
pub fn close_if_body_unread(
  resp: response.Response(a),
  req: request.Request(b),
) -> response.Response(a) {
  case declares_body(req.headers) {
    True -> response.set_header(resp, "connection", "close")
    False -> resp
  }
}

/// Whether request headers announce a body: any Transfer-Encoding, or a
/// Content-Length other than 0 (an unparseable one counts as a body).
pub fn declares_body(headers: List(#(String, String))) -> Bool {
  list.any(headers, fn(header) {
    case string.lowercase(header.0) {
      "transfer-encoding" -> True
      "content-length" -> string.trim(header.1) != "0"
      _ -> False
    }
  })
}

fn check_content_type(
  content_type: Result(String, Nil),
) -> Result(Nil, Rejection) {
  let media_type = case content_type {
    Ok(value) ->
      case string.split_once(value, ";") {
        Ok(#(media_type, _params)) -> media_type
        Error(_) -> value
      }
    Error(_) -> ""
  }
  case string.lowercase(string.trim(media_type)) {
    "application/json" -> Ok(Nil)
    _ -> Error(Rejection(415, "Content-Type must be application/json"))
  }
}
