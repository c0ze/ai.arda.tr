// JavaScript FFI for the Lustre frontend.
//
// Keeps browser-only concerns (localStorage, system theme preference,
// markdown rendering, and DOMPurify sanitisation) out of Gleam.
//
// `marked` and `DOMPurify` are loaded globally from CDN <script> tags in
// index.html. We intentionally fall back to a minimal renderer if either
// library is missing so the app still shows plain text rather than crashing.

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

export function prefers_dark() {
  try {
    return window.matchMedia("(prefers-color-scheme: dark)").matches;
  } catch (_) {
    return false;
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

// Render markdown -> sanitised HTML, mirroring the old script.js pipeline:
//   marked.parse -> DOMPurify.sanitize -> rewrite <a ...> to open in a new tab.
export function render_markdown(text) {
  let html;
  if (typeof window !== "undefined" && typeof window.marked !== "undefined") {
    try {
      html = window.marked.parse(text);
    } catch (_) {
      html = "<p>" + escapeHtml(text) + "</p>";
    }
  } else {
    html = "<p>" + escapeHtml(text) + "</p>";
  }

  if (typeof window !== "undefined" && typeof window.DOMPurify !== "undefined") {
    html = window.DOMPurify.sanitize(html, { ADD_ATTR: ["target"] });
  }

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
  return h === "localhost" || h === "127.0.0.1";
}

export function focus_element(selector) {
  if (typeof document === "undefined") return;
  requestAnimationFrame(() => {
    const el = document.querySelector(selector);
    if (el && typeof el.focus === "function") el.focus();
  });
}
