//// Sentence splitting, markdown stripping and raw-offset mapping for voiced
//// replies. Offsets are UTF-16 code units because the browser reveals the
//// raw reply with `raw.slice(0, offset)`: an off-by-one here shows half a
//// word, or a dangling `**`, on screen while the voice is elsewhere.

import ai_resume_bot/speech.{Token}
import gleam/list
import gleam/string
import gleeunit/should

/// Feed `parts` as streamed chunks, then finish: all segments, in order.
fn split(parts: List(String)) -> List(#(Int, Int, String)) {
  let #(splitter, segs) =
    list.fold(parts, #(speech.new_splitter(), []), fn(acc, part) {
      let #(s, segs) = acc
      let #(s, new) = speech.feed(s, part)
      #(s, list.append(segs, new))
    })
  list.append(segs, speech.finish(splitter))
  |> list.map(fn(seg: speech.Segment) { #(seg.start, seg.end, seg.text) })
}

/// Every codepoint as its own chunk: the harshest streaming split.
fn by_char(text: String) -> List(String) {
  string.to_graphemes(text)
}

fn token_texts(text: String) -> List(String) {
  first_segment_tokens(text) |> list.map(fn(t) { t.text })
}

fn first_segment_tokens(text: String) -> List(speech.Token) {
  // Single-sentence inputs: the whole text is the one segment.
  let #(s, segs) = speech.feed(speech.new_splitter(), text)
  let assert [seg] = list.append(segs, speech.finish(s))
  speech.tokens(seg.chars)
}

/// JavaScript-style `raw.slice(0, n)` over UTF-16 units, for asserting what a
/// client would show at a given offset.
fn js_prefix(raw: String, n: Int) -> String {
  raw
  |> string.to_utf_codepoints
  |> list.fold(#("", 0), fn(acc, cp) {
    let #(out, len) = acc
    let w = case string.utf_codepoint_to_int(cp) > 0xFFFF {
      True -> 2
      False -> 1
    }
    case len + w <= n {
      True -> #(out <> string.from_utf_codepoints([cp]), len + w)
      False -> #(out, n + 1)
    }
  })
  |> fn(r) { r.0 }
}

// ---------------------------------------------------------------------------
// Splitting
// ---------------------------------------------------------------------------

pub fn english_sentences_split_the_same_however_the_stream_is_chunked_test() {
  let raw = "Hello there. I'm **Arda**! Is it on? Yes.\n- Item one\n## Skills"
  let expected = [
    #(0, 12, "Hello there."),
    #(13, 26, "I'm **Arda**!"),
    #(27, 36, "Is it on?"),
    #(37, 41, "Yes."),
    #(42, 52, "- Item one"),
    #(53, 62, "## Skills"),
  ]
  split([raw]) |> should.equal(expected)
  split(by_char(raw)) |> should.equal(expected)
  split([
    "Hello there",
    ". I'm **Ar",
    "da**! Is it on",
    "? Yes.\n- It",
    "em one\n## Skills",
  ])
  |> should.equal(expected)
}

pub fn a_stop_at_the_end_of_a_chunk_waits_for_the_next_one_test() {
  // "3." could be "3.5": nothing is emitted until the next char arrives.
  let #(s, segs) = speech.feed(speech.new_splitter(), "Version 3.")
  segs |> should.equal([])
  let #(_, segs) = speech.feed(s, "5 is out. Next")
  segs
  |> list.map(fn(seg: speech.Segment) { seg.text })
  |> should.equal(["Version 3.5 is out."])
}

pub fn list_numbers_and_abbreviations_are_not_sentence_ends_test() {
  split(["1. First item, e.g. this one. Done"])
  |> list.map(fn(s) { s.2 })
  |> should.equal(["1. First item, e.g. this one.", "Done"])
}

pub fn japanese_splits_on_full_stops_without_spaces_test() {
  let raw = "アルダは東京に住んでいます。次の文！最後？"
  split(by_char(raw))
  |> should.equal([
    #(0, 14, "アルダは東京に住んでいます。"),
    #(14, 18, "次の文！"),
    #(18, 21, "最後？"),
  ])
}

pub fn turkish_letters_count_as_one_utf16_unit_test() {
  let raw = "İstanbul'da ağaçlar yeşil. Şimdi ğ ı!"
  let segs = split(by_char(raw))
  segs
  |> should.equal([
    #(0, 26, "İstanbul'da ağaçlar yeşil."),
    #(27, 37, "Şimdi ğ ı!"),
  ])
  js_prefix(raw, 26) |> should.equal("İstanbul'da ağaçlar yeşil.")
}

pub fn astral_characters_take_two_utf16_units_test() {
  // 👋 is U+1F44B: JS counts it as 2, so every later offset shifts by one.
  let raw = "Hi 👋 there. Next 😀 one."
  split([raw])
  |> should.equal([#(0, 12, "Hi 👋 there."), #(13, 25, "Next 😀 one.")])
  speech.utf16_length(raw) |> should.equal(25)
  js_prefix(raw, 12) |> should.equal("Hi 👋 there.")
}

pub fn over_long_clauses_are_cut_at_a_space_test() {
  let raw = string.repeat("word ", 100)
  let segs = split([raw])
  let assert [#(0, end, first), ..] = segs
  { end <= 220 } |> should.be_true
  string.ends_with(first, "word") |> should.be_true
  // Nothing lost: the pieces cover every word.
  segs
  |> list.map(fn(s) { s.2 })
  |> string.join(" ")
  |> should.equal(string.trim(raw))
}

// ---------------------------------------------------------------------------
// Markdown -> speakable words, with raw end offsets
// ---------------------------------------------------------------------------

pub fn emphasis_and_list_markers_are_silent_but_revealed_with_the_word_test() {
  let raw = "- I'm **Arda**, an engineer."
  let toks = first_segment_tokens(raw)
  toks
  |> list.map(fn(t) { t.text })
  |> should.equal(["I'm", "Arda,", "an", "engineer."])
  // "Arda," ends after the closing ** and the comma, so revealing up to it
  // never leaves an unclosed ** on screen.
  let assert [_, arda, ..] = toks
  js_prefix(raw, arda.end) |> should.equal("- I'm **Arda**,")
}

pub fn links_are_spoken_as_their_label_test() {
  let raw = "Read [my blog](https://blog.arda.tr/posts) today."
  let toks = first_segment_tokens(raw)
  toks
  |> list.map(fn(t) { t.text })
  |> should.equal(["Read", "my", "blog", "today."])
  let assert [_, _, blog, _] = toks
  // Revealing "blog" reveals the whole link markup.
  js_prefix(raw, blog.end)
  |> should.equal("Read [my blog](https://blog.arda.tr/posts)")
}

pub fn bare_urls_are_spoken_as_their_domain_test() {
  let raw = "See https://www.arda.tr/about?x=1, then ask."
  let toks = first_segment_tokens(raw)
  toks
  |> list.map(fn(t) { t.text })
  |> should.equal(["See", "arda.tr,", "then", "ask."])
  let assert [_, host, ..] = toks
  js_prefix(raw, host.end) |> should.equal("See https://www.arda.tr/about?x=1,")
}

pub fn headings_code_and_emoji_are_not_read_test() {
  token_texts("## `Gleam` skills 🚀") |> should.equal(["Gleam", "skills"])
  token_texts("---") |> should.equal([])
  // Underscores inside identifiers stay; at word edges they are emphasis.
  token_texts("_really_ snake_case") |> should.equal(["really", "snake_case"])
}

pub fn japanese_marks_fall_at_kana_run_ends_and_punctuation_test() {
  let raw = "アルダは東京に住んでいるソフトウェアエンジニアです。"
  let toks = first_segment_tokens(raw)
  toks
  |> list.map(fn(t) { t.text })
  |> should.equal(["アルダは", "東京に", "住んでいる", "ソフトウェアエンジニアです。"])
  toks
  |> list.map(fn(t) { t.space_before })
  |> should.equal([False, False, False, False])
  let assert [_, tokyo, ..] = toks
  js_prefix(raw, tokyo.end) |> should.equal("アルダは東京に")
}

pub fn turkish_words_keep_their_letters_test() {
  let raw = "**Şirket:** İş ağı, ılık."
  let toks = first_segment_tokens(raw)
  toks
  |> list.map(fn(t) { t.text })
  |> should.equal(["Şirket:", "İş", "ağı,", "ılık."])
  let assert [sirket, ..] = toks
  js_prefix(raw, sirket.end) |> should.equal("**Şirket:**")
}

// ---------------------------------------------------------------------------
// SSML
// ---------------------------------------------------------------------------

pub fn ssml_puts_a_numbered_mark_after_each_word_and_escapes_test() {
  speech.ssml([
    Token("R&D", 3, False),
    Token("<ok>", 8, True),
    Token("です。", 11, False),
  ])
  |> should.equal(
    "<speak>R&amp;D<mark name=\"0\"/> &lt;ok&gt;<mark name=\"1\"/>です。<mark name=\"2\"/></speak>",
  )
}

// ---------------------------------------------------------------------------
// Voicer: which sentences get synthesised
// ---------------------------------------------------------------------------

fn plan(
  lang: String,
  max: Int,
  parts: List(String),
) -> #(speech.Voicer, List(speech.Job)) {
  let #(v, jobs) =
    list.fold(parts, #(speech.voicer(lang, max), []), fn(acc, part) {
      let #(v, jobs) = acc
      let #(v, new) = speech.voice_text(v, part)
      #(v, list.append(jobs, new))
    })
  let #(v, last) = speech.voice_finish(v)
  #(v, list.append(jobs, last))
}

pub fn voicer_numbers_spoken_sentences_and_skips_code_test() {
  let #(_, jobs) =
    plan("en", 1200, ["Intro.\n```\nlet x = 1. y\n```\n---\nOutro here."])
  jobs
  |> list.map(fn(j: speech.Job) { #(j.seq, j.text) })
  |> should.equal([#(0, "Intro."), #(1, "Outro here.")])
}

pub fn voicer_stops_at_the_character_cap_test() {
  // Spoken chars: "One two." = 7, "Three four." = 10 → cap 12 fits only one.
  let #(v, jobs) = plan("en", 12, ["One two. Three four. Five."])
  jobs |> list.map(fn(j: speech.Job) { j.text }) |> should.equal(["One two."])
  speech.stopped(v) |> should.be_true
  speech.planned(v) |> should.equal(1)
}

pub fn voicer_never_reads_the_contact_email_block_test() {
  let #(_, jobs) =
    plan("en", 1200, [
      "I will pass it on.\n[[SEND_EMAIL]]\n{\"name\": \"A. B.\"}\n[[/SEND_EMAIL]]",
    ])
  jobs
  |> list.map(fn(j: speech.Job) { j.text })
  |> should.equal(["I will pass it on."])
}

pub fn voicer_follows_the_reply_language_test() {
  let #(_, jobs) = plan("en", 1200, ["Hi. こんにちは。 Gleam です。"])
  jobs
  |> list.map(fn(j: speech.Job) { j.lang })
  |> should.equal(["en", "ja", "ja"])
  speech.detect_lang("en", "Merhaba, iyi günler") |> should.equal("en")
  speech.detect_lang("en", "Teşekkürler") |> should.equal("tr")
}
