//// Recent blog posts, fetched from the RSS feed and injected into the system
//// prompt so the bot can answer "what is Arda working on recently?".
////
//// Flow: a background process fetches `blog.arda.tr/rss.xml`, parses the newest
//// few posts, and stores a small markdown snippet in a single-slot in-memory
//// cache (`blog_cache_ffi`), refreshing every few hours. The cache is
//// overwritten each time, so it never grows. Request handlers read the current
//// snippet via `current/0` and append it to the system instruction.
////
//// Degrades gracefully: a fetch/parse failure keeps the last good snippet (or
//// "" if we never succeeded), so a feed outage never breaks chat. State is
//// in-memory only — Cloud Run is ephemeral, so each instance re-populates it.

import gleam/erlang/process
import gleam/http/request
import gleam/httpc
import gleam/list
import gleam/result
import gleam/string
import logging

pub const default_feed_url = "https://blog.arda.tr/rss.xml"

const max_posts = 3

// Kept short because the initial fetch is synchronous at startup — we don't
// want a slow/unreachable feed to hold up boot for long.
const fetch_timeout_ms = 5000

const summary_max_chars = 280

pub type Post {
  Post(title: String, date: String, link: String, summary: String)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// The current cached snippet (markdown). Empty string until first populated.
/// Cheap concurrent ETS read — safe to call once per request.
pub fn current() -> String {
  cache_get()
}

/// Initialise the cache, do a synchronous initial fetch, then start the
/// background refresher. Call once at startup.
///
/// The initial fetch is synchronous (bounded by `fetch_timeout_ms`) so the very
/// first request — even the one that triggers a Cloud Run cold start — already
/// has the posts, rather than racing the background fetch. On failure the cache
/// stays empty and the loop retries; boot continues regardless.
pub fn start(feed_url: String, interval_ms: Int) -> Nil {
  cache_init()
  refresh_once(feed_url)
  spawn_loop(fn() { loop(feed_url, interval_ms) })
}

fn loop(feed_url: String, interval_ms: Int) -> Nil {
  // `start` did the initial fetch; from here just refresh once per interval.
  process.sleep(interval_ms)
  refresh_once(feed_url)
  loop(feed_url, interval_ms)
}

/// Fetch + parse + format, storing the snippet only when we actually got posts
/// — a transient failure keeps the previously cached copy. The outcome is
/// logged so feed problems are visible in Cloud Run logs.
fn refresh_once(feed_url: String) -> Nil {
  case fetch_snippet(feed_url) {
    "" ->
      logging.log(
        logging.Warning,
        "blog: no recent posts fetched (keeping any cached copy): " <> feed_url,
      )
    snippet -> {
      cache_put(snippet)
      logging.log(
        logging.Info,
        "blog: refreshed recent posts from " <> feed_url,
      )
    }
  }
}

fn fetch_snippet(feed_url: String) -> String {
  case fetch_feed(feed_url) {
    Error(_) -> ""
    Ok(xml) -> format_snippet(parse_items(xml))
  }
}

fn fetch_feed(feed_url: String) -> Result(String, Nil) {
  use req <- result.try(request.to(feed_url) |> result.replace_error(Nil))
  use resp <- result.try(
    httpc.configure()
    |> httpc.follow_redirects(True)
    |> httpc.timeout(fetch_timeout_ms)
    |> httpc.dispatch(req)
    |> result.replace_error(Nil),
  )
  case resp.status {
    200 -> Ok(resp.body)
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Parsing + formatting (pure, unit-tested)
// ---------------------------------------------------------------------------

/// Parse the newest `max_posts` items out of an RSS document. String-based
/// extraction tuned to our own @astrojs/rss feed; unknown/malformed items are
/// skipped rather than failing the whole parse.
pub fn parse_items(xml: String) -> List(Post) {
  xml
  |> string.split("<item>")
  |> list.drop(1)
  // first chunk is the channel header
  |> list.filter_map(parse_item)
  |> list.take(max_posts)
}

fn parse_item(chunk: String) -> Result(Post, Nil) {
  // Confine to this item's body in case items are concatenated.
  let body = case string.split_once(chunk, "</item>") {
    Ok(#(inner, _)) -> inner
    Error(_) -> chunk
  }
  use title <- result.try(between(body, "<title>", "</title>"))
  let link = between(body, "<link>", "</link>") |> result.unwrap("")
  let date =
    between(body, "<pubDate>", "</pubDate>")
    |> result.unwrap("")
    |> tidy_date
  let summary =
    between(body, "<description>", "</description>")
    |> result.unwrap("")
    |> clean_html
    |> truncate(summary_max_chars)
  Ok(Post(title: unescape(title), date:, link:, summary:))
}

/// Render posts as a compact markdown block for the system prompt. Empty input
/// yields "" so the section is omitted entirely when there's nothing to show.
pub fn format_snippet(posts: List(Post)) -> String {
  case posts {
    [] -> ""
    _ -> {
      let header =
        "## Recent blog posts (newest first)\nThese are Arda's most recent blog posts (from blog.arda.tr). Use them to answer questions about what he is working on, writing about, or up to recently, and summarise them naturally when asked.\n\n"
      let lines =
        posts
        |> list.map(fn(p) {
          "- **"
          <> p.title
          <> "** ("
          <> p.date
          <> ") — "
          <> p.summary
          <> " ("
          <> p.link
          <> ")"
        })
        |> string.join("\n")
      header <> lines <> "\n"
    }
  }
}

// ---------------------------------------------------------------------------
// Small string helpers
// ---------------------------------------------------------------------------

fn between(s: String, open: String, close: String) -> Result(String, Nil) {
  use #(_, rest) <- result.try(string.split_once(s, open))
  use #(inner, _) <- result.try(string.split_once(rest, close))
  Ok(inner)
}

/// "Thu, 11 Jun 2026 00:00:00 GMT" -> "11 Jun 2026".
fn tidy_date(raw: String) -> String {
  let without_weekday = case string.split_once(raw, ", ") {
    Ok(#(_, rest)) -> rest
    Error(_) -> raw
  }
  without_weekday
  |> string.split(" ")
  |> list.take(3)
  |> string.join(" ")
}

/// Unescape XML entities, strip HTML tags, and collapse whitespace — turns an
/// RSS `description` (escaped `<img>` + `<p>excerpt</p>`) into plain text.
fn clean_html(raw: String) -> String {
  raw
  |> unescape
  |> strip_tags
  |> collapse_whitespace
  |> string.trim
}

fn unescape(s: String) -> String {
  // &amp; must be last so "&amp;lt;" doesn't become "<".
  s
  |> string.replace("&lt;", "<")
  |> string.replace("&gt;", ">")
  |> string.replace("&quot;", "\"")
  |> string.replace("&#39;", "'")
  |> string.replace("&#x27;", "'")
  |> string.replace("&apos;", "'")
  |> string.replace("&amp;", "&")
}

fn strip_tags(s: String) -> String {
  case string.split(s, "<") {
    [first, ..rest] -> {
      let without_tags =
        rest
        |> list.map(fn(part) {
          case string.split_once(part, ">") {
            Ok(#(_tag, after)) -> after
            Error(_) -> part
          }
        })
        |> string.concat
      first <> without_tags
    }
    [] -> s
  }
}

fn collapse_whitespace(s: String) -> String {
  s
  |> string.replace("\n", " ")
  |> string.replace("\r", " ")
  |> string.replace("\t", " ")
  |> string.split(" ")
  |> list.filter(fn(part) { part != "" })
  |> string.join(" ")
}

fn truncate(s: String, max: Int) -> String {
  case string.length(s) > max {
    True -> string.slice(s, 0, max) |> string.trim_end <> "…"
    False -> s
  }
}

// ---------------------------------------------------------------------------
// FFI: single-slot ETS cache + unlinked spawn (blog_cache_ffi.erl)
// ---------------------------------------------------------------------------

@external(erlang, "blog_cache_ffi", "init")
fn cache_init() -> Nil

@external(erlang, "blog_cache_ffi", "put")
fn cache_put(snippet: String) -> Nil

@external(erlang, "blog_cache_ffi", "get")
fn cache_get() -> String

@external(erlang, "blog_cache_ffi", "spawn_loop")
fn spawn_loop(run: fn() -> Nil) -> Nil
