//// The voiced reply transport: a speech session fed with streamed chunks and
//// a mocked TTS. What matters to a client is that speech events arrive in
//// `seq` order however the synthesis finishes, that no more than 3 sentences
//// are synthesised at once, that a TTS failure silences one sentence without
//// losing it, and that `speech_end` is last and says how far audio goes.

import ai_resume_bot/speech.{type Job}
import ai_resume_bot/tts
import ai_resume_bot/voice
import gleam/bit_array
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import shared

fn clip_for(job: Job) -> tts.Clip {
  tts.Clip(
    audio: "QUJD",
    mime: "audio/mpeg",
    marks: list.index_map(job.tokens, fn(_, i) {
      #(i, 0.5 *. int.to_float(i + 1))
    }),
  )
}

fn seqs(events: List(shared.StreamEvent)) -> List(String) {
  list.map(events, fn(e) {
    case e {
      shared.StreamSpeech(seq:, audio: Some(_), ..) ->
        "speech " <> string.inspect(seq)
      shared.StreamSpeech(seq:, audio: None, ..) ->
        "silent " <> string.inspect(seq)
      shared.StreamSpeechEnd(upto:) -> "end " <> string.inspect(upto)
      _ -> "other"
    }
  })
}

const reply = "One here. Two here. Three here. Four here. Five here."

pub fn clips_finishing_out_of_order_are_sent_in_order_test() {
  let session = voice.new("en", 1200, 3)
  // The whole reply streams in before any synthesis finishes.
  let step = voice.on_text(session, reply)
  // Only three sentences synthesise at once; "Five here." has no stop-space
  // after it yet, so it waits for the end of the text.
  step.start |> list.map(fn(j) { j.seq }) |> should.equal([0, 1, 2])
  step.emit |> should.equal([])
  let step = voice.on_text_done(step.session, "")
  step.start |> should.equal([])
  let assert [j0, j1, j2] = voice.on_text(session, reply).start

  // Job 2 finishes first: nothing can be sent yet, but job 3 may start.
  let step = voice.on_clip(step.session, j2, Ok(clip_for(j2)))
  step.emit |> should.equal([])
  let assert [j3] = step.start
  j3.seq |> should.equal(3)
  // Job 0 finishes: it goes out alone (1 is still missing).
  let step = voice.on_clip(step.session, j0, Ok(clip_for(j0)))
  seqs(step.emit) |> should.equal(["speech 0"])
  let assert [j4] = step.start
  // Job 1 fails: it is sent without audio, and 2 (waiting) follows it.
  let step = voice.on_clip(step.session, j1, Error("boom"))
  seqs(step.emit) |> should.equal(["silent 1", "speech 2"])
  let step = voice.on_clip(step.session, j4, Ok(clip_for(j4)))
  step.emit |> should.equal([])
  voice.ended(step.session) |> should.be_false
  let step = voice.on_clip(step.session, j3, Ok(clip_for(j3)))
  // 3 and 4 go out, then the end: `upto` is the end of the last sentence.
  seqs(step.emit) |> should.equal(["speech 3", "speech 4", "end 53"])
  voice.ended(step.session) |> should.be_true
}

pub fn speech_end_comes_mid_stream_when_the_cap_is_hit_test() {
  // 8 spoken chars per sentence ("One" + "here."): a cap of 10 voices
  // only the first.
  let session = voice.new("en", 10, 3)
  let step = voice.on_text(session, "One here. Two here. Three")
  let assert [j0] = step.start
  let step = voice.on_clip(step.session, j0, Ok(clip_for(j0)))
  // The reply is still streaming, but the client learns now that audio
  // stops at offset 9 and can reveal the rest after it.
  seqs(step.emit) |> should.equal(["speech 0", "end 9"])
  let step = voice.on_text(step.session, " here. More text.")
  step.start |> should.equal([])
  step.emit |> should.equal([])
}

pub fn a_reply_with_nothing_to_say_still_ends_the_speech_test() {
  let step = voice.on_text_done(voice.new("en", 1200, 3), "```\ncode\n```")
  step.start |> should.equal([])
  seqs(step.emit) |> should.equal(["end 0"])
}

pub fn speech_events_carry_raw_offsets_for_each_mark_test() {
  let raw = "Hi, I'm **Arda**. Next."
  let step = voice.on_text(voice.new("en", 1200, 3), raw)
  let assert [job] = step.start
  let evt =
    voice.speech_event(
      job,
      Ok(tts.Clip("QUJD", "audio/mpeg", [#(0, 0.3), #(1, 0.6), #(2, 1.1)])),
    )
  evt
  |> shared.stream_event_to_json
  |> json.to_string
  |> should.equal(
    "{\"type\":\"speech\",\"seq\":0,\"start\":0,\"end\":17,\"audio\":\"QUJD\",\"mime\":\"audio/mpeg\",\"marks\":[{\"o\":3,\"t\":0.3},{\"o\":7,\"t\":0.6},{\"o\":17,\"t\":1.1}]}",
  )
  // A failed clip keeps its place with `audio: null`.
  voice.speech_event(job, Error(Nil))
  |> shared.stream_event_to_json
  |> json.to_string
  |> should.equal(
    "{\"type\":\"speech\",\"seq\":0,\"start\":0,\"end\":17,\"audio\":null,\"mime\":\"audio/mpeg\",\"marks\":[]}",
  )
}

pub fn mock_tts_returns_a_wav_with_one_mark_per_word_test() {
  let cfg =
    tts.config_from_env(fn(n) {
      case n {
        "TTS_BACKEND" -> Ok("mock")
        _ -> Error(Nil)
      }
    })
  let assert [job] =
    voice.on_text_done(voice.new("ja", 1200, 3), "アルダは東京に住んでいます。").start
  let assert Ok(clip) = tts.synthesize(cfg, job)
  clip.mime |> should.equal("audio/wav")
  let assert Ok(<<"RIFF":utf8, _:bits>>) = bit_array.base64_decode(clip.audio)
  clip.marks |> list.map(fn(m) { m.0 }) |> should.equal([0, 1, 2])
  // Marks move forward in time.
  let assert [#(_, a), #(_, b), #(_, c)] = clip.marks
  { a <. b && b <. c } |> should.be_true
}

// ---------------------------------------------------------------------------
// Google TTS wire format
// ---------------------------------------------------------------------------

pub fn synthesize_request_asks_for_marks_mp3_and_the_configured_voice_test() {
  let cfg = tts.config_from_env(fn(_) { Error(Nil) })
  let assert [job] =
    voice.on_text_done(voice.new("tr", 1200, 3), "Merhaba dünya.").start
  tts.request_body(cfg, job, True)
  |> json.to_string
  |> should.equal(
    "{\"input\":{\"ssml\":\"<speak>Merhaba<mark name=\\\"0\\\"/> dünya.<mark name=\\\"1\\\"/></speak>\"},\"voice\":{\"languageCode\":\"tr-TR\",\"name\":\"tr-TR-Standard-E\"},\"audioConfig\":{\"audioEncoding\":\"MP3\",\"sampleRateHertz\":24000,\"pitch\":-4.0,\"speakingRate\":0.92},\"enableTimePointing\":[\"SSML_MARK\"]}",
  )
  // The no-marks fallback sends plain text and no timepointing.
  tts.request_body(cfg, job, False)
  |> json.to_string
  |> string.contains("\"input\":{\"text\":\"Merhaba dünya.\"}")
  |> should.be_true
}

pub fn synthesize_response_decodes_timepoints_or_none_test() {
  tts.decode_response(
    "{\"audioContent\":\"QUJD\",\"timepoints\":[{\"markName\":\"0\",\"timeSeconds\":0.555},{\"markName\":\"1\",\"timeSeconds\":1}],\"audioConfig\":{}}",
  )
  |> should.equal(Ok(tts.Clip("QUJD", "audio/mpeg", [#(0, 0.555), #(1, 1.0)])))
  tts.decode_response("{\"audioContent\":\"QUJD\"}")
  |> should.equal(Ok(tts.Clip("QUJD", "audio/mpeg", [])))
  tts.decode_response("{\"error\":{}}") |> should.equal(Error(Nil))
}

pub fn tts_config_defaults_and_overrides_test() {
  let cfg = tts.config_from_env(fn(_) { Error(Nil) })
  cfg.enabled |> should.be_true
  cfg.backend |> should.equal(tts.Google)
  #(cfg.voice_en, cfg.voice_tr, cfg.voice_ja)
  |> should.equal(#("en-US-Standard-D", "tr-TR-Standard-E", "ja-JP-Standard-C"))
  cfg.max_chars |> should.equal(1200)
  let cfg =
    tts.config_from_env(fn(n) {
      case n {
        "VOICE_ENABLED" -> Ok("false")
        "TTS_VOICE_EN" -> Ok("en-US-Standard-J")
        "TTS_PITCH" -> Ok("-2")
        "VOICE_MAX_CHARS" -> Ok("600")
        _ -> Error(Nil)
      }
    })
  #(cfg.enabled, cfg.voice_en, cfg.pitch, cfg.max_chars)
  |> should.equal(#(False, "en-US-Standard-J", -2.0, 600))
  tts.available(cfg) |> should.be_false
}

// ---------------------------------------------------------------------------
// Request compatibility
// ---------------------------------------------------------------------------

pub fn voice_off_requests_are_byte_identical_to_before_test() {
  let req =
    shared.ChatRequest(message: "hi", history: [shared.ChatMessage("user", "a")])
  shared.stream_request_to_json(req, shared.VoiceOptions(False, "ja"))
  |> json.to_string
  |> should.equal(json.to_string(shared.chat_request_to_json(req)))
  shared.stream_request_to_json(req, shared.VoiceOptions(True, "ja"))
  |> json.to_string
  |> should.equal(
    "{\"message\":\"hi\",\"history\":[{\"role\":\"user\",\"content\":\"a\"}],\"voice\":true,\"lang\":\"ja\"}",
  )
}

pub fn voice_options_default_to_off_test() {
  json.parse("{\"message\":\"hi\"}", shared.voice_options_decoder())
  |> should.equal(Ok(shared.VoiceOptions(on: False, lang: "en")))
  json.parse(
    "{\"message\":\"hi\",\"voice\":true,\"lang\":\"tr\"}",
    shared.voice_options_decoder(),
  )
  |> should.equal(Ok(shared.VoiceOptions(on: True, lang: "tr")))
}

pub fn speech_events_round_trip_through_the_shared_decoder_test() {
  let events = [
    shared.StreamVoice(on: True),
    shared.StreamSpeech(1, 10, 20, None, "audio/mpeg", []),
    shared.StreamSpeech(2, 21, 30, Some("QQ=="), "audio/mpeg", [
      shared.SpeechMark(25, 0.25),
    ]),
    shared.StreamSpeechEnd(upto: 30),
  ]
  list.map(events, fn(e) {
    shared.stream_event_to_json(e)
    |> json.to_string
    |> json.parse(shared.stream_event_decoder())
  })
  |> should.equal(list.map(events, Ok))
}
