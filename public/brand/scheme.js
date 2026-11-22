/*
  arda.tr family: the colour scheme switch.
  Source of truth: brand/scheme.js in the arda.tr repository. The sibling sites
  carry a verbatim copy.

  A page follows the system scheme unless the visitor pins one. A pinned scheme is
  stored as "light" or "dark" under the site's localStorage key, and mirrored on
    <html data-theme>             what the Astryx `arda` theme reads
    <meta name="color-scheme">    what the browser's own UI reads
  No stored value means "follow the system" (or the site's default: ai.arda.tr is
  dark unless pinned).

  Before first paint, each page inlines `bootSnippet(key, fallback)` in <head>,
  right after <meta name="color-scheme" content="light dark">.
*/

// Ids stored by the family's earlier systems (One Bit Forest and before), by role.
const LEGACY_LIGHT = ["xerox", "xerox-hc", "stock", "stock-hc", "alucard", "paper"];
const LEGACY_DARK = [
  "night", "night-hc", "microfiche", "microfiche-hc", "dracula", "dracula-pro",
  "blade", "buffy", "lincoln", "morbius", "van-helsing", "carbon",
];

/** "light" | "dark" | null for a stored value, old ids included. */
export function normalize(stored) {
  if (stored === "light" || stored === "dark") return stored;
  if (LEGACY_LIGHT.includes(stored)) return "light";
  if (LEGACY_DARK.includes(stored)) return "dark";
  return null;
}

/** The pinned scheme, or null. Never throws: storage can be blocked. */
export function readScheme(key) {
  try {
    return normalize(localStorage.getItem(key));
  } catch {
    return null;
  }
}

/** Fired on `document` whenever the scheme is applied; `detail` is "light" | "dark" | null. */
export const SCHEME_EVENT = "ix:scheme";

/**
 * Mirrors a scheme ("light" | "dark" | null) onto <html> and the color-scheme
 * meta, and announces it. A page whose framework owns <html data-theme> (Astryx's
 * <Theme mode>) listens for SCHEME_EVENT and passes the scheme on as its mode.
 */
export function applyScheme(scheme) {
  const root = document.documentElement;
  if (scheme) root.setAttribute("data-theme", scheme);
  else root.removeAttribute("data-theme");
  const meta = document.querySelector('meta[name="color-scheme"]');
  if (meta) meta.setAttribute("content", scheme ?? "light dark");
  document.dispatchEvent(new CustomEvent(SCHEME_EVENT, { detail: scheme ?? null }));
}

const systemScheme = () => (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");

/** The scheme on screen now: the pinned one, else the site's default, else the system's. */
export function renderedScheme(key, fallback = null) {
  return readScheme(key) ?? fallback ?? systemScheme();
}

/**
 * Switches to the opposite of what is on screen. Going back to what the page
 * would show anyway (the system's scheme, or the site's default) clears the pin,
 * so the page follows the system again. Returns the scheme now on screen.
 */
export function toggleScheme(key, fallback = null) {
  const target = renderedScheme(key, fallback) === "dark" ? "light" : "dark";
  const unpinned = fallback ?? systemScheme();
  const pin = target === unpinned ? null : target;
  try {
    if (pin) localStorage.setItem(key, pin);
    else localStorage.removeItem(key);
  } catch {
    /* not persisted; still applied below */
  }
  applyScheme(pin ?? fallback);
  return target;
}

/** Keeps this tab in step when the pin changes in another tab. Returns an unsubscribe. */
export function watchScheme(key, fallback = null) {
  const onStorage = (event) => {
    if (event.key === key || event.key === null) applyScheme(readScheme(key) ?? fallback);
  };
  window.addEventListener("storage", onStorage);
  return () => window.removeEventListener("storage", onStorage);
}

/**
 * The inline script for <head>: applies the stored (or default) scheme before
 * first paint and rewrites an old stored id to its role. Plain ES5, no imports.
 */
export function bootSnippet(key, fallback = null) {
  const k = JSON.stringify(key);
  const f = JSON.stringify(fallback);
  const light = JSON.stringify(LEGACY_LIGHT);
  const dark = JSON.stringify(LEGACY_DARK);
  return (
    `(function(){var s=null;try{s=localStorage.getItem(${k});` +
    `if(s!=="light"&&s!=="dark"){var n=${light}.indexOf(s)>=0?"light":${dark}.indexOf(s)>=0?"dark":null;` +
    `if(s!==null){if(n)localStorage.setItem(${k},n);else localStorage.removeItem(${k});}s=n;}}catch(e){}` +
    `s=s||${f};if(s){document.documentElement.setAttribute("data-theme",s);` +
    `var m=document.querySelector('meta[name="color-scheme"]');if(m)m.setAttribute("content",s);}})();`
  );
}
