// JavaScript FFI for the Lustre frontend.
//
// Keeps browser-only concerns (localStorage, system theme preference,
// markdown rendering, and DOMPurify sanitisation) out of Gleam.
//
// `marked` and `DOMPurify` are loaded globally from vendored <script> tags in
// index.html (pinned copies under public/vendor/). If either is unavailable we
// fall back to escaped plain text — never unsanitised HTML.

import { Ok, Error } from "./gleam.mjs";
import { orb, crackle, reducedMotion } from "./onebit.mjs";
import { unlockAudio, voiceEnabled, setVoiceEnabled, createSpeaker } from "./voice.mjs";

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

export function set_body_theme(theme) {
  if (typeof document !== "undefined" && document.body) {
    document.body.setAttribute("data-theme", theme);
  }
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

// Render markdown -> sanitised HTML:
//   marked.parse -> DOMPurify.sanitize -> rewrite <a ...> to open in a new tab.
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

  html = window.DOMPurify.sanitize(html, { ADD_ATTR: ["target"] });
  return html.replace(/<a href/g, '<a target="_blank" rel="noopener noreferrer" href');
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

export function is_localhost() {
  if (typeof window === "undefined" || !window.location) return false;
  const h = window.location.hostname;
  return h === "localhost" || h === "127.0.0.1" || h === "0.0.0.0";
}

// Stream a POST request to the SSE endpoint. Calls `on_event` for each
// parsed SSE event object. The callback receives a JSON string.
export function stream_chat(url, body_json, on_event) {
  let settled = false;
  let reader;
  const controller = new AbortController();
  const onDeadline = () => {
    fail("Response timed out. Please try again.");
    controller.abort();
  };
  let timer = setTimeout(onDeadline, 45000);

  function emit(event) {
    if (settled) return;
    if (event.type === "done" || event.type === "error") {
      settled = true;
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
    .catch((err) => { fail(String(err)); });
}

// ---------------------------------------------------------------------------
// The construct: a 1-bit orb that revolves constantly and sizzles on every
// streamed chunk, plus a crackling block cursor that trails the streaming
// reply. Both canvases are created here, inside elements whose Lustre vnodes
// have no children (the orb host) or whose inner HTML Lustre only replaces
// when the markdown changes (the reply). Lustre never diffs these canvases,
// so re-renders do not recreate them.
// ---------------------------------------------------------------------------

let construct = null; // { canvas, orb }

function ensureOrb(selector) {
  if (typeof document === "undefined") return null;
  if (construct && construct.canvas.isConnected) return construct;
  const host = document.querySelector(selector);
  if (!host) return null;
  if (construct) construct.orb.destroy();
  const canvas = document.createElement("canvas");
  canvas.className = "px";
  host.replaceChildren(canvas);
  construct = { canvas, orb: orb(canvas, { size: 44, speed: 0.6 }) };
  return construct;
}

export function mount_orb(selector) {
  ensureOrb(selector);
}

// One crackle of the orb, sized like the reference sketch. Skipped under
// prefers-reduced-motion: there the orb draws still frames, and the last
// sizzle would otherwise stay frozen on it after the reply ends.
export function sizzle_orb(selector) {
  const c = ensureOrb(selector);
  if (c && !reducedMotion()) c.orb.sizzle(0.5 + Math.random() * 0.5);
}

// While the model is thinking no chunks arrive, so keep the orb simmering
// until the first chunk (or the end) turns it off.
let simmer = 0;
export function simmer_orb(selector, on) {
  clearInterval(simmer);
  simmer = 0;
  if (!on || reducedMotion()) return;
  const c = ensureOrb(selector);
  if (c) simmer = setInterval(() => c.orb.sizzle(0.3), 320);
}

let cursor = null; // { canvas, anim }

// Descend into the last block of the rendered reply so the cursor sits right
// after the final word rather than on a line of its own.
const TRAIL = /^(P|UL|OL|LI|BLOCKQUOTE|H[1-6])$/;
function trailTarget(el, skip) {
  for (;;) {
    let last = el.lastChild;
    while (last && (last === skip || (last.nodeType === 3 && !last.textContent.trim()))) {
      last = last.previousSibling;
    }
    if (last && last.nodeType === 1 && TRAIL.test(last.tagName)) el = last;
    else return el;
  }
}

// Put the crackle cursor at the end of the element matched by `selector`.
// Call it after every render of the streaming reply (Lustre replaces the
// reply's inner HTML when the markdown changes, which detaches the cursor).
export function trail_cursor(selector) {
  if (typeof document === "undefined") return;
  const host = document.querySelector(selector);
  if (!host) return stop_cursor();
  if (!cursor) {
    const canvas = document.createElement("canvas");
    canvas.className = "px cursor";
    canvas.setAttribute("aria-hidden", "true");
    cursor = { canvas, anim: null };
  }
  const target = trailTarget(host, cursor.canvas);
  if (cursor.canvas.parentNode !== target || target.lastChild !== cursor.canvas) {
    target.appendChild(cursor.canvas);
  }
  if (!cursor.anim) cursor.anim = crackle(cursor.canvas);
}

export function stop_cursor() {
  if (!cursor) return;
  cursor.anim?.destroy();
  cursor.canvas.remove();
  cursor = null;
}

// ---------------------------------------------------------------------------
// Voice: the construct reads its replies aloud through voice.mjs (a verbatim
// copy of design-previews/onebit/voice.js; do not fork). One speaker per
// reply; it gates how much of the reply is visible so the text appears as it
// is spoken, and its loudness makes the orb sizzle.
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
let lastLevelAt = 0;

// `on_reveal(n)`: show the first n UTF-16 units of the raw reply; -1 = all.
// Callbacks from a speaker that has since been replaced are dropped.
export function speech_begin(orb_selector, on_reveal, on_end) {
  speech_stop();
  const s = createSpeaker({
    onReveal: (n) => { if (speaker === s) on_reveal(n === Infinity ? -1 : n); },
    onLevel: (level) => {
      // Sizzle at ~9 Hz scaled by loudness: the orb's heat then tracks the voice.
      const now = performance.now();
      if (level < 0.03 || now - lastLevelAt < 110 || reducedMotion()) return;
      lastLevelAt = now;
      const c = ensureOrb(orb_selector);
      if (c) c.orb.sizzle(level * 0.6);
    },
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
