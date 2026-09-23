//// One reply's speech session: plans sentences as text streams in (see
//// `speech.gleam`), keeps at most `max_in_flight` of them synthesising at a
//// time, and releases their `speech` events strictly in `seq` order, then one
//// `speech_end`. Pure: the SSE handler performs the returned side effects
//// (start these jobs, send these events).

import ai_resume_bot/speech.{type Job}
import ai_resume_bot/tts.{type Clip}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import shared.{type StreamEvent}

pub opaque type Session {
  Session(
    voicer: speech.Voicer,
    waiting: List(Job),
    in_flight: Int,
    max_in_flight: Int,
    ready: Dict(Int, StreamEvent),
    next_emit: Int,
    upto: Int,
    ended: Bool,
  )
}

/// What to do after a session event: jobs to start synthesising, and SSE
/// events to send, in order.
pub type Step {
  Step(session: Session, start: List(Job), emit: List(StreamEvent))
}

pub fn new(lang: String, max_chars: Int, max_in_flight: Int) -> Session {
  new_capped(lang, max_chars, max_chars, max_in_flight)
}

/// Like `new`, with a separate (lower) cap for Japanese sentences.
pub fn new_capped(
  lang: String,
  max_chars: Int,
  max_chars_ja: Int,
  max_in_flight: Int,
) -> Session {
  Session(
    voicer: speech.voicer_capped(lang, max_chars, max_chars_ja),
    waiting: [],
    in_flight: 0,
    max_in_flight:,
    ready: dict.new(),
    next_emit: 0,
    upto: 0,
    ended: False,
  )
}

/// More reply text streamed in.
pub fn on_text(session: Session, text: String) -> Step {
  let #(voicer, jobs) = speech.voice_text(session.voicer, text)
  advance(
    Session(..session, voicer:, waiting: list.append(session.waiting, jobs)),
  )
}

/// The reply text is complete (`tail` is any text not yet passed to
/// `on_text`).
pub fn on_text_done(session: Session, tail: String) -> Step {
  let #(voicer, jobs) = speech.voice_text(session.voicer, tail)
  let #(voicer, last) = speech.voice_finish(voicer)
  let jobs = list.append(jobs, last)
  advance(
    Session(..session, voicer:, waiting: list.append(session.waiting, jobs)),
  )
}

/// A job finished synthesising (or failed: its event carries no audio, and
/// the client reveals that sentence silently at its turn).
pub fn on_clip(session: Session, job: Job, result: Result(Clip, a)) -> Step {
  advance(
    Session(
      ..session,
      in_flight: session.in_flight - 1,
      ready: dict.insert(session.ready, job.seq, speech_event(job, result)),
    ),
  )
}

/// `speech_end` has been emitted: nothing more will come from this session.
pub fn ended(session: Session) -> Bool {
  session.ended
}

pub fn speech_event(job: Job, result: Result(Clip, a)) -> StreamEvent {
  case result {
    Ok(clip) -> {
      let ends = list.map(job.tokens, fn(t) { t.end })
      let marks =
        list.filter_map(clip.marks, fn(m) {
          case list.drop(ends, m.0) {
            [end, ..] if m.0 >= 0 ->
              Ok(shared.SpeechMark(offset: end, time: m.1))
            _ -> Error(Nil)
          }
        })
      shared.StreamSpeech(
        seq: job.seq,
        start: job.start,
        end: job.end,
        audio: Some(clip.audio),
        mime: clip.mime,
        marks:,
      )
    }
    Error(_) ->
      shared.StreamSpeech(
        seq: job.seq,
        start: job.start,
        end: job.end,
        audio: None,
        mime: "audio/mpeg",
        marks: [],
      )
  }
}

fn advance(session: Session) -> Step {
  // Start as many waiting jobs as the concurrency bound allows.
  let free = int.max(0, session.max_in_flight - session.in_flight)
  let start = list.take(session.waiting, free)
  let started = list.length(start)
  let session =
    Session(
      ..session,
      waiting: list.drop(session.waiting, started),
      in_flight: session.in_flight + started,
    )
  // Release finished clips in order.
  let #(session, emit) = release(session, [])
  // Everything planned has been sent and nothing more will be planned.
  let finished =
    !session.ended
    && speech.stopped(session.voicer)
    && session.waiting == []
    && session.in_flight == 0
    && session.next_emit == speech.planned(session.voicer)
  case finished {
    True ->
      Step(
        session: Session(..session, ended: True),
        start:,
        emit: list.append(emit, [shared.StreamSpeechEnd(upto: session.upto)]),
      )
    False -> Step(session:, start:, emit:)
  }
}

fn release(
  session: Session,
  acc: List(StreamEvent),
) -> #(Session, List(StreamEvent)) {
  case dict.get(session.ready, session.next_emit) {
    Error(_) -> #(session, list.reverse(acc))
    Ok(evt) -> {
      let upto = case evt {
        shared.StreamSpeech(end:, ..) -> int.max(session.upto, end)
        _ -> session.upto
      }
      release(
        Session(
          ..session,
          ready: dict.delete(session.ready, session.next_emit),
          next_emit: session.next_emit + 1,
          upto:,
        ),
        [evt, ..acc],
      )
    }
  }
}
