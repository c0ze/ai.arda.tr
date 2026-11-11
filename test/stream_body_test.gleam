//// The stream path reads its body itself: mist.read_body only checks
//// Content-Length, so a chunked request could otherwise send any amount.

import ai_resume_bot/stream_handler
import gleeunit/should
import mist

/// A fake `mist.stream` consumer over a fixed list of chunks. `calls` counts
/// how many chunks were pulled, so a test can see that reading stops early.
fn chunks(
  parts: List(BitArray),
) -> fn(Int) -> Result(mist.Chunk, mist.ReadError) {
  fn(_size) {
    case parts {
      [] -> Ok(mist.Done)
      [part, ..rest] -> Ok(mist.Chunk(part, chunks(rest)))
    }
  }
}

pub fn a_chunked_body_under_the_limit_is_read_whole_test() {
  stream_handler.collect_body(chunks([<<"ab":utf8>>, <<"cd":utf8>>]), 4)
  |> should.equal(Ok(<<"abcd":utf8>>))
}

pub fn a_chunked_body_over_the_limit_is_excess_test() {
  stream_handler.collect_body(
    chunks([<<"ab":utf8>>, <<"cd":utf8>>, <<"e":utf8>>]),
    4,
  )
  |> should.equal(Error(mist.ExcessBody))
}

pub fn reading_stops_as_soon_as_the_limit_is_passed_test() {
  // The chunk after the one that crosses the limit is never pulled.
  let boom = fn(_size) -> Result(mist.Chunk, mist.ReadError) {
    panic as "read past the limit"
  }
  let consume = fn(_size) { Ok(mist.Chunk(<<"too long":utf8>>, boom)) }
  stream_handler.collect_body(consume, 4)
  |> should.equal(Error(mist.ExcessBody))
}

pub fn a_malformed_body_stays_malformed_test() {
  let consume = fn(_size) -> Result(mist.Chunk, mist.ReadError) {
    Error(mist.MalformedBody)
  }
  stream_handler.collect_body(consume, 4)
  |> should.equal(Error(mist.MalformedBody))
}
