// JavaScript FFI for the Lustre frontend.
//
// Keeps browser-only concerns (localStorage, the colour scheme, markdown
// rendering, and DOMPurify sanitisation) out of Gleam.
//
// `marked` and `DOMPurify` are loaded globally from vendored <script> tags in
// index.html (pinned copies under public/vendor/). If either is unavailable we
// fall back to escaped plain text — never unsanitised HTML. The family's
// `scheme.js` (public/brand/) is loaded by index.html too, as `window.ardaScheme`.

import { Ok, Error } from "./gleam.mjs";
import { unlockAudio, voiceEnabled, setVoiceEnabled, createSpeaker } from "./voice.mjs";
import { createNaturalSpeaker, dropNatural, loadNatural, naturalLoaded, naturalWanted } from "./natural.mjs";

export function storage_get(key) {
  try {
    const value = window.localStorage.getItem(key);
    return value === null ? new Error(undefined) : new Ok(value);
  } catch (_) {
    return new Error(undefined);
  }
}

export function storage_set(key, value) {
  try {
    window.localStorage.setItem(key, value);
  } catch (_) {
    // Ignore — private mode, quota, etc.
  }
}

// The colour scheme: light or dark, kept by the family's scheme.js (a verbatim
// copy of arda.tr's brand/scheme.js, loaded by index.html). ai.arda.tr is dark
// unless the visitor pins light. The inline script in index.html (see
// frontend/gleam.toml) is scheme.js's own boot snippet for the same key and
// fallback, so the scheme is on <html> before first paint; these only change
// it afterwards. Without scheme.js (it failed to load) the switch does nothing.
const SCHEME_KEY = "theme";
const SCHEME_FALLBACK = "dark";

function scheme() {
  return (typeof window !== "undefined" && window.ardaScheme) || null;
}

// Switch to the scheme that is not on screen. Going back to dark clears the pin.
export function scheme_toggle() {
  scheme()?.toggleScheme(SCHEME_KEY, SCHEME_FALLBACK);
}

// Follow a pin set or cleared in another tab.
export function scheme_watch() {
  scheme()?.watchScheme(SCHEME_KEY, SCHEME_FALLBACK);
}

// Keep <html lang="..."> in sync with the selected UI locale so screen
// readers and translation tools pick the right language.
export function set_document_lang(lang) {
  if (typeof document !== "undefined" && document.documentElement) {
    document.documentElement.setAttribute("lang", lang);
  }
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (ch) => {
    switch (ch) {
      case "&": return "&amp;";
      case "<": return "&lt;";
      case ">": return "&gt;";
      case '"': return "&quot;";
      case "'": return "&#039;";
      default: return ch;
    }
  });
}

// Only what markdown renders to is allowed. A deny list cannot keep up: an
// image beacon also fits in <svg><image>, <video poster>, <audio>, <picture>
// or <table background>, and a full-page overlay in <div style>. Attributes:
// links (href, title), ordered-list starts and table alignment, exactly what
// marked emits. Not `class` (a reply could borrow the page's own classes; the
// code block's language class styles nothing), nor data-* / aria-*.
const SANITIZE = {
  ALLOWED_TAGS: [
    "p", "br", "strong", "b", "em", "i", "del", "s", "code", "pre", "blockquote",
    "ul", "ol", "li", "a", "h1", "h2", "h3", "h4", "h5", "h6", "hr",
    "table", "thead", "tbody", "tr", "th", "td",
  ],
  ALLOWED_ATTR: ["href", "title", "start", "align"],
  ALLOW_DATA_ATTR: false,
  ALLOW_ARIA_ATTR: false,
};

// Links in replies open in a new tab. Set on the sanitised DOM nodes by a
// DOMPurify hook, registered once per DOMPurify instance.
let hookedPurify = null;
function purifier() {
  const purify = window.DOMPurify;
  if (purify !== hookedPurify) {
    purify.addHook("afterSanitizeAttributes", (node) => {
      if (node.tagName === "A" && node.hasAttribute("href")) {
        node.setAttribute("target", "_blank");
        node.setAttribute("rel", "noopener noreferrer");
      }
    });
    hookedPurify = purify;
  }
  return purify;
}

// Render markdown -> sanitised HTML:
//   marked.parse -> DOMPurify.sanitize with the SANITIZE allowlist (links get
//   target/rel in a hook).
// DOMPurify is REQUIRED. If it (or marked) is missing we fall back to escaped
// plain text and never return raw, unsanitised HTML (fail closed).
export function render_markdown(text) {
  // Without DOMPurify we cannot guarantee the HTML is safe, so escape and bail
  // out rather than injecting unsanitised markup into the page.
  if (typeof window === "undefined" || typeof window.DOMPurify === "undefined") {
    return "<p>" + escapeHtml(text) + "</p>";
  }

  let html;
  if (typeof window.marked !== "undefined") {
    try {
      html = window.marked.parse(text);
    } catch (_) {
      html = "<p>" + escapeHtml(text) + "</p>";
    }
  } else {
    html = "<p>" + escapeHtml(text) + "</p>";
  }

  return purifier().sanitize(html, SANITIZE);
}

// A reply as a screen reader should hear it: the rendered markdown's text,
// without the ** and []() markup. Outside a browser the text is returned as is.
export function plain_text(markdown) {
  if (!markdown || typeof document === "undefined") return markdown;
  const tmp = document.createElement("div");
  tmp.innerHTML = render_markdown(markdown); // sanitised; detached, never shown
  return tmp.textContent.replace(/\s+/g, " ").trim();
}

// Defer DOM mutations by a tick so Lustre has finished rendering the node
// before we read its layout.
export function scroll_to_bottom(selector) {
  if (typeof document === "undefined") return;
  // Double rAF: the first frame lets Lustre commit its DOM patch (e.g. the
  // freshly-sent message); the second runs after that paint, so scrollHeight
  // is final. A single rAF can read a stale height on the send path, leaving
  // the new message below the fold until the agent's reply re-scrolls.
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      const el = document.querySelector(selector);
      if (el) el.scrollTop = el.scrollHeight;
    });
  });
}

// A fresh conversation starts at its top, where the page's heading is: on a
// small phone the heading, the welcome and the quick prompts do not all fit.
export function scroll_to_top(selector) {
  if (typeof document === "undefined") return;
  requestAnimationFrame(() => {
    const el = document.querySelector(selector);
    if (el) el.scrollTop = 0;
  });
}

export function is_localhost() {
  if (typeof window === "undefined" || !window.location) return false;
  const h = window.location.hostname;
  return h === "localhost" || h === "127.0.0.1" || h === "0.0.0.0";
}

// The request in flight, if any: `{ abort }`. Only one at a time.
let active = null;

// Abort the request in flight (a reset or a new question). It reports nothing
// more: no events, not even an error.
export function abort_stream() {
  const a = active;
  active = null;
  if (a) a.abort();
}

// Stream a POST request to the SSE endpoint. Calls `on_event` for each
// parsed SSE event object. The callback receives a JSON string. Starting a
// request aborts the previous one.
export function stream_chat(url, body_json, on_event) {
  abort_stream();
  let settled = false;
  let reader;
  const controller = new AbortController();
  const handle = {
    abort() {
      settled = true;
      clearTimeout(timer);
      if (reader) reader.cancel().catch(() => {});
      controller.abort();
    },
  };
  active = handle;
  const onDeadline = () => {
    fail("Response timed out. Please try again.");
    controller.abort();
  };
  let timer = setTimeout(onDeadline, 45000);

  function emit(event) {
    if (settled) return;
    if (event.type === "done" || event.type === "error") {
      settled = true;
      if (active === handle) active = null;
      clearTimeout(timer);
      if (reader) reader.cancel().catch(() => {});
    }
    on_event(JSON.stringify(event));
  }
  function fail(message) {
    emit({ type: "error", message });
  }

  fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: body_json,
    signal: controller.signal,
  })
    .then(async (resp) => {
      if (settled) {
        if (resp.body) await resp.body.cancel();
        return;
      }
      if (!resp.ok || !resp.body) {
        if (resp.body) resp.body.cancel().catch(() => {});
        fail(resp.ok ? "Empty response body" : "HTTP " + resp.status);
        return;
      }
      reader = resp.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      while (!settled) {
        const { done, value } = await reader.read();
        if (settled) return;
        if (!done && value.byteLength > 0) {
          clearTimeout(timer);
          timer = setTimeout(onDeadline, 45000);
        }
        buffer += done ? decoder.decode() : decoder.decode(value, { stream: true });
        // Keep incomplete frames buffered across reads, including split CRLFs.
        const parts = buffer.split(/\r?\n\r?\n/);
        buffer = parts.pop() || "";
        for (const part of parts) {
          const data = part.split(/\r?\n/)
            .filter((line) => line.startsWith("data:"))
            .map((line) => line.slice(5).replace(/^ /, ""))
            .join("\n");
          let event;
          try { event = JSON.parse(data); } catch (_) { continue; }
          // Match shared.stream_event_decoder before treating an event as final.
          if (!event || typeof event !== "object") continue;
          if (event.type === "thinking" ||
              ((event.type === "chunk" || event.type === "done") && typeof event.text === "string") ||
              (event.type === "error" && typeof event.message === "string") ||
              // Voice replies (only sent when the request asked for voice).
              (event.type === "voice" && typeof event.on === "boolean") ||
              (event.type === "speech" && Number.isInteger(event.seq) &&
                Number.isInteger(event.start) && Number.isInteger(event.end)) ||
              (event.type === "speech_end" && Number.isInteger(event.upto))) {
            emit(event);
          }
          if (settled) return;
        }
        if (done) {
          fail("Response ended before completion. Please try again.");
          return;
        }
      }
    })
    // fetch rejects with a TypeError when the network or the server is
    // unreachable; the app shows that as its localised "offline" line.
    .catch((err) => { fail(err instanceof TypeError ? "Network error" : String(err)); });
}

// ---------------------------------------------------------------------------
// Voice: the assistant reads its English replies aloud through voice.mjs (a
// verbatim copy of design-previews/onebit/voice.js; do not fork). One speaker
// per reply; it gates how much of the reply is visible so the text appears as
// it is spoken, and its loudness is shown by the reply's ember (set_mark_level).
// ---------------------------------------------------------------------------

export function voice_enabled() {
  return voiceEnabled();
}

export function set_voice_enabled(on) {
  setVoiceEnabled(on);
}

// Must run inside the user's send gesture, or the browser keeps audio muted.
export function unlock_audio() {
  unlockAudio();
}

let speaker = null;

// The element that carries the voice's loudness, if any.
let leveled = null;

// Show the voice's loudness (0 to 1) on the element matched by `selector`: the
// ember of the reply being spoken. It is set as the custom property
// `--ix-level`; brand.css (`.ix-mark`) makes the ember glow with it. Silence
// removes the property, and so does a reply that is no longer the one
// speaking, so no ember stays lit.
export function set_mark_level(selector, level) {
  if (typeof document === "undefined") return;
  const quiet = !(level > 0);
  const el = quiet ? null : document.querySelector(selector);
  if (leveled && leveled !== el) leveled.style.removeProperty("--ix-level");
  leveled = el;
  if (el) el.style.setProperty("--ix-level", Math.min(1, level).toFixed(2));
}

// The natural English voice (natural.mjs): Phonon, running in the browser. The
// visitor opts in; the model is downloaded once and kept in the browser's cache.
export function natural_wanted() {
  return naturalWanted();
}

// `on_progress(0..100)` follows the download; then `on_ready()` or `on_failed()`.
export function natural_load(on_progress, on_ready, on_failed) {
  loadNatural(on_progress).then(() => on_ready(), () => on_failed());
}

export function natural_drop() {
  dropNatural();
}

// `on_reveal(n)`: show the first n UTF-16 units of the raw reply; -1 = all.
// Callbacks from a speaker that has since been replaced are dropped.
// `natural`: the reply is text-only and the browser's own model speaks it;
// otherwise the audio comes with the reply, from the server.
export function speech_begin(mark_selector, natural, on_reveal, on_end) {
  speech_stop();
  const create = natural ? (callbacks) => createNaturalSpeaker({ tts: naturalLoaded(), ...callbacks }) : createSpeaker;
  const s = create({
    onReveal: (n) => { if (speaker === s) on_reveal(n === Infinity ? -1 : n); },
    // Each animation frame while speaking, and 0 when the voice stops.
    onLevel: (level) => { if (speaker === s) set_mark_level(mark_selector, level); },
    onEnd: () => { if (speaker === s) { speaker = null; on_end(); } },
  });
  speaker = s;
}

export function speech_feed(json) {
  if (!speaker) return;
  try { speaker.handle(JSON.parse(json)); } catch (_) {}
}

export function speech_stop() {
  const s = speaker;
  speaker = null;
  if (s) s.stop();
  // The stopped speaker's own "level 0" is dropped above, so clear it here.
  set_mark_level("", 0);
}

// The part of a reply the voice has reached, safe to render as markdown:
// never half a surrogate pair, a half-typed link shows as its label, and an
// open ** or ` is closed so the word being spoken is not framed by markers (or dropped, if nothing
// follows it yet).
export function reveal_prefix(text, n) {
  if (n < 0 || n >= text.length) return text;
  let s = text.slice(0, n);
  const last = s.charCodeAt(s.length - 1);
  if (last >= 0xd800 && last <= 0xdbff) s = s.slice(0, -1);
  if (s.endsWith("*") && text.charAt(s.length) === "*") s = s.slice(0, -1); // half a ** marker
  s = s.replace(/\[([^\]\n]*)(\]\([^)\n]*)?$/, "$1");
  // an opener with nothing after it yet (the voice rests right before a bold word) is dropped, not
  // closed: "**" + "**" is not bold, so closing it would flash a literal "****"
  if ((s.match(/\*\*/g) || []).length % 2) s = s.endsWith("**") ? s.slice(0, -2) : s + "**";
  if ((s.match(/`/g) || []).length % 2) s = s.endsWith("`") ? s.slice(0, -1) : s + "`";
  return s;
}
