//// Speech planning for voiced replies (pure; no I/O).
////
//// As Gemini's text streams in, the reply is cut into sentences, each
//// sentence is stripped of markdown into speakable words, and every word gets
//// an SSML `<mark/>` so the TTS can report when it was spoken. Every word keeps
//// the offset where it ends in the RAW reply text, in UTF-16 code units (what
//// JavaScript's `raw.slice(0, n)` counts), so a client can reveal the raw text
//// in step with the audio.
////
//// Sentence ends: `.`, `!`, `?` (or `…`) followed by whitespace; `。！？`;
//// newlines (list items, headings); or a clause cap for very long runs.
////
//// Japanese is marked at punctuation and at the end of each kana run (where a
//// particle or okurigana meets the next word) rather than every few
//// characters: a mark inside a word makes the voice pause there (measured on
//// ja-JP-Standard-C: +17% duration), while marks at those boundaries cost
//// nothing.

import gleam/int
import gleam/list
import gleam/string

// ---------------------------------------------------------------------------
// Characters with offsets
// ---------------------------------------------------------------------------

/// One code point of the raw reply, with its UTF-16 offset and width.
pub type Ch {
  Ch(cp: UtfCodepoint, code: Int, off: Int, w: Int)
}

fn chars_from(text: String, off: Int) -> #(List(Ch), Int) {
  let #(rev, next) =
    text
    |> string.to_utf_codepoints
    |> list.fold(#([], off), fn(acc, cp) {
      let #(rev, off) = acc
      let code = string.utf_codepoint_to_int(cp)
      let w = case code > 0xFFFF {
        True -> 2
        False -> 1
      }
      #([Ch(cp:, code:, off:, w:), ..rev], off + w)
    })
  #(list.reverse(rev), next)
}

fn text_of(chars: List(Ch)) -> String {
  chars |> list.map(fn(c) { c.cp }) |> string.from_utf_codepoints
}

fn is_space(code: Int) -> Bool {
  code == 32
  || code == 9
  || code == 10
  || code == 13
  || code == 0xA0
  || code == 0x3000
}

/// UTF-16 length of a string, i.e. JavaScript's `s.length`.
pub fn utf16_length(text: String) -> Int {
  chars_from(text, 0).1
}

// ---------------------------------------------------------------------------
// Sentence splitter (incremental)
// ---------------------------------------------------------------------------

/// A sentence of the raw reply: `raw[start..end)`, whitespace-trimmed.
pub type Segment {
  Segment(start: Int, end: Int, text: String, chars: List(Ch))
}

/// Carries the not-yet-complete tail of the reply between chunks.
pub opaque type Splitter {
  Splitter(pending: List(Ch), next_off: Int)
}

/// Clauses longer than this (UTF-16 units) are cut at a comma or space.
const clause_cap = 220

pub fn new_splitter() -> Splitter {
  Splitter(pending: [], next_off: 0)
}

/// Add streamed text; returns the sentences it completed.
pub fn feed(splitter: Splitter, text: String) -> #(Splitter, List(Segment)) {
  let #(new, next_off) = chars_from(text, splitter.next_off)
  let #(segments, rest) =
    scan(list.append(splitter.pending, new), [], 0, [], False)
  #(Splitter(pending: rest, next_off:), segments)
}

/// The reply is complete: return whatever is left as a final sentence.
pub fn finish(splitter: Splitter) -> List(Segment) {
  scan(splitter.pending, [], 0, [], True).0
}

/// Scan `input`; `cur` is the current sentence (reversed) and `len` its UTF-16
/// length. Returns completed segments and the chars to keep pending.
fn scan(
  input: List(Ch),
  cur: List(Ch),
  len: Int,
  acc: List(Segment),
  final: Bool,
) -> #(List(Segment), List(Ch)) {
  case input {
    [] ->
      case final {
        True -> #(list.reverse(push(acc, cur)), [])
        False -> #(list.reverse(acc), list.reverse(cur))
      }
    [c, ..rest] ->
      case c.code {
        10 -> scan(rest, [], 0, push(acc, cur), final)
        // 。！？ end a sentence outright (plus any closing quote/bracket).
        0x3002 | 0xFF01 | 0xFF1F -> {
          let #(closers, rest) = take_closers(rest, [])
          scan(rest, [], 0, push(acc, list.append(closers, [c, ..cur])), final)
        }
        0x2E | 0x21 | 0x3F | 0x2026 -> {
          let #(closers, after) = take_closers(rest, [])
          let ended = list.append(closers, [c, ..cur])
          case after {
            // Can't tell yet whether whitespace follows: wait for more text.
            [] if !final -> #(list.reverse(acc), list.reverse(ended))
            [] -> scan([], ended, 0, acc, final)
            [n, ..] ->
              case is_space(n.code) && !is_false_stop(cur, c.code) {
                True -> scan(after, [], 0, push(acc, ended), final)
                False -> scan(after, ended, len + width(ended, cur), acc, final)
              }
          }
        }
        _ -> {
          let cur = [c, ..cur]
          let len = len + c.w
          case len >= clause_cap {
            False -> scan(rest, cur, len, acc, final)
            True -> {
              let #(head, tail) = soft_cut(cur)
              scan(rest, tail, rev_len(tail), push(acc, head), final)
            }
          }
        }
      }
  }
}

fn width(ended: List(Ch), before: List(Ch)) -> Int {
  rev_len(ended) - rev_len(before)
}

fn rev_len(chars: List(Ch)) -> Int {
  list.fold(chars, 0, fn(n, c) { n + c.w })
}

/// Closing markup/quotes that belong to the sentence before the whitespace.
fn take_closers(input: List(Ch), acc: List(Ch)) -> #(List(Ch), List(Ch)) {
  case input {
    [c, ..rest] ->
      case c.code {
        0x2A
        | 0x5F
        | 0x29
        | 0x22
        | 0x27
        | 0x201D
        | 0x2019
        | 0x300D
        | 0x300F
        | 0xFF09 -> take_closers(rest, [c, ..acc])
        _ -> #(acc, input)
      }
    [] -> #(acc, input)
  }
}

/// A `.` after a list number ("1. ") or a common abbreviation is not a stop.
fn is_false_stop(cur_rev: List(Ch), punct: Int) -> Bool {
  case punct {
    0x2E -> {
      let word =
        cur_rev
        |> list.take_while(fn(c) { !is_space(c.code) })
        |> list.reverse
        |> text_of
        |> string.lowercase
      let whole = cur_rev |> list.reverse |> text_of |> string.trim
      is_digits(whole)
      || string.length(word) == 1
      || list.contains(
        ["e.g", "i.e", "vs", "mr", "mrs", "ms", "dr", "st", "jr"],
        word,
      )
    }
    _ -> False
  }
}

fn is_digits(s: String) -> Bool {
  s != "" && string.length(s) <= 3 && result_is_ok(int.parse(s))
}

fn result_is_ok(r: Result(a, b)) -> Bool {
  case r {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Cut an over-long clause (reversed) after its last comma, semicolon, 、 or
/// space, keeping at least a third of the cap in the head. Returns the head
/// (reversed) and the carried-over tail (reversed).
fn soft_cut(cur: List(Ch)) -> #(List(Ch), List(Ch)) {
  let tail = list.take_while(cur, fn(c) { !is_soft_break(c.code) })
  let head = list.drop(cur, list.length(tail))
  case rev_len(head) >= clause_cap / 3 {
    True -> #(head, tail)
    False -> #(cur, [])
  }
}

fn is_soft_break(code: Int) -> Bool {
  code == 0x2C || code == 0x3B || code == 0x3001 || code == 0xFF0C || code == 32
}

/// Close the current sentence (reversed) unless it is only whitespace.
fn push(acc: List(Segment), cur_rev: List(Ch)) -> List(Segment) {
  let chars =
    cur_rev
    |> list.drop_while(fn(c) { is_space(c.code) })
    |> list.reverse
    |> list.drop_while(fn(c) { is_space(c.code) })
  case chars, list.last(chars) {
    [first, ..], Ok(last) -> [
      Segment(
        start: first.off,
        end: last.off + last.w,
        text: text_of(chars),
        chars:,
      ),
      ..acc
    ]
    _, _ -> acc
  }
}

// ---------------------------------------------------------------------------
// Markdown -> speakable words
// ---------------------------------------------------------------------------

/// A speakable word (or Japanese phrase). `end` is the raw offset where it
/// ends, extended over closing markup (`**`, `)` of a link) so revealing up
/// to it never leaves half a markdown construct on screen.
pub type Token {
  Token(text: String, end: Int, space_before: Bool)
}

/// A kept character: `code` 32 stands for any separator.
type Kept {
  Kept(cp: UtfCodepoint, code: Int, end: Int)
}

/// Strip markdown from a sentence and split it into words, each with the raw
/// offset where it ends. Unspeakable tokens (pure punctuation) are dropped.
pub fn tokens(chars: List(Ch)) -> List(Token) {
  chars
  |> strip_block_prefix
  |> inline([])
  |> list.reverse
  |> tokenize([], False, False, [])
  |> list.filter(fn(t) { is_speakable(t.text) })
}

/// Drop leading `#`, `>`, list bullets and `1.` / `1)` markers.
fn strip_block_prefix(chars: List(Ch)) -> List(Ch) {
  let chars = list.drop_while(chars, fn(c) { is_space(c.code) })
  case chars {
    [c, ..rest] if c.code == 0x23 -> {
      let rest = list.drop_while(rest, fn(c) { c.code == 0x23 })
      case rest {
        [s, ..more] if s.code == 32 -> strip_block_prefix(more)
        _ -> chars
      }
    }
    [c, ..rest] if c.code == 0x3E -> strip_block_prefix(rest)
    [c, s, ..rest]
      if { c.code == 0x2D || c.code == 0x2A || c.code == 0x2B } && s.code == 32
    -> strip_block_prefix(rest)
    _ -> {
      let digits =
        list.take_while(chars, fn(c) { c.code >= 0x30 && c.code <= 0x39 })
      let n = list.length(digits)
      case n > 0 && n <= 3, list.drop(chars, n) {
        True, [p, s, ..rest]
          if { p.code == 0x2E || p.code == 0x29 } && s.code == 32
        -> strip_block_prefix(rest)
        _, _ -> chars
      }
    }
  }
}

/// Inline markdown pass. `acc` is reversed.
fn inline(chars: List(Ch), acc: List(Kept)) -> List(Kept) {
  case chars {
    [] -> acc
    [c, ..rest] ->
      case c.code {
        // Backslash escape: keep the escaped char.
        0x5C ->
          case rest {
            [n, ..more] -> inline(more, keep(acc, n))
            [] -> acc
          }
        // Emphasis / code / strikethrough markers are silent.
        0x2A | 0x60 | 0x7E -> inline(rest, close_over(acc, c))
        // `_` is emphasis at a word edge, part of the word inside one.
        0x5F ->
          case at_word_start(acc) || at_word_end(rest) {
            True -> inline(rest, close_over(acc, c))
            False -> inline(rest, keep(acc, c))
          }
        0x5B ->
          case parse_link(rest) {
            Ok(#(label, close, more)) -> {
              let acc = inline(label, acc)
              inline(more, extend_last(acc, close.off + close.w))
            }
            Error(_) -> inline(rest, close_over(acc, c))
          }
        0x5D -> inline(rest, close_over(acc, c))
        0x7C -> inline(rest, [Kept(c.cp, 32, c.off + c.w), ..acc])
        0x68 ->
          case at_word_start(acc), take_url(chars) {
            True, Ok(#(host, url_end, more)) ->
              inline(more, speak_host(host, url_end, acc))
            _, _ -> inline(rest, keep(acc, c))
          }
        _ -> inline(rest, keep(acc, c))
      }
  }
}

fn keep(acc: List(Kept), c: Ch) -> List(Kept) {
  let code = case is_space(c.code) {
    True -> 32
    False -> c.code
  }
  [Kept(c.cp, code, c.off + c.w), ..acc]
}

/// Silent markup right after a word (e.g. closing `**`) extends that word, so
/// its reveal offset includes the markup.
fn close_over(acc: List(Kept), c: Ch) -> List(Kept) {
  case acc {
    [k, ..] if k.code != 32 -> extend_last(acc, c.off + c.w)
    _ -> acc
  }
}

fn extend_last(acc: List(Kept), end: Int) -> List(Kept) {
  case acc {
    [k, ..rest] -> [Kept(..k, end: int.max(k.end, end)), ..rest]
    [] -> acc
  }
}

fn at_word_start(acc: List(Kept)) -> Bool {
  case acc {
    [] -> True
    [k, ..] -> k.code == 32
  }
}

fn at_word_end(rest: List(Ch)) -> Bool {
  case rest {
    [] -> True
    [n, ..] -> is_space(n.code) || is_ascii_punct(n.code)
  }
}

fn is_ascii_punct(code: Int) -> Bool {
  { code >= 0x21 && code <= 0x2F }
  || { code >= 0x3A && code <= 0x40 }
  || { code >= 0x5B && code <= 0x60 }
  || { code >= 0x7B && code <= 0x7E }
}

/// After `[`: `label](url)` → label chars, the `)` char, and what follows.
fn parse_link(rest: List(Ch)) -> Result(#(List(Ch), Ch, List(Ch)), Nil) {
  let label = list.take_while(rest, fn(c) { c.code != 0x5D && c.code != 0x5B })
  case list.drop(rest, list.length(label)) {
    [close_bracket, open, ..more]
      if close_bracket.code == 0x5D && open.code == 0x28
    -> {
      let url = list.take_while(more, fn(c) { c.code != 0x29 && c.code != 10 })
      case list.drop(more, list.length(url)) {
        [close, ..after] if close.code == 0x29 -> Ok(#(label, close, after))
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// A bare `http(s)://` URL at `chars`: its host (without `www.`), the raw
/// offset where the URL ends, and the rest. Trailing punctuation stays out.
fn take_url(chars: List(Ch)) -> Result(#(List(Ch), Int, List(Ch)), Nil) {
  let prefix = chars |> list.take(8) |> text_of
  let scheme = case string.starts_with(prefix, "https://") {
    True -> Ok(8)
    False ->
      case string.starts_with(prefix, "http://") {
        True -> Ok(7)
        False -> Error(Nil)
      }
  }
  case scheme {
    Error(_) -> Error(Nil)
    Ok(n) -> {
      let url =
        chars
        |> list.take_while(fn(c) { !is_space(c.code) && c.code != 0x29 })
        |> list.reverse
        |> list.drop_while(fn(c) { is_trailing_url_punct(c.code) })
        |> list.reverse
      let rest = list.drop(chars, list.length(url))
      let host =
        url
        |> list.drop(n)
        |> list.take_while(fn(c) {
          c.code != 0x2F && c.code != 0x3F && c.code != 0x23 && c.code != 0x3A
        })
      let host = case text_of(list.take(host, 4)) {
        "www." -> list.drop(host, 4)
        _ -> host
      }
      case list.last(url) {
        Ok(last) if host != [] -> Ok(#(host, last.off + last.w, rest))
        _ -> Error(Nil)
      }
    }
  }
}

fn is_trailing_url_punct(code: Int) -> Bool {
  code == 0x2E
  || code == 0x2C
  || code == 0x3B
  || code == 0x3A
  || code == 0x21
  || code == 0x3F
}

fn speak_host(host: List(Ch), url_end: Int, acc: List(Kept)) -> List(Kept) {
  list.fold(host, acc, fn(acc, c) { [Kept(c.cp, c.code, url_end), ..acc] })
}

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

type Script {
  Kana
  Katakana
  Han
  OpenPunct
  ClosePunct
  Other
}

fn script(code: Int) -> Script {
  case code {
    _ if code >= 0x3041 && code <= 0x309F -> Kana
    // ー continues whatever it follows; treat as katakana (most common).
    _ if code >= 0x30A0 && code <= 0x30FF -> Katakana
    _ if code >= 0x31F0 && code <= 0x31FF -> Katakana
    _ if code >= 0xFF66 && code <= 0xFF9F -> Katakana
    _ if code >= 0x4E00 && code <= 0x9FFF -> Han
    _ if code >= 0x3400 && code <= 0x4DBF -> Han
    0x3005 -> Han
    0x300C | 0x300E | 0xFF08 | 0x3010 -> OpenPunct
    0x3001
    | 0x3002
    | 0xFF01
    | 0xFF1F
    | 0x300D
    | 0x300F
    | 0xFF09
    | 0x3011
    | 0xFF0C
    | 0xFF1A
    | 0x30FB -> ClosePunct
    _ -> Other
  }
}

/// Where a mark may go between two adjacent characters: after a kana run
/// (a particle or okurigana) meets kanji or katakana, and before an opening
/// bracket. Never inside a kanji or katakana word.
fn breaks(prev: Int, next: Int) -> Bool {
  let p = script(prev)
  let s = script(next)
  s == OpenPunct || { p == Kana && { s == Han || s == Katakana } }
}

/// `cur` is the current token (reversed); `cur_space` whether whitespace
/// preceded it; `gap` whether whitespace was seen since the last token.
fn tokenize(
  kept: List(Kept),
  cur: List(Kept),
  cur_space: Bool,
  gap: Bool,
  acc: List(Token),
) -> List(Token) {
  case kept {
    [] -> list.reverse(flush(acc, cur, cur_space))
    [k, ..rest] if k.code == 32 ->
      tokenize(rest, [], False, True, flush(acc, cur, cur_space))
    [k, ..rest] -> {
      let #(acc, cur, cur_space) = case cur {
        [] -> #(acc, [k], gap)
        [prev, ..] ->
          case breaks(prev.code, k.code) {
            True -> #(flush(acc, cur, cur_space), [k], False)
            False -> #(acc, [k, ..cur], cur_space)
          }
      }
      case script(k.code) {
        // 、。！？」 end a phrase: the mark goes right after them.
        ClosePunct ->
          tokenize(rest, [], False, False, flush(acc, cur, cur_space))
        _ -> tokenize(rest, cur, cur_space, False, acc)
      }
    }
  }
}

fn flush(acc: List(Token), cur: List(Kept), space: Bool) -> List(Token) {
  case cur {
    [] -> acc
    [last, ..] -> {
      let text =
        cur
        |> list.reverse
        |> list.map(fn(k) { k.cp })
        |> string.from_utf_codepoints
      [Token(text:, end: last.end, space_before: space && acc != []), ..acc]
    }
  }
}

/// Has at least one letter, digit or CJK character (not just punctuation,
/// symbols or emoji).
fn is_speakable(text: String) -> Bool {
  text
  |> string.to_utf_codepoints
  |> list.any(fn(cp) {
    let c = string.utf_codepoint_to_int(cp)
    { c >= 0x30 && c <= 0x39 }
    || { c >= 0x41 && c <= 0x5A }
    || { c >= 0x61 && c <= 0x7A }
    || { c >= 0xC0 && c < 0x2000 && c != 0xD7 && c != 0xF7 }
    || { c >= 0x3041 && c <= 0x30FF && c != 0x30FB }
    || { c >= 0x3400 && c <= 0x9FFF }
    || c == 0x3005
    || { c >= 0xAC00 && c <= 0xD7AF }
    || { c >= 0xFF10 && c <= 0xFF19 }
    || { c >= 0xFF21 && c <= 0xFF3A }
    || { c >= 0xFF41 && c <= 0xFF5A }
    || { c >= 0xFF66 && c <= 0xFF9F }
  })
}

// ---------------------------------------------------------------------------
// SSML
// ---------------------------------------------------------------------------

/// `<speak>word<mark name="0"/> word<mark name="1"/>…</speak>`: mark N sits
/// right after token N.
pub fn ssml(tokens: List(Token)) -> String {
  let body =
    tokens
    |> list.index_map(fn(t, i) {
      let sep = case t.space_before {
        True -> " "
        False -> ""
      }
      sep <> xml_escape(t.text) <> "<mark name=\"" <> int.to_string(i) <> "\"/>"
    })
    |> string.concat
  "<speak>" <> body <> "</speak>"
}

/// The same words as plain text (no marks), for voices that reject SSML marks.
pub fn plain(tokens: List(Token)) -> String {
  tokens
  |> list.map(fn(t) {
    case t.space_before {
      True -> " " <> t.text
      False -> t.text
    }
  })
  |> string.concat
}

fn xml_escape(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&apos;")
}

// ---------------------------------------------------------------------------
// Voicer: the reply-level plan (which sentences to synthesise, in what order)
// ---------------------------------------------------------------------------

/// One sentence to synthesise. `tokens` map mark N to `tokens[N].end`.
pub type Job {
  Job(
    seq: Int,
    start: Int,
    end: Int,
    lang: String,
    ssml: String,
    text: String,
    tokens: List(Token),
  )
}

pub opaque type Voicer {
  Voicer(
    splitter: Splitter,
    lang: String,
    in_fence: Bool,
    voiced: Int,
    max_chars: Int,
    max_chars_ja: Int,
    next_seq: Int,
    stopped: Bool,
  )
}

/// `lang` is "en", "ja" or "tr" (anything else is English). `max_chars` caps
/// the spoken characters per reply.
pub fn voicer(lang: String, max_chars: Int) -> Voicer {
  voicer_capped(lang, max_chars, max_chars)
}

/// Like `voicer`, with a separate cap once the reply turns out to be Japanese.
pub fn voicer_capped(lang: String, max_chars: Int, max_chars_ja: Int) -> Voicer {
  Voicer(
    splitter: new_splitter(),
    lang: normalise_lang(lang),
    in_fence: False,
    voiced: 0,
    max_chars:,
    max_chars_ja:,
    next_seq: 0,
    stopped: False,
  )
}

pub fn normalise_lang(lang: String) -> String {
  case string.lowercase(lang) {
    "ja" | "jp" -> "ja"
    "tr" -> "tr"
    _ -> "en"
  }
}

/// Feed streamed reply text; returns the jobs for the sentences it completed.
pub fn voice_text(v: Voicer, text: String) -> #(Voicer, List(Job)) {
  case v.stopped {
    True -> #(v, [])
    False -> {
      let #(splitter, segments) = feed(v.splitter, text)
      plan(Voicer(..v, splitter:), segments, [])
    }
  }
}

/// The reply text is complete; plan its last sentence.
pub fn voice_finish(v: Voicer) -> #(Voicer, List(Job)) {
  case v.stopped {
    True -> #(v, [])
    False -> {
      let segments = finish(v.splitter)
      let #(v, jobs) = plan(Voicer(..v, splitter: new_splitter()), segments, [])
      #(Voicer(..v, stopped: True), jobs)
    }
  }
}

/// How many jobs have been planned (their seqs are 0..n-1).
pub fn planned(v: Voicer) -> Int {
  v.next_seq
}

/// True once no more jobs will be planned (finished, capped, or hit the
/// contact-email block).
pub fn stopped(v: Voicer) -> Bool {
  v.stopped
}

fn plan(
  v: Voicer,
  segments: List(Segment),
  acc: List(Job),
) -> #(Voicer, List(Job)) {
  case segments {
    [] -> #(v, list.reverse(acc))
    _ if v.stopped -> #(v, list.reverse(acc))
    [seg, ..rest] ->
      case string.starts_with(seg.text, "```"), v.in_fence {
        // Code fences toggle; code is never read out.
        True, _ -> plan(Voicer(..v, in_fence: !v.in_fence), rest, acc)
        False, True -> plan(v, rest, acc)
        False, False ->
          // The [[SEND_EMAIL]] block is machine-readable: stop voicing.
          case string.contains(seg.text, "[[") {
            True -> #(Voicer(..v, stopped: True), list.reverse(acc))
            False -> {
              let toks = tokens(seg.chars)
              let spoken =
                list.fold(toks, 0, fn(n, t) { n + string.length(t.text) })
              let lang = detect_lang(v.lang, seg.text)
              let cap = case lang {
                "ja" -> v.max_chars_ja
                _ -> v.max_chars
              }
              case toks {
                [] -> plan(v, rest, acc)
                _ if v.voiced + spoken > cap -> #(
                  Voicer(..v, stopped: True),
                  list.reverse(acc),
                )
                _ -> {
                  let job =
                    Job(
                      seq: v.next_seq,
                      start: seg.start,
                      end: seg.end,
                      lang:,
                      ssml: ssml(toks),
                      text: plain(toks),
                      tokens: toks,
                    )
                  plan(
                    Voicer(
                      ..v,
                      lang:,
                      voiced: v.voiced + spoken,
                      next_seq: v.next_seq + 1,
                    ),
                    rest,
                    [job, ..acc],
                  )
                }
              }
            }
          }
      }
  }
}

/// The UI language picks the voice, but a reply in another language switches
/// it for the rest of the reply: any kana/kanji means Japanese, and ş/ğ/ı/İ
/// mean Turkish (English is never inferred, it has no tell-tale letters).
pub fn detect_lang(current: String, text: String) -> String {
  let codes =
    text |> string.to_utf_codepoints |> list.map(string.utf_codepoint_to_int)
  case
    list.any(codes, fn(c) {
      let s = script(c)
      s == Kana || s == Katakana || s == Han
    })
  {
    True -> "ja"
    False ->
      case
        list.any(codes, fn(c) {
          c == 0x15F
          || c == 0x15E
          || c == 0x11F
          || c == 0x11E
          || c == 0x131
          || c == 0x130
        })
      {
        True -> "tr"
        False -> current
      }
  }
}
