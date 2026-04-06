//// Lustre port of the chat UI that lives at ai.arda.tr.
////
//// Shape mirrors the old `public/script.js`:
////   - theme (dark / light / dracula) persisted in localStorage
////   - language toggle (en / jp) with translated strings + quick prompts
////   - chat history sent with each request to `/api/chat`
////   - markdown rendered through marked.js + DOMPurify (loaded from CDN
////     globals in `index.html` and invoked through `ffi.mjs`)

import frontend/i18n.{type Language, type Strings, En, Jp}
import frontend/icons
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/string
import lustre
import shared.{ChatMessage as WireMessage, ChatRequest}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// Cloud Run endpoint used when the page is served from anywhere other than
/// localhost. On localhost we use the same-origin relative path so the
/// Gleam backend can serve us CORS-free.
const cloud_run_base = "https://ai-arda-tr-api-599610058688.asia-northeast1.run.app"

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

pub type Theme {
  Dark
  Light
  Dracula
}

pub type Sender {
  User
  Bot
}

pub type ChatMessage {
  ChatMessage(id: Int, sender: Sender, text: String)
}

pub type Model {
  Model(
    theme: Theme,
    language: Language,
    input: String,
    history: List(ChatMessage),
    next_id: Int,
    sending: Bool,
  )
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  let theme = load_theme()
  apply_theme(theme)
  let model =
    Model(
      theme: theme,
      language: En,
      input: "",
      history: [],
      next_id: 0,
      sending: False,
    )
  reset_with_welcome(model, En)
}

// ---------------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------------

pub type Msg {
  UserToggledTheme
  UserToggledLanguage(Bool)
  UserTypedInput(String)
  UserPressedKey(String)
  UserClickedSend
  UserPickedPrompt(String)
  ApiReplied(Result(String, rsvp.Error))
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserToggledTheme -> {
      let next = next_theme(model.theme)
      save_theme(next)
      apply_theme(next)
      #(Model(..model, theme: next), effect.none())
    }

    UserToggledLanguage(is_jp) -> {
      let lang = case is_jp {
        True -> Jp
        False -> En
      }
      reset_with_welcome(model, lang)
    }

    UserTypedInput(text) -> #(Model(..model, input: text), effect.none())

    UserPressedKey("Enter") -> send_current(model)
    UserPressedKey(_) -> #(model, effect.none())

    UserClickedSend -> send_current(model)

    UserPickedPrompt(prompt) -> send_current(Model(..model, input: prompt))

    ApiReplied(Ok(reply)) -> {
      let #(model, _) = push(model, Bot, reply)
      #(Model(..model, sending: False), scroll_to_bottom())
    }

    ApiReplied(Error(_)) -> {
      let #(model, _) = push(model, Bot, "System Malfunction: Network Error")
      #(Model(..model, sending: False), scroll_to_bottom())
    }
  }
}

fn reset_with_welcome(model: Model, lang: Language) -> #(Model, Effect(Msg)) {
  let s = i18n.strings(lang)
  let cleared =
    Model(
      ..model,
      language: lang,
      history: [],
      next_id: 0,
      sending: False,
      input: "",
    )
  let #(with_welcome, _) = push(cleared, Bot, s.welcome_msg)
  #(with_welcome, scroll_to_bottom())
}

fn send_current(model: Model) -> #(Model, Effect(Msg)) {
  let text = string.trim(model.input)
  case text == "" || model.sending {
    True -> #(model, effect.none())
    False -> {
      let #(with_user, _) = push(model, User, text)
      // History sent to the backend is everything BEFORE the new user message,
      // matching the old script.js slice(0, -1) behaviour.
      let #(history_before_user, _) =
        split_last(with_user.history)
      let effect = call_api(text, history_before_user)
      #(
        Model(..with_user, input: "", sending: True),
        effect.batch([effect, scroll_to_bottom()]),
      )
    }
  }
}

fn push(
  model: Model,
  sender: Sender,
  text: String,
) -> #(Model, Int) {
  let id = model.next_id
  let msg = ChatMessage(id: id, sender: sender, text: text)
  #(
    Model(..model, history: list.append(model.history, [msg]), next_id: id + 1),
    id,
  )
}

fn split_last(items: List(a)) -> #(List(a), Bool) {
  let n = list.length(items)
  case n {
    0 -> #([], False)
    _ -> #(list.take(items, n - 1), True)
  }
}

fn next_theme(theme: Theme) -> Theme {
  case theme {
    Dark -> Light
    Light -> Dracula
    Dracula -> Dark
  }
}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

fn call_api(text: String, history: List(ChatMessage)) -> Effect(Msg) {
  let wire_history =
    list.map(history, fn(m) {
      WireMessage(role: role_of(m.sender), content: m.text)
    })
  let body = shared.chat_request_to_json(ChatRequest(
    message: text,
    history: wire_history,
  ))
  let response_decoder =
    shared.chat_response_decoder()
    |> decode.map(fn(resp) { resp.reply })
  let handler = rsvp.expect_json(response_decoder, ApiReplied)
  rsvp.post(api_endpoint(), body, handler)
}

fn role_of(sender: Sender) -> String {
  case sender {
    User -> "user"
    Bot -> "model"
  }
}

fn api_endpoint() -> String {
  case is_localhost() {
    True -> "/api/chat"
    False -> cloud_run_base <> "/api/chat"
  }
}

fn scroll_to_bottom() -> Effect(Msg) {
  effect.from(fn(_dispatch) { do_scroll_to_bottom("#messages-container") })
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  let s = i18n.strings(model.language)
  let has_messages = case model.history {
    [] -> False
    _ -> True
  }

  html.div([attribute.id("app")], [
    header(model, s),
    html.main([attribute.id("chat-area")], [
      messages_container(model, has_messages),
      welcome_screen(s, has_messages),
      quick_topics(s),
    ]),
    input_footer(model, s),
  ])
}

fn header(model: Model, s: Strings) -> Element(Msg) {
  html.header([attribute.id("header")], [
    html.div([attribute.class("header-left")], [
      html.h1([], [html.text(s.header_title)]),
    ]),
    html.div([attribute.class("header-right")], [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("theme-toggle"),
          attribute.attribute("aria-label", "Toggle theme"),
          attribute.title("Toggle theme"),
          event.on_click(UserToggledTheme),
        ],
        [icons.moon(), icons.sun(), icons.dracula()],
      ),
      language_toggle(model.language),
    ]),
  ])
}

fn language_toggle(language: Language) -> Element(Msg) {
  let is_jp = language == Jp
  html.div([attribute.class("language-toggle")], [
    html.span([attribute.class("toggle-label")], [html.text("EN")]),
    html.label(
      [
        attribute.class("switch"),
        attribute.attribute(
          "aria-label",
          "Toggle language between English and Japanese",
        ),
      ],
      [
        html.input([
          attribute.type_("checkbox"),
          attribute.id("lang-toggle"),
          attribute.checked(is_jp),
          attribute.attribute("aria-label", "Switch to Japanese"),
          event.on_check(UserToggledLanguage),
        ]),
        html.span([attribute.class("slider")], []),
      ],
    ),
    html.span([attribute.class("toggle-label")], [html.text("JP")]),
  ])
}

fn messages_container(model: Model, has_messages: Bool) -> Element(Msg) {
  let cls = case has_messages {
    True -> "has-messages"
    False -> ""
  }
  let tail = case model.sending {
    True -> [view_typing()]
    False -> []
  }
  html.div(
    [attribute.id("messages-container"), attribute.class(cls)],
    [
      html.div(
        [attribute.id("messages")],
        list.append(list.map(model.history, view_message), tail),
      ),
    ],
  )
}

fn view_message(msg: ChatMessage) -> Element(Msg) {
  let #(sender_class, avatar) = case msg.sender {
    User -> #("user", "Y")
    Bot -> #("bot", "A")
  }
  html.div(
    [
      attribute.class("message animate-fade-in " <> sender_class),
      attribute.attribute("data-msg-id", int.to_string(msg.id)),
    ],
    [
      html.div([attribute.class("message-avatar")], [html.text(avatar)]),
      element.unsafe_raw_html(
        "",
        "div",
        [attribute.class("message-content")],
        render_markdown(msg.text),
      ),
    ],
  )
}

fn view_typing() -> Element(Msg) {
  html.div([attribute.class("message bot animate-fade-in")], [
    html.div([attribute.class("message-avatar")], [html.text("A")]),
    html.div([attribute.class("message-content")], [
      html.div([attribute.class("typing-indicator")], [
        html.span([], []),
        html.span([], []),
        html.span([], []),
      ]),
    ]),
  ])
}

fn welcome_screen(s: Strings, has_messages: Bool) -> Element(Msg) {
  let cls = case has_messages {
    True -> "hidden"
    False -> ""
  }
  html.div([attribute.id("welcome-screen"), attribute.class(cls)], [
    html.div([attribute.class("welcome-icon")], [icons.terminal()]),
    html.h2([], [html.text(s.welcome_title)]),
    html.p([], [html.text(s.welcome_subtitle)]),
  ])
}

fn quick_topics(s: Strings) -> Element(Msg) {
  html.div([attribute.id("quick-topics")], [
    topic_button(s.btn_experience, s.prompt_experience, icons.briefcase()),
    topic_button(s.btn_education, s.prompt_education, icons.cap()),
    topic_button(s.btn_skills, s.prompt_skills, icons.code()),
    topic_button(s.btn_visa, s.prompt_visa, icons.calendar()),
    topic_button(s.btn_about_bot, s.prompt_about_bot, icons.info()),
  ])
}

fn topic_button(
  label: String,
  prompt: String,
  icon: Element(Msg),
) -> Element(Msg) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("topic-btn"),
      event.on_click(UserPickedPrompt(prompt)),
    ],
    [
      html.span([attribute.class("topic-icon")], [icon]),
      html.span([], [html.text(label)]),
    ],
  )
}

fn input_footer(model: Model, s: Strings) -> Element(Msg) {
  html.footer([attribute.id("input-footer")], [
    html.div([attribute.id("input-wrapper")], [
      html.input([
        attribute.type_("text"),
        attribute.id("user-input"),
        attribute.placeholder(s.input_placeholder),
        attribute.value(model.input),
        attribute.autofocus(True),
        event.on_input(UserTypedInput),
        event.on_keydown(UserPressedKey),
      ]),
      html.button(
        [
          attribute.type_("button"),
          attribute.id("send-btn"),
          attribute.attribute("aria-label", "Send message"),
          event.on_click(UserClickedSend),
        ],
        [icons.send()],
      ),
    ]),
    html.p([attribute.class("input-hint")], [
      html.text(
        "Arda's AI can make mistakes. Consider verifying important information.",
      ),
    ]),
  ])
}

// ---------------------------------------------------------------------------
// Theme persistence (localStorage via FFI)
// ---------------------------------------------------------------------------

fn load_theme() -> Theme {
  case do_storage_get("theme") {
    Ok("dark") -> Dark
    Ok("light") -> Light
    Ok("dracula") -> Dracula
    _ ->
      case do_prefers_dark() {
        True -> Dark
        False -> Light
      }
  }
}

fn save_theme(theme: Theme) -> Nil {
  do_storage_set("theme", theme_to_string(theme))
}

fn apply_theme(theme: Theme) -> Nil {
  do_set_body_theme(theme_to_string(theme))
}

fn theme_to_string(theme: Theme) -> String {
  case theme {
    Dark -> "dark"
    Light -> "light"
    Dracula -> "dracula"
  }
}

// ---------------------------------------------------------------------------
// FFI bindings
// ---------------------------------------------------------------------------

@external(javascript, "./ffi.mjs", "storage_get")
fn do_storage_get(key: String) -> Result(String, Nil)

@external(javascript, "./ffi.mjs", "storage_set")
fn do_storage_set(key: String, value: String) -> Nil

@external(javascript, "./ffi.mjs", "prefers_dark")
fn do_prefers_dark() -> Bool

@external(javascript, "./ffi.mjs", "set_body_theme")
fn do_set_body_theme(theme: String) -> Nil

@external(javascript, "./ffi.mjs", "render_markdown")
fn render_markdown(text: String) -> String

@external(javascript, "./ffi.mjs", "scroll_to_bottom")
fn do_scroll_to_bottom(selector: String) -> Nil

@external(javascript, "./ffi.mjs", "is_localhost")
fn is_localhost() -> Bool

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
