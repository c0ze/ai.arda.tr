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
  requestAnimationFrame(() => {
    const el = document.querySelector(selector);
    if (el) el.scrollTop = el.scrollHeight;
  });
}

export function is_localhost() {
  if (typeof window === "undefined" || !window.location) return false;
  const h = window.location.hostname;
  return h === "localhost" || h === "127.0.0.1" || h === "0.0.0.0";
}

export function focus_element(selector) {
  if (typeof document === "undefined") return;
  requestAnimationFrame(() => {
    const el = document.querySelector(selector);
    if (el && typeof el.focus === "function") el.focus();
  });
}

// Stream a POST request to the SSE endpoint. Calls `on_event` for each
// parsed SSE event object. The callback receives a JSON string.
export function stream_chat(url, body_json, on_event) {
  fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: body_json,
  })
    .then((resp) => {
      if (!resp.ok) {
        on_event(JSON.stringify({ type: "error", message: "HTTP " + resp.status }));
        return;
      }
      const reader = resp.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      function pump() {
        return reader.read().then(({ done, value }) => {
          if (done) {
            // Process any remaining buffered data
            if (buffer.trim()) processBuffer();
            return;
          }
          buffer += decoder.decode(value, { stream: true });
          processBuffer();
          return pump();
        });
      }

      function processBuffer() {
        // SSE events are separated by double newlines
        const parts = buffer.split("\n\n");
        // Keep the last (possibly incomplete) part in the buffer
        buffer = parts.pop() || "";
        for (const part of parts) {
          for (const line of part.split("\n")) {
            if (line.startsWith("data: ")) {
              const data = line.slice(6);
              try {
                // Validate it's JSON before forwarding
                JSON.parse(data);
                on_event(data);
              } catch (_) {
                // Skip malformed data lines
              }
            }
          }
        }
      }

      return pump();
    })
    .catch((err) => {
      on_event(JSON.stringify({ type: "error", message: String(err) }));
    });
}
