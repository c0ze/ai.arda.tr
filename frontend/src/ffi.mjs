// JavaScript FFI for the Lustre frontend.
//
// Keeps browser-only concerns (localStorage, system theme preference,
// markdown rendering, and DOMPurify sanitisation) out of Gleam.
//
// `marked` and `DOMPurify` are loaded globally from vendored <script> tags in
// index.html (pinned copies under public/vendor/). If either is unavailable we
// fall back to escaped plain text — never unsanitised HTML.

import { Ok, Error } from "./gleam.mjs";

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
              (event.type === "error" && typeof event.message === "string")) {
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
