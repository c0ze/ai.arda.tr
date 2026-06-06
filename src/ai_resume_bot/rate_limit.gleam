//// Per-client fixed-window rate limiting for the public chat endpoints.
////
//// Both `/api/chat` and `/api/chat/stream` are unauthenticated and call the
//// paid Gemini API (and can trigger contact emails), so they need an abuse /
//// cost guard. The counter lives in an ETS table (atomic `update_counter`,
//// safe under Mist's per-request concurrency) behind `rate_limit_ffi.erl`;
//// this module owns the pure client-key extraction and the small wrapper API.

import gleam/int
import gleam/list
import gleam/string

/// Rate-limit policy: at most `max_requests` per `window_ms` per client key.
pub type Config {
  Config(max_requests: Int, window_ms: Int)
}

/// Build a Config from optional env values (strings), falling back to the
/// defaults when unset or unparseable. Defaults: 30 requests / 60s.
pub fn config_from_env(
  max_requests: Result(String, Nil),
  window_seconds: Result(String, Nil),
) -> Config {
  let max = parse_positive(max_requests, 30)
  let window_s = parse_positive(window_seconds, 60)
  Config(max_requests: max, window_ms: window_s * 1000)
}

fn parse_positive(raw: Result(String, Nil), fallback: Int) -> Int {
  case raw {
    Ok(value) ->
      case int.parse(string.trim(value)) {
        Ok(n) if n > 0 -> n
        _ -> fallback
      }
    Error(_) -> fallback
  }
}

/// Derive the rate-limit key from the `x-forwarded-for` header.
///
/// This service runs directly on Cloud Run (`*.run.app`), where Google's front
/// end *appends* the real client IP as the right-most entry; any client-supplied
/// hops sit to its left and are spoofable, so we take the right-most non-empty
/// entry. (Behind a custom HTTPS load balancer the authoritative hop would be
/// the second-from-right instead — revisit if the ingress changes.) A missing
/// or blank header falls back to a shared `"unknown"` bucket so those requests
/// are limited *together* rather than bypassing the limit.
pub fn client_key(forwarded_for: Result(String, Nil)) -> String {
  case forwarded_for {
    Ok(value) -> {
      let hops =
        value
        |> string.split(on: ",")
        |> list.map(string.trim)
        |> list.filter(fn(hop) { hop != "" })
      case list.last(hops) {
        Ok(ip) -> ip
        Error(_) -> "unknown"
      }
    }
    Error(_) -> "unknown"
  }
}

/// Create the ETS table backing the limiter. Idempotent; call once at startup.
pub fn init() -> Nil {
  do_init()
}

/// Whether a request for `key` is allowed under `config` right now.
pub fn allow(config: Config, key: String) -> Bool {
  allow_at(config, key, now_ms())
}

/// `allow` with an explicit timestamp, so the window behaviour is
/// deterministically testable.
pub fn allow_at(config: Config, key: String, now_ms: Int) -> Bool {
  do_allow(key, config.max_requests, config.window_ms, now_ms)
}

/// Convenience for handlers: extract the client key from the forwarded-for
/// header and check it in one call.
pub fn check(config: Config, forwarded_for: Result(String, Nil)) -> Bool {
  allow(config, client_key(forwarded_for))
}

@external(erlang, "rate_limit_ffi", "init")
fn do_init() -> Nil

@external(erlang, "rate_limit_ffi", "allow")
fn do_allow(key: String, limit: Int, window_ms: Int, now_ms: Int) -> Bool

@external(erlang, "rate_limit_ffi", "now_ms")
fn now_ms() -> Int
