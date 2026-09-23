//// Google Cloud Text-to-Speech client for voiced replies, plus a mock.
////
//// Auth is the Cloud Run service identity: an access token from the metadata
//// server (Application Default Credentials), cached until shortly before it
//// expires. No API keys or secrets. For local runs against the real API,
//// `TTS_ACCESS_TOKEN` (+ `TTS_QUOTA_PROJECT`) can stand in for the metadata
//// server, e.g. `TTS_ACCESS_TOKEN=$(gcloud auth print-access-token)`.
////
//// Requests go to `v1beta1/text:synthesize` (the only version that returns
//// SSML mark timepoints) for MP3 at 24 kHz (Safari cannot decode Ogg), pitched
//// down and slightly slowed for the construct's voice. If the API rejects the
//// marked SSML, the sentence is retried as plain text without marks, and the
//// client reveals it linearly.
////
//// A 403 or 429 (API disabled, no permission, quota spent), or no token,
//// marks TTS unavailable for a while: replies then say `voice: false` up
//// front instead of streaming silent sentences.
////
//// `TTS_BACKEND=mock` swaps in a fake synthesiser (a buzzing WAV tone per
//// word with evenly spaced marks, after a random delay) for local end-to-end
//// runs and tests.

import ai_resume_bot/speech.{type Job}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import logging

pub type Backend {
  Google
  Mock
}

pub type Config {
  Config(
    enabled: Bool,
    backend: Backend,
    voice_en: String,
    voice_tr: String,
    voice_ja: String,
    pitch: Float,
    speaking_rate: Float,
    max_chars: Int,
    dev_token: String,
    quota_project: String,
  )
}

/// Synthesised audio for one sentence. `audio` is base64; `marks` pair a mark
/// index (token N of the job) with the time in seconds it was reached.
pub type Clip {
  Clip(audio: String, mime: String, marks: List(#(Int, Float)))
}

// Low, male Standard voices: each language's lowest male Standard voice by
// median f0 on a sample sentence at the construct's pitch (-4 st), measured
// against the live API on 2026-09-23. All of them return mark timepoints.
//   en-US  D ~99 Hz   I ~100  J ~104  B ~110  A ~125
//   tr-TR  E ~92 Hz   B ~117
//   ja-JP  C ~120 Hz  D ~124
pub const default_voice_en = "en-US-Standard-D"

pub const default_voice_tr = "tr-TR-Standard-E"

pub const default_voice_ja = "ja-JP-Standard-C"

const synth_url = "https://texttospeech.googleapis.com/v1beta1/text:synthesize"

const voices_url = "https://texttospeech.googleapis.com/v1/voices"

const metadata_token_url = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"

/// How long to stop offering voice after the API refused us.
const unavailable_seconds = 600

/// Read the config from the environment (via `get`, so tests can fake it).
pub fn config_from_env(get: fn(String) -> Result(String, Nil)) -> Config {
  let str = fn(name, default) {
    case get(name) {
      Ok(v) ->
        case string.trim(v) {
          "" -> default
          v -> v
        }
      Error(_) -> default
    }
  }
  let num = fn(name, default) {
    let raw = str(name, "")
    case float.parse(raw), int.parse(raw) {
      Ok(f), _ -> f
      _, Ok(i) -> int.to_float(i)
      _, _ -> default
    }
  }
  Config(
    enabled: case string.lowercase(str("VOICE_ENABLED", "true")) {
      "false" | "0" | "no" | "off" -> False
      _ -> True
    },
    backend: case string.lowercase(str("TTS_BACKEND", "google")) {
      "mock" -> Mock
      _ -> Google
    },
    voice_en: str("TTS_VOICE_EN", default_voice_en),
    voice_tr: str("TTS_VOICE_TR", default_voice_tr),
    voice_ja: str("TTS_VOICE_JA", default_voice_ja),
    pitch: num("TTS_PITCH", -4.0),
    speaking_rate: num("TTS_SPEAKING_RATE", 0.92),
    max_chars: case int.parse(str("VOICE_MAX_CHARS", "")) {
      Ok(n) if n > 0 -> n
      _ -> 1200
    },
    dev_token: str("TTS_ACCESS_TOKEN", ""),
    quota_project: str("TTS_QUOTA_PROJECT", ""),
  )
}

pub fn voice_for(cfg: Config, lang: String) -> String {
  case lang {
    "ja" -> cfg.voice_ja
    "tr" -> cfg.voice_tr
    _ -> cfg.voice_en
  }
}

/// "en-US-Standard-D" -> "en-US".
pub fn language_code(voice: String) -> String {
  case string.split(voice, "-") {
    [lang, region, ..] -> lang <> "-" <> region
    _ -> voice
  }
}

/// Voice is on and the API has not refused us recently.
pub fn available(cfg: Config) -> Bool {
  cfg.enabled && now_seconds() >= unavailable_until()
}

/// Synthesise one sentence. Never crashes: any failure is an `Error`.
pub fn synthesize(cfg: Config, job: Job) -> Result(Clip, String) {
  case
    rescue(fn() {
      case cfg.backend {
        Google -> google_synthesize(cfg, job)
        Mock -> mock_synthesize(job)
      }
    })
  {
    Ok(r) -> r
    Error(_) -> Error("TTS worker crashed")
  }
}

// ---------------------------------------------------------------------------
// Google
// ---------------------------------------------------------------------------

/// The synthesize request. `marks: False` sends the plain words instead of
/// the marked SSML (fallback for voices that reject marks).
pub fn request_body(cfg: Config, job: Job, marks: Bool) -> json.Json {
  let voice = voice_for(cfg, job.lang)
  let input = case marks {
    True -> json.object([#("ssml", json.string(job.ssml))])
    False -> json.object([#("text", json.string(job.text))])
  }
  let fields = [
    #("input", input),
    #(
      "voice",
      json.object([
        #("languageCode", json.string(language_code(voice))),
        #("name", json.string(voice)),
      ]),
    ),
    #(
      "audioConfig",
      json.object([
        #("audioEncoding", json.string("MP3")),
        #("sampleRateHertz", json.int(24_000)),
        #("pitch", json.float(cfg.pitch)),
        #("speakingRate", json.float(cfg.speaking_rate)),
      ]),
    ),
  ]
  case marks {
    True ->
      json.object(
        list.append(fields, [
          #("enableTimePointing", json.array(["SSML_MARK"], json.string)),
        ]),
      )
    False -> json.object(fields)
  }
}

/// `{"audioContent": base64, "timepoints": [{"markName","timeSeconds"}]}`.
/// Missing timepoints (voice without mark support) give no marks.
pub fn decode_response(body: String) -> Result(Clip, Nil) {
  let number =
    decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
  let timepoint = {
    use name <- decode.field("markName", decode.string)
    use t <- decode.optional_field("timeSeconds", 0.0, number)
    decode.success(#(name, t))
  }
  let decoder = {
    use audio <- decode.field("audioContent", decode.string)
    use points <- decode.optional_field(
      "timepoints",
      [],
      decode.list(timepoint),
    )
    decode.success(#(audio, points))
  }
  case json.parse(body, decoder) {
    Ok(#(audio, points)) if audio != "" ->
      Ok(Clip(
        audio:,
        mime: "audio/mpeg",
        marks: list.filter_map(points, fn(p) {
          int.parse(p.0) |> result.map(fn(i) { #(i, p.1) })
        }),
      ))
    _ -> Error(Nil)
  }
}

fn google_synthesize(cfg: Config, job: Job) -> Result(Clip, String) {
  use token <- result.try(access_token(cfg))
  let attempt = fn(marks) {
    use #(status, body) <- result.try(post_json(
      cfg,
      token,
      request_body(cfg, job, marks),
    ))
    case status {
      200 ->
        decode_response(body)
        |> result.replace_error("TTS: undecodable response")
      _ -> Error(refused(status, body))
    }
  }
  case attempt(True) {
    // Marks (or the SSML) rejected: speak the plain words, reveal linearly.
    Error("TTS HTTP 400" <> _) -> attempt(False)
    other -> other
  }
}

fn refused(status: Int, body: String) -> String {
  case status {
    401 -> token_forget()
    403 | 429 -> mark_unavailable()
    _ -> Nil
  }
  "TTS HTTP " <> int.to_string(status) <> ": " <> string.slice(body, 0, 300)
}

fn post_json(
  cfg: Config,
  token: String,
  body: json.Json,
) -> Result(#(Int, String), String) {
  use req <- result.try(
    request.to(synth_url) |> result.replace_error("bad TTS url"),
  )
  req
  |> request.set_method(http.Post)
  |> request.set_header("content-type", "application/json")
  |> authorise(cfg, token)
  |> request.set_body(json.to_string(body))
  |> send(10_000)
}

fn authorise(
  req: request.Request(String),
  cfg: Config,
  token: String,
) -> request.Request(String) {
  let req = request.set_header(req, "authorization", "Bearer " <> token)
  case cfg.quota_project {
    "" -> req
    project -> request.set_header(req, "x-goog-user-project", project)
  }
}

fn send(
  req: request.Request(String),
  timeout: Int,
) -> Result(#(Int, String), String) {
  httpc.configure()
  |> httpc.timeout(timeout)
  |> httpc.dispatch(req)
  |> result.map(fn(resp) { #(resp.status, resp.body) })
  |> result.map_error(fn(e) { "TTS transport: " <> string.inspect(e) })
}

fn access_token(cfg: Config) -> Result(String, String) {
  case cfg.dev_token {
    "" ->
      case token_get() {
        Ok(#(token, expires)) if expires > 0 -> {
          case expires - now_seconds() > 120 {
            True -> Ok(token)
            False -> fetch_token()
          }
        }
        _ -> fetch_token()
      }
    token -> Ok(token)
  }
}

fn fetch_token() -> Result(String, String) {
  let decoder = {
    use token <- decode.field("access_token", decode.string)
    use expires_in <- decode.field("expires_in", decode.int)
    decode.success(#(token, expires_in))
  }
  let assert Ok(req) = request.to(metadata_token_url)
  let fetched =
    req
    |> request.set_header("metadata-flavor", "Google")
    |> send(2000)
    |> result.try(fn(resp) {
      case resp {
        #(200, body) ->
          json.parse(body, decoder)
          |> result.replace_error("metadata token: undecodable")
        #(status, _) -> Error("metadata token: HTTP " <> int.to_string(status))
      }
    })
  case fetched {
    Ok(#(token, expires_in)) -> {
      token_put(token, now_seconds() + expires_in)
      Ok(token)
    }
    Error(e) -> {
      // No service identity (e.g. local dev): stop offering voice for now.
      mark_unavailable()
      Error(e)
    }
  }
}

fn mark_unavailable() -> Nil {
  set_unavailable_until(now_seconds() + unavailable_seconds)
}

/// Startup check, run in the background: log whether TTS works with this
/// service identity and whether the configured voices exist. A failure marks
/// TTS unavailable (replies say `voice: false`) until the next retry window.
pub fn probe(cfg: Config) -> Nil {
  case cfg.enabled, cfg.backend {
    False, _ -> logging.log(logging.Info, "Voice disabled (VOICE_ENABLED)")
    True, Mock -> logging.log(logging.Info, "Voice on, using the MOCK TTS")
    True, Google -> {
      let wanted = [cfg.voice_en, cfg.voice_tr, cfg.voice_ja]
      let listed = {
        use token <- result.try(access_token(cfg))
        use req <- result.try(
          request.to(voices_url) |> result.replace_error("bad voices url"),
        )
        use #(status, body) <- result.try(
          req |> authorise(cfg, token) |> send(10_000),
        )
        case status {
          200 ->
            json.parse(
              body,
              decode.at(
                ["voices"],
                decode.list(decode.at(["name"], decode.string)),
              ),
            )
            |> result.replace_error("voices: undecodable")
          _ -> Error(refused(status, body))
        }
      }
      case listed {
        Ok(names) -> {
          let missing = list.filter(wanted, fn(v) { !list.contains(names, v) })
          case missing {
            [] ->
              logging.log(
                logging.Info,
                "Voice on: TTS reachable, voices " <> string.join(wanted, ", "),
              )
            _ ->
              logging.log(
                logging.Warning,
                "Voice: unknown TTS voices " <> string.join(missing, ", "),
              )
          }
        }
        Error(e) ->
          logging.log(logging.Warning, "Voice unavailable for now: " <> e)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Mock
// ---------------------------------------------------------------------------

const mock_rate = 16_000

/// A WAV "voice": one buzzing tone per word (longer words, longer tones) with
/// a short gap after each, a mark at the end of every tone, after a random
/// 60-360 ms delay so clips finish out of order.
fn mock_synthesize(job: Job) -> Result(Clip, String) {
  process.sleep(60 + int.random(300))
  let #(pcm, marks, _) =
    list.index_fold(job.tokens, #(<<>>, [], 0), fn(acc, tok, i) {
      let #(pcm, marks, n) = acc
      let chars = string.length(tok.text)
      let dur = float.min(0.9, 0.06 +. 0.075 *. int.to_float(chars))
      let tone_n = float.round(dur *. int.to_float(mock_rate))
      let gap_n = mock_rate / 20
      let f = 110.0 +. 18.0 *. int.to_float(i % 5)
      let pcm = tone(pcm, 0, tone_n, f)
      let pcm = silence(pcm, gap_n)
      let t = int.to_float(n + tone_n) /. int.to_float(mock_rate)
      #(pcm, [#(i, t), ..marks], n + tone_n + gap_n)
    })
  Ok(Clip(
    audio: bit_array.base64_encode(wav(pcm), True),
    mime: "audio/wav",
    marks: list.reverse(marks),
  ))
}

fn tone(acc: BitArray, i: Int, n: Int, f: Float) -> BitArray {
  case i >= n {
    True -> acc
    False -> {
      let t = int.to_float(i) /. int.to_float(mock_rate)
      let w = 2.0 *. pi *. f *. t
      let env = sin(pi *. int.to_float(i) /. int.to_float(n))
      let x = { sin(w) +. 0.5 *. sin(2.0 *. w) +. 0.3 *. sin(3.0 *. w) } *. env
      let s = float.round(x *. 0.3 *. 32_767.0)
      tone(<<acc:bits, s:little-size(16)>>, i + 1, n, f)
    }
  }
}

fn silence(acc: BitArray, n: Int) -> BitArray {
  case n <= 0 {
    True -> acc
    False -> silence(<<acc:bits, 0:little-size(16)>>, n - 1)
  }
}

fn wav(pcm: BitArray) -> BitArray {
  let size = bit_array.byte_size(pcm)
  <<
    "RIFF":utf8,
    { 36 + size }:little-size(32),
    "WAVE":utf8,
    "fmt ":utf8,
    16:little-size(32),
    1:little-size(16),
    1:little-size(16),
    mock_rate:little-size(32),
    { mock_rate * 2 }:little-size(32),
    2:little-size(16),
    16:little-size(16),
    "data":utf8,
    size:little-size(32),
    pcm:bits,
  >>
}

const pi = 3.141592653589793

@external(erlang, "math", "sin")
fn sin(x: Float) -> Float

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "ai_resume_bot_tts_ffi", "token_get")
fn token_get() -> Result(#(String, Int), Nil)

@external(erlang, "ai_resume_bot_tts_ffi", "token_put")
fn token_put(token: String, expires_at: Int) -> Nil

@external(erlang, "ai_resume_bot_tts_ffi", "token_forget")
fn token_forget() -> Nil

@external(erlang, "ai_resume_bot_tts_ffi", "unavailable_until")
fn unavailable_until() -> Int

@external(erlang, "ai_resume_bot_tts_ffi", "set_unavailable_until")
fn set_unavailable_until(seconds: Int) -> Nil

@external(erlang, "ai_resume_bot_tts_ffi", "now_seconds")
fn now_seconds() -> Int

@external(erlang, "ai_resume_bot_tts_ffi", "rescue")
fn rescue(f: fn() -> a) -> Result(a, Nil)
