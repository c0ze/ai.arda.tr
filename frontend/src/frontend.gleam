//// Lustre port of the chat UI that lives at ai.arda.tr.
////
//// Shape mirrors the old `public/script.js`:
////   - light or dark scheme, dark unless the visitor pins light; the pin is
////     kept in localStorage under `theme` by the family's `scheme.js`, and the
////     page reads it before first paint (see `frontend/gleam.toml`)
////   - language switcher (en / jp / tr) with translated strings + quick
////     prompts, persisted in localStorage
////   - chat history sent with each request to `/api/chat/stream` (SSE)
////   - markdown rendered through marked.js + DOMPurify (vendored under
////     `public/vendor/`, loaded as globals by `index.html` and invoked
////     through `ffi.mjs`)
////
//// Streaming: The frontend POSTs to `/api/chat/stream` and receives SSE
//// events: `thinking` → `chunk`* → `done`. Chunks are appended progressively
//// with markdown rendered live. The assistant is the ember (`.ix-mark` in
//// brand.css): it glows while a reply is awaited or written, and that is all
//// the motion there is.
////
//// Voice: unless muted (the voice toggle, persisted by voice.mjs), requests
//// ask for speech too. The speaker in `ffi.mjs` / `voice.mjs` plays it through
//// a robot filter and reports how far the voice has got; the reply is shown
//// only up to there (`Speaking`), so it is written as it is spoken, and the
//// ember glows with the voice's loudness.

import frontend/i18n.{type Language, type Strings, En, Jp, Tr}
import frontend/wordmark
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

/// The ember of the reply being written or spoken. While the voice speaks,
/// `ffi.mjs` sets its loudness on it as `--ix-level` (see brand.css).
const speaking_mark = ".msg.is-streaming .ix-mark"

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

pub type Sender {
  User
  Bot
}

/// `is_error`: a client-side error line, not the model's words; it is never
/// sent back to the model as history.
pub type ChatMessage {
  ChatMessage(id: Int, sender: Sender, text: String, is_error: Bool)
}

/// How much of a reply the voice lets us show.
pub type Speech {
  /// No gating: every message shows all of its text.
  Silent
  /// Message `msg_id` shows its first `shown` UTF-16 units while spoken.
  Speaking(msg_id: Int, shown: Int)
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
    language: Language,
    input: String,
    history: List(ChatMessage),
    next_id: Int,
    stream_state: StreamState,
    voice_on: Bool,
    natural: Natural,
    speech: Speech,
    // Bumped by every send and every reset; stream events carry the value
    // they were started with, and events from an older request are dropped.
    generation: Int,
    // The last completed reply, for the screen-reader live region. Set once
    // when a reply completes (not on every chunk), cleared on send.
    announcement: String,
  )
}

/// The natural English voice: a model that runs in the visitor's browser
/// (natural.mjs). They opt in to its download; until it is `NaturalOn`,
/// English replies are spoken by the server's voice.
pub type Natural {
  NaturalOff
  /// Downloading or starting, with the download's percentage.
  NaturalLoading(Int)
  NaturalOn
  NaturalFailed
}

pub fn init(_flags) -> #(Model, Effect(Msg)) {
  let language = load_language()
  apply_language(language)
  let wanted = do_natural_wanted()
  let model =
    Model(
      language: language,
      input: "",
      history: [],
      next_id: 0,
      stream_state: Idle,
      voice_on: do_voice_enabled(),
      natural: case wanted {
        True -> NaturalLoading(0)
        False -> NaturalOff
      },
      speech: Silent,
      generation: 0,
      announcement: "",
    )
  let #(model, effects) = reset_with_welcome(model, language)
  // A visitor who chose the natural voice before gets it back: from the
  // browser's cache, so no download.
  let natural = case wanted {
    True -> natural_load()
    False -> effect.none()
  }
  #(model, effect.batch([effects, scheme_watch(), natural]))
}

// ---------------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------------

pub type Msg {
  UserToggledScheme
  UserPickedLanguage(Language)
  UserTypedInput(String)
  UserPressedEnter
  UserClickedSend
  UserPickedPrompt(String)
  UserToggledVoice
  UserToggledNatural
  NaturalProgressed(Int)
  NaturalLoaded
  NaturalBroke
  /// An SSE event of the request started with `generation`.
  StreamEventReceived(generation: Int, json: String)
  SpeechRevealed(Int)
  SpeechEnded
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // The scheme is not in the model: scheme.js keeps it on <html>, and
    // brand.css shows the switch's label from there.
    UserToggledScheme -> #(
      model,
      effect.from(fn(_dispatch) { do_scheme_toggle() }),
    )

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

    UserToggledVoice -> {
      let on = !model.voice_on
      // Muting makes the current speaker stop and reveal everything, which
      // comes back as SpeechRevealed(-1) and SpeechEnded.
      #(
        Model(..model, voice_on: on),
        effect.from(fn(_dispatch) { do_set_voice_enabled(on) }),
      )
    }

    UserToggledNatural ->
      case model.natural {
        NaturalOff | NaturalFailed -> #(
          Model(..model, natural: NaturalLoading(0)),
          natural_load(),
        )
        // Turning it off keeps the download in the browser's cache.
        NaturalOn -> #(
          Model(..model, natural: NaturalOff),
          effect.from(fn(_dispatch) { do_natural_drop() }),
        )
        NaturalLoading(_) -> #(model, effect.none())
      }

    NaturalProgressed(percent) ->
      case model.natural {
        NaturalLoading(_) -> #(
          Model(..model, natural: NaturalLoading(percent)),
          effect.none(),
        )
        _ -> #(model, effect.none())
      }

    NaturalLoaded ->
      case model.natural {
        NaturalLoading(_) -> #(
          Model(..model, natural: NaturalOn),
          effect.none(),
        )
        _ -> #(model, effect.none())
      }

    NaturalBroke ->
      case model.natural {
        NaturalLoading(_) -> #(
          Model(..model, natural: NaturalFailed),
          effect.none(),
        )
        _ -> #(model, effect.none())
      }

    // A reply to a request that was replaced or reset (a language switch
    // mid-reply) must not land in the current conversation.
    StreamEventReceived(generation, _) if generation != model.generation -> #(
      model,
      effect.none(),
    )
    StreamEventReceived(_, json_str) -> handle_stream_event(model, json_str)

    SpeechRevealed(shown) -> {
      let speech = case shown < 0, model.speech, model.stream_state {
        True, _, _ -> Silent
        False, Speaking(msg_id: id, ..), _ -> Speaking(msg_id: id, shown:)
        False, Silent, Streaming(id) -> Speaking(msg_id: id, shown:)
        False, Silent, _ -> Silent
      }
      #(Model(..model, speech: speech), scroll_to_bottom())
    }

    SpeechEnded -> {
      let model = Model(..model, speech: Silent)
      case model.stream_state {
        Idle -> #(model, scroll_to_bottom())
        _ -> #(model, effect.none())
      }
    }
  }
}

fn handle_stream_event(model: Model, json_str: String) -> #(Model, Effect(Msg)) {
  case json.parse(json_str, shared.stream_event_decoder()) {
    Error(_) -> #(model, effect.none())
    Ok(evt) ->
      case evt {
        shared.StreamThinking -> {
          // Add a placeholder bot message; until its first chunk it shows
          // only the glowing ember.
          let #(model, bot_id) = push(model, Bot, "")
          #(
            Model(..model, stream_state: Streaming(bot_msg_id: bot_id)),
            scroll_to_bottom(),
          )
        }

        shared.StreamChunk(text) -> {
          case model.stream_state {
            Streaming(bot_msg_id) -> {
              let model = append_to_message(model, bot_msg_id, text)
              #(model, scroll_to_bottom())
            }
            _ -> #(model, effect.none())
          }
        }

        shared.StreamDone(text) -> {
          case model.stream_state {
            Streaming(bot_msg_id) -> {
              // Replace with the final complete text (may include email
              // success suffix from the server).
              let model =
                Model(
                  ..replace_message_text(model, bot_msg_id, text),
                  announcement: text,
                )
              // Still speaking: the reply goes on appearing with the voice.
              case model.speech {
                Speaking(..) -> #(
                  Model(..model, stream_state: Idle),
                  effect.none(),
                )
                Silent -> #(
                  Model(..model, stream_state: Idle),
                  scroll_to_bottom(),
                )
              }
            }
            _ -> {
              let #(model, _) = push(model, Bot, text)
              #(Model(..model, stream_state: Idle), scroll_to_bottom())
            }
          }
        }

        // Speech events are consumed by the voice module (see ffi.mjs).
        shared.StreamVoice(_)
        | shared.StreamSpeech(..)
        | shared.StreamSpeechEnd(_) -> #(model, effect.none())

        shared.StreamError(message) -> {
          let s = i18n.strings(model.language)
          let error_text = error_text(s, message)
          // Heard as it is seen: the label, then the line.
          let model =
            Model(
              ..model,
              speech: Silent,
              announcement: s.error_label <> ": " <> error_text,
            )
          case model.stream_state {
            Streaming(bot_msg_id) -> {
              let has_partial_text =
                list.any(model.history, fn(msg) {
                  msg.id == bot_msg_id && msg.text != ""
                })
              let model = case has_partial_text {
                True -> push_error(model, error_text)
                False -> replace_with_error(model, bot_msg_id, error_text)
              }
              #(Model(..model, stream_state: Idle), scroll_to_bottom())
            }
            _ -> #(
              Model(..push_error(model, error_text), stream_state: Idle),
              scroll_to_bottom(),
            )
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
      speech: Silent,
      generation: model.generation + 1,
      announcement: "",
    )
  let #(with_welcome, _) = push(cleared, Bot, s.welcome_msg)
  // A language switch mid-reply drops the stream, and its voice with it. The
  // new conversation is shown from its top: the page's heading, the welcome.
  #(
    with_welcome,
    effect.batch([stream_abort(), speech_stop(), scroll_to_top()]),
  )
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
      let generation = model.generation + 1
      let effect =
        call_api_stream(
          text,
          history_before_user,
          voice_for(model),
          lang_code(model.language),
          generation,
        )
      #(
        // A new question interrupts the previous reply's voice.
        Model(
          ..with_user,
          input: "",
          stream_state: Thinking,
          speech: Silent,
          generation: generation,
          announcement: "",
        ),
        effect.batch([effect, scroll_to_bottom()]),
      )
    }
  }
}

fn push(model: Model, sender: Sender, text: String) -> #(Model, Int) {
  let id = model.next_id
  let msg = ChatMessage(id: id, sender: sender, text: text, is_error: False)
  #(
    Model(..model, history: list.append(model.history, [msg]), next_id: id + 1),
    id,
  )
}

fn push_error(model: Model, text: String) -> Model {
  let id = model.next_id
  let msg = ChatMessage(id: id, sender: Bot, text: text, is_error: True)
  Model(..model, history: list.append(model.history, [msg]), next_id: id + 1)
}

fn replace_with_error(model: Model, msg_id: Int, text: String) -> Model {
  let history =
    list.map(model.history, fn(m) {
      case m.id == msg_id {
        True -> ChatMessage(..m, text: text, is_error: True)
        False -> m
      }
    })
  Model(..model, history: history)
}

/// What an error says in the UI language. The transport reports `HTTP 429`
/// (rate limited), `Network error` (offline, or the server unreachable) and
/// `Response timed out. Please try again.` (see ffi.mjs); anything else is
/// shown as it came. The view puts the localised "Error" label above it.
fn error_text(s: Strings, message: String) -> String {
  case message {
    "HTTP 429" -> s.error_rate_limited
    "Network error" -> s.error_offline
    "Response timed out. Please try again." -> s.error_timeout
    _ -> message
  }
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

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

/// Who speaks a reply.
pub type Voice {
  /// Nobody: voice is off, or the reply is not in English.
  NoVoice
  /// The server sends audio with the reply.
  ServerVoice
  /// The reply is text-only and the model in the browser speaks it.
  NaturalVoice
}

/// Only English is spoken. The natural voice takes over once it is loaded;
/// while it is not, the server's voice speaks.
pub fn voice_for(model: Model) -> Voice {
  case model.voice_on, model.language, model.natural {
    True, En, NaturalOn -> NaturalVoice
    True, En, _ -> ServerVoice
    _, _, _ -> NoVoice
  }
}

fn natural_load() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    do_natural_load(
      fn(percent) { dispatch(NaturalProgressed(percent)) },
      fn() { dispatch(NaturalLoaded) },
      fn() { dispatch(NaturalBroke) },
    )
  })
}

fn call_api_stream(
  text: String,
  history: List(ChatMessage),
  voice: Voice,
  lang: String,
  generation: Int,
) -> Effect(Msg) {
  let wire_history = wire_history(history)
  // Only the server's voice is asked for in the request; otherwise no voice
  // fields at all, exactly the text-only request.
  let body =
    shared.stream_request_to_json(
      shared.ChatRequest(message: text, history: wire_history),
      shared.VoiceOptions(on: voice == ServerVoice, lang: lang),
    )
    |> json.to_string

  // Synchronous effect: runs inside the send gesture, so audio may start.
  effect.from(fn(dispatch) {
    do_speech_stop()
    case voice {
      NoVoice -> Nil
      _ -> {
        do_unlock_audio()
        do_speech_begin(
          speaking_mark,
          voice == NaturalVoice,
          fn(shown) { dispatch(SpeechRevealed(shown)) },
          fn() { dispatch(SpeechEnded) },
        )
      }
    }
    do_stream_chat(stream_endpoint(), body, fn(json_str) {
      do_speech_feed(json_str)
      dispatch(StreamEventReceived(generation, json_str))
    })
  })
}

/// The history sent with a question: the model's and the user's words only.
pub fn wire_history(history: List(ChatMessage)) -> List(shared.ChatMessage) {
  history
  // Drop the leading assistant welcome message: it is UI-only chrome, and
  // Gemini's `contents` should begin with a user turn rather than a model
  // turn (and we needn't spend tokens echoing our own canned greeting).
  |> list.drop_while(fn(m) { m.sender == Bot })
  // Error lines and empty replies are not the model's words; sent back, they
  // would read as its own turns ("HTTP 429").
  |> list.filter(fn(m) { !m.is_error && string.trim(m.text) != "" })
  |> list.map(fn(m) {
    shared.ChatMessage(role: role_of(m.sender), content: m.text)
  })
  |> shared.cap_history(max_history_messages)
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

fn scroll_to_top() -> Effect(Msg) {
  effect.from(fn(_dispatch) { do_scroll_to_top("#messages-container") })
}

/// Follow a scheme pinned or unpinned in another tab.
fn scheme_watch() -> Effect(Msg) {
  effect.from(fn(_dispatch) { do_scheme_watch() })
}

/// Abort the request in flight, if any; it reports nothing more.
fn stream_abort() -> Effect(Msg) {
  effect.from(fn(_dispatch) { do_stream_abort() })
}

fn speech_stop() -> Effect(Msg) {
  effect.from(fn(_dispatch) { do_speech_stop() })
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

/// The bar across the page; under it one 720px column (`.ix-wrap--read`): the
/// conversation (with the quick prompts at its end), the composer, the footer. The shell is pinned to the viewport
/// and only the conversation scrolls, so the input is always within reach.
pub fn view(model: Model) -> Element(Msg) {
  let s = i18n.strings(model.language)

  html.div([attribute.class("shell")], [
    bar(model, s),
    html.main([attribute.id("chat-area")], [
      messages_container(model, s),
      composer(model, s),
      wisp(),
    ]),
    footer(s),
  ])
}

/// The family bar: the emblem, the wordmark and `ask` at left; at right the
/// sibling sites, the voice toggle, the language switch and the scheme switch.
/// The link labels are the family's own names for its sites, the same in
/// every language.
fn bar(model: Model, s: Strings) -> Element(Msg) {
  html.header([attribute.class("ix-bar")], [
    html.div([attribute.class("ix-wrap ix-bar__in")], [
      // One link: the emblem is decoration beside the wordmark, which names it.
      html.a(
        [attribute.class("ix-bar__brand"), attribute.href("https://arda.tr")],
        [
          html.img([
            attribute.class("ix-emblem"),
            attribute.src("/brand/art/emblem.webp"),
            attribute.alt(""),
            attribute.width(40),
            attribute.height(40),
          ]),
          wordmark.view(),
        ],
      ),
      html.span([attribute.class("ix-bar__site")], [html.text("ask")]),
      html.div([attribute.class("ix-bar__nav ix-bar__nav--end")], [
        html.nav(
          [attribute.class("bar-sites"), attribute.aria_label(s.nav_label)],
          [
            html.a([attribute.href("https://arda.tr")], [html.text("works")]),
            html.a([attribute.href("https://blog.arda.tr")], [
              html.text("blog"),
            ]),
            html.a([attribute.href("https://resume.arda.tr")], [
              html.text("résumé"),
            ]),
          ],
        ),
        // Only English is spoken: the voice controls are shown there only.
        case model.language {
          En ->
            element.fragment([
              voice_toggle(model.voice_on, s),
              case model.voice_on {
                True -> natural_toggle(model.natural)
                False -> element.none()
              },
            ])
          _ -> element.none()
        },
        language_toggle(model.language, s),
        scheme_toggle(s),
      ]),
    ]),
  ])
}

/// A wisp of smoke in the far right margin, on wide screens only (style.css).
/// It is bone lines, so it sits on a soot plate: unseen on the dark page, a
/// plate on bone paper. Decoration: nothing is said about it.
fn wisp() -> Element(Msg) {
  html.div(
    [attribute.class("wisp ix-plate ix-smoke"), attribute.aria_hidden(True)],
    [
      html.img([
        attribute.class("ix-art ix-art--drift"),
        // The film the family's smoke.js plays over the image (gleam.toml).
        attribute.attribute("data-smoke-video", "/brand/art/wisp-smoke.mp4"),
        attribute.src("/brand/art/wisp.webp"),
        attribute.alt(""),
        attribute.width(400),
        attribute.height(840),
        // Not fetched where it is not shown.
        attribute.attribute("loading", "lazy"),
      ]),
    ],
  )
}

/// Light or dark. Both labels are in the markup, each naming the scheme the
/// switch would go to, and brand.css (`.ix-scheme [data-when]`) shows the one
/// that fits the scheme on <html>: the label is right before any script runs
/// and needs no state here. The hidden words complete the accessible name
/// around the visible one (WCAG 2.5.3).
fn scheme_toggle(s: Strings) -> Element(Msg) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("ix-scheme ix-navlink"),
      event.on_click(UserToggledScheme),
    ],
    [
      scheme_option("light", s.scheme_dark, s),
      scheme_option("dark", s.scheme_light, s),
    ],
  )
}

/// `when`: the scheme on screen while this label shows; `target`: the other one.
fn scheme_option(when: String, target: String, s: Strings) -> Element(Msg) {
  html.span([attribute.data("when", when)], [
    hidden_text(s.scheme_before),
    html.text(target),
    hidden_text(s.scheme_after),
  ])
}

/// Text for screen readers only (`.ix-sr` in brand.css).
fn hidden_text(text: String) -> Element(Msg) {
  case text {
    "" -> element.none()
    _ -> html.span([attribute.class("ix-sr")], [html.text(text)])
  }
}

/// Mute / unmute the spoken replies. `aria-pressed` carries the state (the
/// chip fills when it is on), and the label says it in words too. The bar has
/// room for one word; the title says what the voice does.
fn voice_toggle(on: Bool, s: Strings) -> Element(Msg) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("ix-chip voice-toggle"),
      attribute.title(s.voice_label),
      attribute.aria_pressed(case on {
        True -> "true"
        False -> "false"
      }),
      event.on_click(UserToggledVoice),
    ],
    [
      html.text(
        s.voice_short
        <> ": "
        <> case on {
          True -> s.voice_on
          False -> s.voice_off
        },
      ),
    ],
  )
}

/// The natural voice: offered with its size, then the download's progress,
/// then on. Shown in English only, so its words are not in `Strings`.
fn natural_toggle(natural: Natural) -> Element(Msg) {
  // The long label, and the short one a phone's bar has room for.
  let #(label, short, pressed, busy) = case natural {
    NaturalOff -> #("Natural voice · 67 MB", "Natural voice", "false", False)
    NaturalLoading(percent) -> #(
      "Loading voice " <> int.to_string(percent) <> "%",
      "Voice " <> int.to_string(percent) <> "%",
      "false",
      True,
    )
    NaturalOn -> #("Natural voice: On", "Natural: On", "true", False)
    NaturalFailed -> #(
      "Natural voice unavailable · retry",
      "Retry voice",
      "false",
      False,
    )
  }
  html.button(
    [
      attribute.type_("button"),
      attribute.class("ix-chip voice-toggle natural-toggle"),
      attribute.title(
        "A natural English voice that runs in your browser. One 67 MB download, kept in the browser's cache.",
      ),
      attribute.aria_pressed(pressed),
      attribute.aria_busy(busy),
      event.on_click(UserToggledNatural),
    ],
    [
      html.span([attribute.class("label-long")], [html.text(label)]),
      html.span([attribute.class("label-short")], [html.text(short)]),
    ],
  )
}

fn language_toggle(language: Language, s: Strings) -> Element(Msg) {
  html.div(
    [
      attribute.class("language-toggle"),
      attribute.role("group"),
      attribute.aria_label(s.language_label),
    ],
    list.intersperse(
      [
        language_button(En, "EN", s.switch_to_en, language),
        language_button(Jp, "JP", s.switch_to_jp, language),
        language_button(Tr, "TR", s.switch_to_tr, language),
      ],
      html.span([attribute.aria_hidden(True)], [html.text("/")]),
    ),
  )
}

fn language_button(
  lang: Language,
  label: String,
  aria_label: String,
  current: Language,
) -> Element(Msg) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("ix-navlink"),
      // Starts with the visible code, so the name contains it (WCAG 2.5.3).
      attribute.aria_label(label <> ", " <> aria_label),
      attribute.aria_pressed(case lang == current {
        True -> "true"
        False -> "false"
      }),
      event.on_click(UserPickedLanguage(lang)),
    ],
    [html.text(label)],
  )
}

/// What the assistant is doing, in words.
fn status(model: Model, s: Strings) -> String {
  case model.speech, model.stream_state {
    Speaking(shown: n, ..), _ if n > 0 -> s.status_speaking
    Speaking(..), _ -> s.status_thinking
    Silent, Idle -> s.status_ready
    Silent, Thinking -> s.status_thinking
    Silent, Streaming(id) ->
      case list.any(model.history, fn(m) { m.id == id && m.text != "" }) {
        True -> s.status_writing
        False -> s.status_thinking
      }
  }
}

/// The page's one heading, beside the large ember. The theme sets an h1 in
/// blackletter, and this is the only blackletter on the page. It scrolls away
/// with the conversation.
fn intro(s: Strings) -> Element(Msg) {
  html.header([attribute.class("intro")], [
    html.span(
      [attribute.class("ix-mark ix-mark--lg"), attribute.aria_hidden(True)],
      [],
    ),
    html.div([], [
      html.h1([attribute.class("ix-emerge")], [html.text(s.construct_title)]),
      html.p([attribute.class("ix-muted")], [html.text(s.construct_subline)]),
    ]),
  ])
}

fn messages_container(model: Model, s: Strings) -> Element(Msg) {
  let tail = case model.stream_state {
    Thinking -> [view_pending(s)]
    _ -> []
  }
  // The scrolling region: focusable, so it can be scrolled from the keyboard.
  html.div(
    [
      attribute.id("messages-container"),
      attribute.attribute("tabindex", "0"),
      attribute.role("region"),
      attribute.aria_label(s.conversation_label),
    ],
    [
      html.div([attribute.class("ix-wrap ix-wrap--read")], [
        intro(s),
        // The transcript is a log, but it does not announce itself: it
        // changes on every chunk. The finished reply goes to
        // `#reply-announcer` instead.
        html.div(
          [
            attribute.id("messages"),
            attribute.class("ix-thread"),
            attribute.role("log"),
            attribute.aria_live("off"),
          ],
          list.append(
            list.map(model.history, fn(msg) {
              view_message(msg, model.stream_state, model.speech, s)
            }),
            tail,
          ),
        ),
        // After the transcript, and at the foot of the scroller while the
        // conversation is short (style.css): just above the input.
        quick_topics(s),
        html.div(
          [
            attribute.id("reply-announcer"),
            attribute.class("ix-sr"),
            attribute.aria_live("polite"),
            attribute.aria_atomic(True),
          ],
          [html.text(plain_text(model.announcement))],
        ),
      ]),
    ],
  )
}

fn view_message(
  msg: ChatMessage,
  stream_state: StreamState,
  speech: Speech,
  s: Strings,
) -> Element(Msg) {
  // While spoken, a reply shows only as far as the voice has got.
  let shown = case speech {
    Speaking(msg_id: id, shown:) if id == msg.id ->
      reveal_prefix(msg.text, shown)
    _ -> msg.text
  }
  let is_streaming_this = case stream_state, speech {
    Streaming(id), _ if id == msg.id -> True
    _, Speaking(msg_id: id, ..) if id == msg.id -> True
    _, _ -> False
  }
  // Once the voice has started on a reply, the ember follows its loudness
  // instead of pulsing.
  let is_voiced = case speech {
    Speaking(msg_id: id, shown: n) if id == msg.id -> n > 0
    _ -> False
  }
  let text = case shown, is_streaming_this {
    // Waiting for the first chunk, or for the voice to start.
    "", True -> thinking(s)
    "", False -> html.div([attribute.class("txt ix-prose")], [])
    _, _ ->
      element.unsafe_raw_html(
        "",
        "div",
        [attribute.class("txt ix-prose")],
        render_markdown(shown),
      )
  }
  let attributes = fn(class: String) {
    [
      attribute.class(case is_streaming_this {
        True -> class <> " is-streaming"
        False -> class
      }),
      attribute.data("msg-id", int.to_string(msg.id)),
      ..message_lang(msg.text)
    ]
  }
  case msg.sender, msg.is_error {
    // The visitor's words: right-aligned, on the surface colour.
    User, _ ->
      html.div(attributes("ix-msg ix-msg--you msg user"), [
        hidden_text(s.who_you),
        text,
      ])
    // An error is not the assistant's words, so it has no ember. It is told
    // by its label and its written message, not by its colour alone.
    Bot, True ->
      html.div(attributes("ix-msg msg bot is-error"), [
        html.div([attribute.class("ix-msg__body ix-error")], [
          html.p([attribute.class("ix-label")], [html.text(s.error_label)]),
          text,
        ]),
      ])
    Bot, False ->
      html.div(attributes("ix-msg msg bot"), [
        mark(is_streaming_this && !is_voiced),
        html.div([attribute.class("ix-msg__body")], [
          hidden_text(s.who_construct),
          text,
        ]),
      ])
  }
}

/// Sent, but the server has not said `thinking` yet.
fn view_pending(s: Strings) -> Element(Msg) {
  html.div([attribute.class("ix-msg msg bot is-streaming")], [
    mark(True),
    html.div([attribute.class("ix-msg__body")], [
      hidden_text(s.who_construct),
      thinking(s),
    ]),
  ])
}

/// "Thinking…" beside the glowing ember, so the wait is said in words too
/// (the ember does not pulse under reduced motion). Screen readers hear it
/// from the status line instead.
fn thinking(s: Strings) -> Element(Msg) {
  html.p([attribute.class("txt ix-muted"), attribute.aria_hidden(True)], [
    html.text(s.status_thinking),
  ])
}

/// A message in Japanese is marked as such when the page is in another
/// language, so it gets the Japanese face and size (brand.css `:lang(ja)`)
/// and a screen reader's Japanese voice. Told by its kana: kanji alone could
/// be Chinese.
fn message_lang(text: String) -> List(attribute.Attribute(Msg)) {
  let has_kana =
    string.to_utf_codepoints(text)
    |> list.any(fn(codepoint) {
      let n = string.utf_codepoint_to_int(codepoint)
      n >= 0x3040 && n <= 0x30FF
    })
  case has_kana {
    True -> [attribute.lang("ja")]
    False -> []
  }
}

/// The assistant: the ember, and nothing else (brand.css draws `.ix-mark`
/// from `--ix-ember-art`, which style.css sets). `busy` (a reply is awaited or
/// being written) makes it glow.
fn mark(busy: Bool) -> Element(Msg) {
  let attributes = [attribute.class("ix-mark"), attribute.aria_hidden(True)]
  html.span(
    case busy {
      True -> [attribute.data("busy", "true"), ..attributes]
      False -> attributes
    },
    [],
  )
}

/// "Try asking": a label over the quick prompts, which it names as a group.
fn quick_topics(s: Strings) -> Element(Msg) {
  html.div([attribute.id("quick-topics")], [
    html.p([attribute.id("try-asking"), attribute.class("ix-label")], [
      html.text(s.try_asking),
    ]),
    html.div(
      [
        attribute.class("ix-chips"),
        attribute.role("group"),
        attribute.aria_labelledby("try-asking"),
      ],
      [
        topic_button(s.btn_experience, s.prompt_experience),
        topic_button(s.btn_education, s.prompt_education),
        topic_button(s.btn_skills, s.prompt_skills),
        topic_button(s.btn_visa, s.prompt_visa),
        topic_button(s.btn_about_bot, s.prompt_about_bot),
      ],
    ),
  ])
}

fn topic_button(label: String, prompt: String) -> Element(Msg) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("ix-chip"),
      event.on_click(UserPickedPrompt(prompt)),
    ],
    [html.text(label)],
  )
}

/// The question field and its button, then the disclaimer. The status line is
/// for screen readers: on screen the ember and the reply itself show what is
/// happening.
fn composer(model: Model, s: Strings) -> Element(Msg) {
  html.div([attribute.class("composer")], [
    html.div([attribute.class("ix-wrap ix-wrap--read")], [
      html.div([attribute.id("input-wrapper")], [
        html.input([
          attribute.type_("text"),
          attribute.id("user-input"),
          attribute.class("ix-input"),
          attribute.placeholder(s.input_placeholder),
          attribute.aria_label(s.input_placeholder),
          attribute.attribute("autocomplete", "off"),
          // The server rejects longer messages with a 400.
          attribute.attribute(
            "maxlength",
            int.to_string(shared.max_message_chars),
          ),
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
            attribute.class("ix-btn ix-btn--primary"),
            // Contains the visible label (WCAG 2.5.3).
            attribute.aria_label(s.send_label),
            attribute.disabled(model.stream_state != Idle),
            event.on_click(UserClickedSend),
          ],
          [html.text(s.send)],
        ),
      ]),
      html.p([attribute.class("ix-small ix-muted")], [html.text(s.disclaimer)]),
      html.p(
        [
          attribute.class("ix-sr"),
          attribute.role("status"),
          attribute.aria_live("polite"),
        ],
        [html.text(status(model, s))],
      ),
    ]),
  ])
}

/// The arda.tr family, linked from every site's chrome. Link texts are
/// hostnames in every language.
fn footer(s: Strings) -> Element(Msg) {
  html.footer([attribute.class("ix-foot")], [
    html.div([attribute.class("ix-wrap ix-wrap--read ix-foot__in")], [
      html.nav(
        [
          attribute.class("family ix-small ix-muted"),
          attribute.aria_label(s.family_label),
        ],
        list.intersperse(
          [
            family_link("arda.tr"),
            family_link("blog.arda.tr"),
            family_link("resume.arda.tr"),
            family_link("lind.arda.tr"),
          ],
          html.span([attribute.aria_hidden(True)], [html.text(" · ")]),
        ),
      ),
    ]),
  ])
}

fn family_link(host: String) -> Element(Msg) {
  html.a([attribute.href("https://" <> host)], [html.text(host)])
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
// Language persistence (localStorage via FFI)
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

@external(javascript, "./ffi.mjs", "scheme_toggle")
fn do_scheme_toggle() -> Nil

@external(javascript, "./ffi.mjs", "scheme_watch")
fn do_scheme_watch() -> Nil

@external(javascript, "./ffi.mjs", "set_document_lang")
fn do_set_document_lang(lang: String) -> Nil

@external(javascript, "./ffi.mjs", "render_markdown")
fn render_markdown(text: String) -> String

@external(javascript, "./ffi.mjs", "plain_text")
fn plain_text(markdown: String) -> String

@external(javascript, "./ffi.mjs", "scroll_to_bottom")
fn do_scroll_to_bottom(selector: String) -> Nil

@external(javascript, "./ffi.mjs", "scroll_to_top")
fn do_scroll_to_top(selector: String) -> Nil

@external(javascript, "./ffi.mjs", "is_localhost")
fn is_localhost() -> Bool

@external(javascript, "./ffi.mjs", "stream_chat")
fn do_stream_chat(url: String, body: String, on_event: fn(String) -> Nil) -> Nil

@external(javascript, "./ffi.mjs", "abort_stream")
fn do_stream_abort() -> Nil

@external(javascript, "./ffi.mjs", "voice_enabled")
fn do_voice_enabled() -> Bool

@external(javascript, "./ffi.mjs", "set_voice_enabled")
fn do_set_voice_enabled(on: Bool) -> Nil

@external(javascript, "./ffi.mjs", "unlock_audio")
fn do_unlock_audio() -> Nil

@external(javascript, "./ffi.mjs", "natural_wanted")
fn do_natural_wanted() -> Bool

@external(javascript, "./ffi.mjs", "natural_load")
fn do_natural_load(
  on_progress: fn(Int) -> Nil,
  on_ready: fn() -> Nil,
  on_failed: fn() -> Nil,
) -> Nil

@external(javascript, "./ffi.mjs", "natural_drop")
fn do_natural_drop() -> Nil

@external(javascript, "./ffi.mjs", "speech_begin")
fn do_speech_begin(
  mark_selector: String,
  natural: Bool,
  on_reveal: fn(Int) -> Nil,
  on_end: fn() -> Nil,
) -> Nil

@external(javascript, "./ffi.mjs", "speech_feed")
fn do_speech_feed(json: String) -> Nil

@external(javascript, "./ffi.mjs", "speech_stop")
fn do_speech_stop() -> Nil

@external(javascript, "./ffi.mjs", "reveal_prefix")
fn reveal_prefix(text: String, shown: Int) -> String

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
