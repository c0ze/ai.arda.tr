//// Lustre port of the chat UI that lives at ai.arda.tr.
////
//// Shape mirrors the old `public/script.js`:
////   - rendition (night / night-hc / xerox / xerox-hc) persisted in
////     localStorage under `theme`; legacy ids migrate on read
////   - language switcher (en / jp / tr) with translated strings + quick
////     prompts, persisted in localStorage like the theme
////   - chat history sent with each request to `/api/chat/stream` (SSE)
////   - markdown rendered through marked.js + DOMPurify (loaded from CDN
////     globals in `index.html` and invoked through `ffi.mjs`)
////
//// Streaming: The frontend POSTs to `/api/chat/stream` and receives SSE
//// events: `thinking` → `chunk`* → `done`. The construct orb (a 1-bit
//// canvas owned by `ffi.mjs`, see `onebit.mjs`) simmers while the model
//// thinks and sizzles on every chunk; a crackling block cursor trails the
//// reply while it streams. Chunks are appended progressively with markdown
//// rendered live.

import frontend/i18n.{type Language, type Strings, En, Jp, Tr}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// Cloud Run endpoint used when the page is served from anywhere other than
/// localhost. On localhost we use the same-origin relative path so the
/// Gleam backend can serve us CORS-free.
const cloud_run_base = "https://ai-arda-tr-api-599610058688.asia-northeast1.run.app"

/// Cap on how many past messages are sent with each request, to bound token
/// cost / latency on long conversations (~the last 10 exchanges). The full
/// conversation is still shown in the UI. Shared with the server, which
/// re-applies the same cap on untrusted input.
const max_history_messages = shared.default_max_history

/// Host element for the construct orb's canvas (created by `ffi.mjs`).
const orb_host = "#construct-orb"

/// Where the crackle cursor goes while a reply streams.
const streaming_reply = ".msg.is-streaming .txt"

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// The four One Bit Forest renditions (see DESIGN-SYSTEM.md).
pub type Theme {
  Night
  NightHc
  Xerox
  XeroxHc
}

pub type Sender {
  User
  Bot
}

pub type ChatMessage {
  ChatMessage(id: Int, sender: Sender, text: String)
}

/// Tracks the current state of a streaming response.
pub type StreamState {
  /// No request in flight.
  Idle
  /// Waiting for the first token from Gemini.
  Thinking
  /// Receiving text chunks. `bot_msg_id` is the message being built.
  Streaming(bot_msg_id: Int)
}

pub type Model {
  Model(
    theme: Theme,
    language: Language,
    input: String,
    history: List(ChatMessage),
    next_id: Int,
    stream_state: StreamState,
  )
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  let theme = load_theme()
  apply_theme(theme)
  let language = load_language()
  apply_language(language)
  let model =
    Model(
      theme: theme,
      language: language,
      input: "",
      history: [],
      next_id: 0,
      stream_state: Idle,
    )
  let #(model, effects) = reset_with_welcome(model, language)
  #(model, effect.batch([effects, orb_mount()]))
}

// ---------------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------------

pub type Msg {
  UserCycledTheme
  UserPickedLanguage(Language)
  UserTypedInput(String)
  UserPressedEnter
  UserClickedSend
  UserPickedPrompt(String)
  StreamEventReceived(String)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserCycledTheme -> {
      let next = next_theme(model.theme)
      save_theme(next)
      apply_theme(next)
      #(Model(..model, theme: next), effect.none())
    }

    UserPickedLanguage(lang) ->
      // Re-clicking the active language must not wipe the conversation.
      case lang == model.language {
        True -> #(model, effect.none())
        False -> {
          save_language(lang)
          apply_language(lang)
          reset_with_welcome(model, lang)
        }
      }

    UserTypedInput(text) -> #(Model(..model, input: text), effect.none())

    UserPressedEnter -> send_current(model)

    UserClickedSend -> send_current(model)

    UserPickedPrompt(prompt) -> send_current(Model(..model, input: prompt))

    StreamEventReceived(json_str) -> handle_stream_event(model, json_str)
  }
}

fn handle_stream_event(model: Model, json_str: String) -> #(Model, Effect(Msg)) {
  case json.parse(json_str, shared.stream_event_decoder()) {
    Error(_) -> #(model, effect.none())
    Ok(evt) ->
      case evt {
        shared.StreamThinking -> {
          // Add a placeholder bot message; until its first chunk it shows
          // only the crackle cursor while the orb simmers.
          let #(model, bot_id) = push(model, Bot, "")
          #(
            Model(..model, stream_state: Streaming(bot_msg_id: bot_id)),
            effect.batch([
              scroll_to_bottom(),
              orb_sizzle(),
              orb_simmer(True),
              cursor_trail(),
            ]),
          )
        }

        shared.StreamChunk(text) -> {
          case model.stream_state {
            Streaming(bot_msg_id) -> {
              let model = append_to_message(model, bot_msg_id, text)
              #(
                model,
                effect.batch([
                  scroll_to_bottom(),
                  orb_sizzle(),
                  orb_simmer(False),
                  cursor_trail(),
                ]),
              )
            }
            _ -> #(model, effect.none())
          }
        }

        shared.StreamDone(text) -> {
          case model.stream_state {
            Streaming(bot_msg_id) -> {
              // Replace with the final complete text (may include email
              // success suffix from the server).
              let model = replace_message_text(model, bot_msg_id, text)
              #(Model(..model, stream_state: Idle), settle())
            }
            _ -> {
              let #(model, _) = push(model, Bot, text)
              #(Model(..model, stream_state: Idle), settle())
            }
          }
        }

        shared.StreamError(message) -> {
          let error_text = "System Malfunction: " <> message
          case model.stream_state {
            Streaming(bot_msg_id) -> {
              let has_partial_text =
                list.any(model.history, fn(msg) {
                  msg.id == bot_msg_id && msg.text != ""
                })
              let model = case has_partial_text {
                True -> {
                  let #(model, _) = push(model, Bot, error_text)
                  model
                }
                False -> replace_message_text(model, bot_msg_id, error_text)
              }
              #(Model(..model, stream_state: Idle), settle())
            }
            _ -> {
              let #(model, _) = push(model, Bot, error_text)
              #(Model(..model, stream_state: Idle), settle())
            }
          }
        }
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
      stream_state: Idle,
      input: "",
    )
  let #(with_welcome, _) = push(cleared, Bot, s.welcome_msg)
  // A language switch mid-reply drops the stream, so quiet the construct.
  #(with_welcome, settle())
}

fn send_current(model: Model) -> #(Model, Effect(Msg)) {
  let text = string.trim(model.input)
  let is_busy = model.stream_state != Idle
  case text == "" || is_busy {
    True -> #(model, effect.none())
    False -> {
      let #(with_user, _) = push(model, User, text)
      // History sent to the backend is everything BEFORE the new user message,
      // matching the old script.js slice(0, -1) behaviour.
      let #(history_before_user, _) = split_last(with_user.history)
      let effect = call_api_stream(text, history_before_user)
      #(
        Model(..with_user, input: "", stream_state: Thinking),
        effect.batch([effect, scroll_to_bottom(), cursor_trail()]),
      )
    }
  }
}

fn push(model: Model, sender: Sender, text: String) -> #(Model, Int) {
  let id = model.next_id
  let msg = ChatMessage(id: id, sender: sender, text: text)
  #(
    Model(..model, history: list.append(model.history, [msg]), next_id: id + 1),
    id,
  )
}

fn append_to_message(model: Model, msg_id: Int, text: String) -> Model {
  let history =
    list.map(model.history, fn(m) {
      case m.id == msg_id {
        True -> ChatMessage(..m, text: m.text <> text)
        False -> m
      }
    })
  Model(..model, history: history)
}

fn replace_message_text(model: Model, msg_id: Int, text: String) -> Model {
  let history =
    list.map(model.history, fn(m) {
      case m.id == msg_id {
        True -> ChatMessage(..m, text: text)
        False -> m
      }
    })
  Model(..model, history: history)
}

fn split_last(items: List(a)) -> #(List(a), Bool) {
  let n = list.length(items)
  case n {
    0 -> #([], False)
    _ -> #(list.take(items, n - 1), True)
  }
}

fn next_theme(theme: Theme) -> Theme {
  // Night -> Night HC -> Xerox -> Xerox HC -> Night
  case theme {
    Night -> NightHc
    NightHc -> Xerox
    Xerox -> XeroxHc
    XeroxHc -> Night
  }
}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

fn call_api_stream(text: String, history: List(ChatMessage)) -> Effect(Msg) {
  let wire_history =
    history
    // Drop the leading assistant welcome message: it is UI-only chrome, and
    // Gemini's `contents` should begin with a user turn rather than a model
    // turn (and we needn't spend tokens echoing our own canned greeting).
    |> list.drop_while(fn(m) { m.sender == Bot })
    |> list.map(fn(m) {
      shared.ChatMessage(role: role_of(m.sender), content: m.text)
    })
    |> shared.cap_history(max_history_messages)
  let body =
    shared.chat_request_to_json(shared.ChatRequest(
      message: text,
      history: wire_history,
    ))
    |> json.to_string

  effect.from(fn(dispatch) {
    do_stream_chat(stream_endpoint(), body, fn(json_str) {
      dispatch(StreamEventReceived(json_str))
    })
  })
}

fn role_of(sender: Sender) -> String {
  case sender {
    User -> "user"
    Bot -> "model"
  }
}

fn stream_endpoint() -> String {
  case is_localhost() {
    True -> "/api/chat/stream"
    False -> cloud_run_base <> "/api/chat/stream"
  }
}

fn scroll_to_bottom() -> Effect(Msg) {
  effect.from(fn(_dispatch) { do_scroll_to_bottom("#messages-container") })
}

/// The orb's canvas lives outside Lustre's vdom, so mount it once the host
/// element exists.
fn orb_mount() -> Effect(Msg) {
  effect.after_paint(fn(_dispatch, _root) { do_mount_orb(orb_host) })
}

fn orb_sizzle() -> Effect(Msg) {
  effect.from(fn(_dispatch) { do_sizzle_orb(orb_host) })
}

fn orb_simmer(on: Bool) -> Effect(Msg) {
  effect.from(fn(_dispatch) { do_simmer_orb(orb_host, on) })
}

/// Runs after Lustre patches the DOM but before paint, so the cursor is back
/// at the end of the reply in the same frame the new text appears.
fn cursor_trail() -> Effect(Msg) {
  effect.before_paint(fn(_dispatch, _root) { do_trail_cursor(streaming_reply) })
}

/// The reply is over (done, error or cleared): stop the cursor and simmer.
fn settle() -> Effect(Msg) {
  effect.batch([
    scroll_to_bottom(),
    orb_simmer(False),
    effect.from(fn(_dispatch) { do_stop_cursor() }),
  ])
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  let s = i18n.strings(model.language)

  html.div([attribute.id("app")], [
    header(model, s),
    html.main([attribute.id("chat-area")], [
      construct(model, s),
      messages_container(model, s),
    ]),
    input_footer(model, s),
  ])
}

fn header(model: Model, s: Strings) -> Element(Msg) {
  html.header([attribute.id("header"), attribute.class("bar")], [
    html.span([attribute.class("site")], [
      html.i([attribute.attribute("aria-hidden", "true")], []),
      html.text("ai.arda.tr"),
    ]),
    html.span([attribute.class("bar-title")], [html.text(s.header_title)]),
    html.span([attribute.class("sp")], []),
    language_toggle(model.language),
    theme_toggle(model.theme),
  ])
}

fn theme_toggle(theme: Theme) -> Element(Msg) {
  let label =
    "Rendition: "
    <> theme_name(theme)
    <> ". Switch to "
    <> theme_name(next_theme(theme))
  html.button(
    [
      attribute.type_("button"),
      attribute.class("theme-toggle"),
      attribute.attribute("aria-label", label),
      attribute.title(label),
      event.on_click(UserCycledTheme),
    ],
    [html.text(theme_name(theme))],
  )
}

fn language_toggle(language: Language) -> Element(Msg) {
  html.div(
    [
      attribute.class("language-toggle"),
      attribute.attribute("role", "group"),
      attribute.attribute("aria-label", "Language"),
    ],
    [
      language_button(En, "EN", "Switch to English", language),
      language_button(Jp, "JP", "Switch to Japanese", language),
      language_button(Tr, "TR", "Switch to Turkish", language),
    ],
  )
}

fn language_button(
  lang: Language,
  label: String,
  aria_label: String,
  current: Language,
) -> Element(Msg) {
  let is_active = lang == current
  let class = case is_active {
    True -> "lang-btn active"
    False -> "lang-btn"
  }
  html.button(
    [
      attribute.type_("button"),
      attribute.class(class),
      attribute.attribute("aria-label", aria_label),
      attribute.attribute("aria-pressed", case is_active {
        True -> "true"
        False -> "false"
      }),
      event.on_click(UserPickedLanguage(lang)),
    ],
    [html.text(label)],
  )
}

/// The orb, the heading, and a live status line. The orb host has no Lustre
/// children, so the canvas `ffi.mjs` puts in it survives every re-render.
fn construct(model: Model, s: Strings) -> Element(Msg) {
  let #(status, busy) = case model.stream_state {
    Idle -> #(s.status_ready, False)
    Thinking -> #(s.status_thinking, True)
    Streaming(id) ->
      case list.any(model.history, fn(m) { m.id == id && m.text != "" }) {
        True -> #(s.status_writing, True)
        False -> #(s.status_thinking, True)
      }
  }
  html.div([attribute.class("ai-id")], [
    html.div(
      [
        attribute.id("construct-orb"),
        attribute.class("orb"),
        attribute.attribute("aria-hidden", "true"),
      ],
      [],
    ),
    html.div([attribute.class("ai-id-text")], [
      html.h1([], [html.text(s.construct_title)]),
      html.p([attribute.class("sub")], [html.text(s.construct_subline)]),
      html.p(
        [
          attribute.class("state"),
          attribute.classes([#("is-busy", busy)]),
          attribute.attribute("role", "status"),
          attribute.attribute("aria-live", "polite"),
        ],
        [html.text(status)],
      ),
    ]),
  ])
}

fn messages_container(model: Model, s: Strings) -> Element(Msg) {
  let tail = case model.stream_state {
    Thinking -> [view_pending(s)]
    _ -> []
  }
  html.div([attribute.id("messages-container")], [
    html.div(
      [attribute.id("messages")],
      list.append(
        list.map(model.history, fn(msg) {
          view_message(msg, model.stream_state, s)
        }),
        tail,
      ),
    ),
  ])
}

fn view_message(
  msg: ChatMessage,
  stream_state: StreamState,
  s: Strings,
) -> Element(Msg) {
  let is_streaming_this = case stream_state {
    Streaming(id) if id == msg.id -> True
    _ -> False
  }
  let is_error = string.starts_with(msg.text, "System Malfunction: ")
  let text = case msg.text {
    // Waiting for the first chunk: an empty column for the crackle cursor.
    "" -> html.div([attribute.class("txt")], [])
    _ ->
      element.unsafe_raw_html(
        "",
        "div",
        [attribute.class("txt")],
        render_markdown(msg.text),
      )
  }
  html.div(
    [
      attribute.class("msg " <> sender_class(msg.sender)),
      attribute.classes([
        #("is-streaming", is_streaming_this),
        #("is-error", is_error),
      ]),
      attribute.attribute("data-msg-id", int.to_string(msg.id)),
    ],
    [who(msg.sender, s), text],
  )
}

/// Sent, but the server has not said `thinking` yet.
fn view_pending(s: Strings) -> Element(Msg) {
  html.div([attribute.class("msg bot is-streaming")], [
    who(Bot, s),
    html.div([attribute.class("txt")], []),
  ])
}

fn sender_class(sender: Sender) -> String {
  case sender {
    User -> "user"
    Bot -> "bot"
  }
}

fn who(sender: Sender, s: Strings) -> Element(Msg) {
  let label = case sender {
    User -> s.who_you
    Bot -> s.who_construct
  }
  html.div([attribute.class("who")], [html.text(label)])
}

fn quick_topics(s: Strings) -> Element(Msg) {
  html.div([attribute.id("quick-topics")], [
    topic_button("1", s.btn_experience, s.prompt_experience),
    topic_button("2", s.btn_education, s.prompt_education),
    topic_button("3", s.btn_skills, s.prompt_skills),
    topic_button("4", s.btn_visa, s.prompt_visa),
    topic_button("5", s.btn_about_bot, s.prompt_about_bot),
  ])
}

fn topic_button(number: String, label: String, prompt: String) -> Element(Msg) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("topic-btn"),
      event.on_click(UserPickedPrompt(prompt)),
    ],
    [
      html.em([attribute.attribute("aria-hidden", "true")], [
        html.text(number),
      ]),
      html.text(label),
    ],
  )
}

fn input_footer(model: Model, s: Strings) -> Element(Msg) {
  html.footer([attribute.id("input-footer")], [
    quick_topics(s),
    html.div([attribute.id("input-wrapper")], [
      html.span(
        [attribute.class("prompt"), attribute.attribute("aria-hidden", "true")],
        [
          html.text("▸"),
        ],
      ),
      html.span(
        [attribute.class("cur"), attribute.attribute("aria-hidden", "true")],
        [],
      ),
      html.input([
        attribute.type_("text"),
        attribute.id("user-input"),
        attribute.placeholder(s.input_placeholder),
        attribute.attribute("aria-label", s.input_placeholder),
        attribute.attribute("autocomplete", "off"),
        attribute.attribute("enterkeyhint", "send"),
        attribute.value(model.input),
        attribute.autofocus(True),
        event.on_input(UserTypedInput),
        event.on("keydown", enter_decoder()),
      ]),
      html.button(
        [
          attribute.type_("button"),
          attribute.id("send-btn"),
          attribute.attribute("aria-label", "Send message"),
          attribute.disabled(model.stream_state != Idle),
          event.on_click(UserClickedSend),
        ],
        [html.text("enter ↵")],
      ),
    ]),
    html.p([attribute.class("input-hint")], [
      html.text(s.disclaimer),
    ]),
  ])
}

/// Enter sends, except while an IME is composing: confirming a Japanese
/// conversion also fires Enter (`isComposing`, or keyCode 229 in Safari).
fn enter_decoder() -> decode.Decoder(Msg) {
  use key <- decode.field("key", decode.string)
  use composing <- decode.optional_field("isComposing", False, decode.bool)
  use key_code <- decode.optional_field("keyCode", 0, decode.int)
  case key == "Enter" && !composing && key_code != 229 {
    True -> decode.success(UserPressedEnter)
    False -> decode.failure(UserPressedEnter, "Enter outside composition")
  }
}

// ---------------------------------------------------------------------------
// Theme persistence (localStorage via FFI)
// ---------------------------------------------------------------------------

fn load_theme() -> Theme {
  case do_storage_get("theme") {
    Ok(id) -> theme_from_string(id)
    Error(_) -> Night
  }
}

/// Night is the default. Ids stored by the pre-2026-09 UI migrate by role;
/// the pre-hydration script in gleam.toml applies the same mapping.
fn theme_from_string(id: String) -> Theme {
  case id {
    "night-hc" | "carbon" -> NightHc
    "xerox" | "light" -> Xerox
    "xerox-hc" | "paper" -> XeroxHc
    _ -> Night
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
    Night -> "night"
    NightHc -> "night-hc"
    Xerox -> "xerox"
    XeroxHc -> "xerox-hc"
  }
}

fn theme_name(theme: Theme) -> String {
  case theme {
    Night -> "night"
    NightHc -> "night hc"
    Xerox -> "xerox"
    XeroxHc -> "xerox hc"
  }
}

// ---------------------------------------------------------------------------
// Language persistence (localStorage via FFI, mirroring the theme)
// ---------------------------------------------------------------------------

fn load_language() -> Language {
  case do_storage_get("language") {
    Ok("jp") -> Jp
    Ok("tr") -> Tr
    _ -> En
  }
}

fn save_language(language: Language) -> Nil {
  do_storage_set("language", language_to_string(language))
}

/// Keep `<html lang="...">` in sync with the UI locale (the static value baked
/// into index.html is only the pre-hydration default).
fn apply_language(language: Language) -> Nil {
  do_set_document_lang(lang_code(language))
}

/// Storage keys: short site-local identifiers ("jp" matches the historic
/// script.js value, so existing visitors keep their choice).
fn language_to_string(language: Language) -> String {
  case language {
    En -> "en"
    Jp -> "jp"
    Tr -> "tr"
  }
}

/// BCP-47 codes for the `lang` attribute (Japanese is "ja", not "jp").
fn lang_code(language: Language) -> String {
  case language {
    En -> "en"
    Jp -> "ja"
    Tr -> "tr"
  }
}

// ---------------------------------------------------------------------------
// FFI bindings
// ---------------------------------------------------------------------------

@external(javascript, "./ffi.mjs", "storage_get")
fn do_storage_get(key: String) -> Result(String, Nil)

@external(javascript, "./ffi.mjs", "storage_set")
fn do_storage_set(key: String, value: String) -> Nil

@external(javascript, "./ffi.mjs", "set_body_theme")
fn do_set_body_theme(theme: String) -> Nil

@external(javascript, "./ffi.mjs", "set_document_lang")
fn do_set_document_lang(lang: String) -> Nil

@external(javascript, "./ffi.mjs", "render_markdown")
fn render_markdown(text: String) -> String

@external(javascript, "./ffi.mjs", "scroll_to_bottom")
fn do_scroll_to_bottom(selector: String) -> Nil

@external(javascript, "./ffi.mjs", "is_localhost")
fn is_localhost() -> Bool

@external(javascript, "./ffi.mjs", "stream_chat")
fn do_stream_chat(url: String, body: String, on_event: fn(String) -> Nil) -> Nil

@external(javascript, "./ffi.mjs", "mount_orb")
fn do_mount_orb(selector: String) -> Nil

@external(javascript, "./ffi.mjs", "sizzle_orb")
fn do_sizzle_orb(selector: String) -> Nil

@external(javascript, "./ffi.mjs", "simmer_orb")
fn do_simmer_orb(selector: String, on: Bool) -> Nil

@external(javascript, "./ffi.mjs", "trail_cursor")
fn do_trail_cursor(selector: String) -> Nil

@external(javascript, "./ffi.mjs", "stop_cursor")
fn do_stop_cursor() -> Nil

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
