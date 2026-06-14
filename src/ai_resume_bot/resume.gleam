//// Resume fetch + load, ported from internal/resume/resume.go.
////
//// Fetches the five JSON files from c0ze/resume, caches them on disk, and
//// decodes them into a `ResumeData` value at startup.

import ai_resume_bot/models.{type ResumeData, ResumeData}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

const base_url = "https://raw.githubusercontent.com/c0ze/resume/main/content/en/"

pub const files: List(String) = [
  "about.json", "experience.json", "projects.json", "skills.json",
  "education.json",
]

pub type FetchError {
  HttpError(file: String, reason: String)
  WriteError(file: String, reason: String)
  ReadError(file: String, reason: String)
  DecodeError(file: String, reason: String)
}

// ---------------------------------------------------------------------------
// Fetch to disk
// ---------------------------------------------------------------------------

pub fn fetch_to_disk(output_dir: String) -> Result(Nil, FetchError) {
  let _ = simplifile.create_directory_all(output_dir)
  list.try_each(files, fn(file) { fetch_one(file, output_dir) })
}

fn fetch_one(file: String, output_dir: String) -> Result(Nil, FetchError) {
  let url = base_url <> file
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { HttpError(file, "invalid url: " <> url) }),
  )
  use resp <- result.try(
    httpc.send_bits(request.set_body(req, <<>>))
    |> result.map_error(fn(e) { HttpError(file, string.inspect(e)) }),
  )
  case resp.status {
    200 -> {
      let path = join_path(output_dir, file)
      simplifile.write_bits(path, resp.body)
      |> result.map_error(fn(e) { WriteError(file, string.inspect(e)) })
    }
    code -> Error(HttpError(file, "status " <> int.to_string(code)))
  }
}

fn join_path(dir: String, file: String) -> String {
  case string.ends_with(dir, "/") {
    True -> dir <> file
    False -> dir <> "/" <> file
  }
}

// ---------------------------------------------------------------------------
// Load from disk
// ---------------------------------------------------------------------------

pub fn load_from_disk(input_dir: String) -> Result(ResumeData, FetchError) {
  use about <- result.try(load_file(
    input_dir,
    "about.json",
    models.about_decoder(),
  ))
  use experience <- result.try(load_file(
    input_dir,
    "experience.json",
    models.experience_decoder(),
  ))
  use projects <- result.try(load_file(
    input_dir,
    "projects.json",
    models.projects_decoder(),
  ))
  use skills <- result.try(load_file(
    input_dir,
    "skills.json",
    models.skills_decoder(),
  ))
  use education <- result.try(load_file(
    input_dir,
    "education.json",
    models.education_decoder(),
  ))
  Ok(ResumeData(about:, experience:, projects:, skills:, education:))
}

fn load_file(
  dir: String,
  file: String,
  decoder: decode.Decoder(a),
) -> Result(a, FetchError) {
  let path = join_path(dir, file)
  use bits <- result.try(
    simplifile.read_bits(path)
    |> result.map_error(fn(e) { ReadError(file, string.inspect(e)) }),
  )
  use text <- result.try(
    bit_array.to_string(bits)
    |> result.map_error(fn(_) { ReadError(file, "invalid utf-8") }),
  )
  json.parse(text, decoder)
  |> result.map_error(fn(e) { DecodeError(file, string.inspect(e)) })
}
