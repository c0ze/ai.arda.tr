//// Minimal .env loader with "real env wins" semantics.
////
//// Behaviour matches `godotenv.Load()` in the Go backend: if a `.env` file
//// exists, each `KEY=VALUE` line is read and `KEY` is put into the process
//// environment *only if it is not already set*. Missing file is not an
//// error. Comments (`#`) and blank lines are skipped. Values may optionally
//// be wrapped in single or double quotes, which are stripped.

import envoy
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Load `.env` from the current working directory, falling back to the
/// parent directory. This lets you `cd gleam_backend && gleam run` and still
/// pick up a repo-root `.env`, matching what developers expect from
/// godotenv/dotenv in Node. Never fails: a missing or malformed file is
/// silently ignored so production (which injects real env vars) works the
/// same as local dev.
pub fn load_default() -> Nil {
  load(".env")
  load("../.env")
}

pub fn load(path: String) -> Nil {
  case simplifile.read(path) {
    Error(_) -> Nil
    Ok(contents) -> {
      contents
      |> string.split("\n")
      |> list.each(apply_line)
    }
  }
}

fn apply_line(raw: String) -> Nil {
  let line = string.trim(raw)
  case line == "" || string.starts_with(line, "#") {
    True -> Nil
    False ->
      case parse_kv(line) {
        Error(_) -> Nil
        Ok(#(key, value)) ->
          case envoy.get(key) {
            // Real env wins: only set if the var is unset.
            Ok(_) -> Nil
            Error(_) -> envoy.set(key, value)
          }
      }
  }
}

fn parse_kv(line: String) -> Result(#(String, String), Nil) {
  // Strip an optional `export ` prefix so files sourced by shell also load.
  let line = case string.starts_with(line, "export ") {
    True -> string.drop_start(line, 7) |> string.trim
    False -> line
  }
  use #(key, value) <- result.try(string.split_once(line, "="))
  let key = string.trim(key)
  let value = value |> string.trim |> unquote
  case key {
    "" -> Error(Nil)
    _ -> Ok(#(key, value))
  }
}

fn unquote(value: String) -> String {
  case
    { string.starts_with(value, "\"") && string.ends_with(value, "\"") }
    || { string.starts_with(value, "'") && string.ends_with(value, "'") }
  {
    True ->
      value
      |> string.drop_start(1)
      |> string.drop_end(1)
    False -> value
  }
}
