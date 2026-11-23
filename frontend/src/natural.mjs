/*
 * natural.mjs: the natural English voice. Phonon (by Gradium, public/vendor/phonon-tts/) runs in
 * the visitor's browser, in a worker: no server takes part, and nothing that is said leaves the
 * page. It is an opt-in download (the model is about 67 MB, kept in the browser's cache), and it
 * speaks English only.
 *
 *   naturalWanted()                 the visitor's choice, localStorage "natural-voice" = "on"
 *   loadNatural(onProgress)         fetch (or read from cache) and start the model; resolves when
 *                                   it can speak. onProgress(0..100) follows the weights' download.
 *   naturalLoaded()                 the running model, or null
 *   dropNatural()                   forget the choice and free the model (the cache is kept)
 *   createNaturalSpeaker({...})     → {handle(event), stop()}, the same shape as voice.mjs's
 *                                   speaker: feed it every SSE event of a TEXT-ONLY reply.
 *
 * The speaker reads a reply sentence by sentence as its text streams in. A sentence appears when
 * its audio starts. Text never waits long for the voice: if a sentence's audio is not ready
 * LEAD_MS after the previous one ended, the sentence is shown and the voice follows.
 */
import { onVoiceChange, speechInput, speechLevel, unlockAudio } from "./voice.mjs";

const KEY = "natural-voice";
const ENGINE = "/vendor/phonon-tts/index.js";
// Preston: the lowest of the catalogue's male English voices (about 122 Hz, measured). The
// catalogue is pinned to a commit so the voice cannot change under us.
export const VOICE = "Preston";
const VOICE_URL =
  "https://huggingface.co/gradium/phonon-voices/resolve/0ee17205f254b5abc43b266c8a0f215565c352f7/voices/qIxlZ7Ei8KvWlyQH.safetensors";

const LEAD_MS = 2500; // how long text waits for a voice that is not ready
const MAX_CHARS = 1200; // spoken characters per reply; the rest is shown after the audio

export function naturalWanted() {
  try {
    return window.localStorage.getItem(KEY) === "on";
  } catch (_) {
    return false;
  }
}

function remember(on) {
  try {
    if (on) window.localStorage.setItem(KEY, "on");
    else window.localStorage.removeItem(KEY);
  } catch (_) {}
}

let model = null;
let loading = null;

export function naturalLoaded() {
  return model;
}

export function loadNatural(onProgress = () => {}) {
  remember(true);
  if (model) return Promise.resolve(model);
  if (loading) return loading;
  const attempt = (async () => {
    const { PhononTTS } = await import(/* @vite-ignore */ ENGINE);
    const tts = await PhononTTS.load({
      lang: "en",
      // The GPU where the browser offers one, the CPU otherwise.
      device: "auto",
      onProgress: ({ file, loaded, total }) => {
        if (file === "weights" && total) onProgress(Math.min(100, Math.round((loaded / total) * 100)));
      },
    });
    await tts.addVoice(VOICE, VOICE_URL);
    // Dropped while it was loading.
    if (loading !== attempt) {
      tts.dispose();
      throw new Error("The natural voice was turned off.");
    }
    model = tts;
    return tts;
  })();
  loading = attempt;
  attempt.catch(() => {
    if (loading === attempt) loading = null;
  });
  return attempt;
}

export function dropNatural() {
  remember(false);
  loading = null;
  if (model) model.dispose();
  model = null;
}

/* ---------------------------------------------------------------- text */

/**
 * Where the complete sentences of `raw` end, from offset `from` on: after . ! ? (and any closing
 * quote or bracket) followed by whitespace, or at a line break. A list number ("1.") or a single
 * letter does not end a sentence. With `final` the rest of the text is the last sentence.
 */
export function sentenceEnds(raw, from, final) {
  const ends = [];
  let start = from;
  for (let i = from; i < raw.length; i++) {
    const c = raw[i];
    let end = -1;
    if (c === "\n") end = i + 1;
    else if (c === "." || c === "!" || c === "?") {
      let j = i + 1;
      while (j < raw.length && /["')\]*_]/.test(raw[j])) j++;
      if (j < raw.length && /\s/.test(raw[j])) {
        const word = raw.slice(start, i).split(/\s/).pop();
        if (c !== "." || !(word.length <= 1 || /^\d+$/.test(word))) end = j;
      }
    }
    if (end > start) {
      if (raw.slice(start, end).trim()) ends.push(end);
      start = end;
      i = end - 1;
    }
  }
  if (final && raw.slice(start).trim()) ends.push(raw.length);
  return ends;
}

/** What to say for a piece of markdown: its words, without the markup, links as their labels. */
export function speakable(markdown) {
  return markdown
    .replace(/```[\s\S]*?(```|$)/g, " ")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, " ")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/https?:\/\/\S+/g, " ")
    .replace(/^\s{0,3}(#{1,6}|>|[-*+]|\d+[.)])\s+/gm, "")
    .replace(/[*_`~]+/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

/* ---------------------------------------------------------------- speaker */

export function createNaturalSpeaker({ tts, onReveal = () => {}, onLevel = () => {}, onEnd = () => {} }) {
  const ctx = unlockAudio();
  const input = ctx && speechInput();
  // No audio or no model: plain text, exactly like a muted client (said on the first event,
  // as voice.mjs's speaker does, so the caller has the speaker by then).
  const plain = !(tts && ctx && input);
  let on = true;
  let started = false;
  let raw = "";
  let cut = 0; // raw up to here has been cut into sentences
  let spoken = 0;
  let textDone = false;
  let shown = -1;
  let playEnd = 0;
  let wake = null;
  let frame = 0;
  let lastLevel = -1;
  const queue = [];
  const sources = new Set();
  const timers = new Set();
  const abort = new AbortController();
  const unsubscribe = onVoiceChange((enabled) => {
    if (!enabled) stop();
  });

  function reveal(n) {
    if (on && n > shown) {
      shown = n;
      onReveal(n);
    }
  }

  function later(ms, fn) {
    const id = setTimeout(() => {
      timers.delete(id);
      fn();
    }, Math.max(0, ms));
    timers.add(id);
    return id;
  }

  const sleep = (ms) => new Promise((resolve) => later(ms, resolve));
  const untilPlayed = () => sleep((playEnd - ctx.currentTime) * 1000);

  function finish({ silence }) {
    if (!on) return;
    reveal(Infinity);
    on = false;
    unsubscribe();
    abort.abort();
    for (const id of timers) clearTimeout(id);
    if (frame) cancelAnimationFrame(frame);
    if (silence) for (const s of sources) { try { s.stop(); } catch (_) {} }
    if (lastLevel !== 0) onLevel(0);
    if (wake) wake();
    onEnd();
  }

  function stop() {
    finish({ silence: true });
  }

  function play(pcm) {
    const buffer = ctx.createBuffer(1, pcm.length, tts.sampleRate);
    buffer.getChannelData(0).set(pcm);
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.connect(input);
    const t0 = Math.max(ctx.currentTime + 0.03, playEnd);
    source.start(t0);
    sources.add(source);
    source.onended = () => sources.delete(source);
    playEnd = t0 + buffer.duration;
    return t0;
  }

  function meter() {
    if (!on) return;
    const l = ctx.currentTime < playEnd ? speechLevel() : 0;
    if (l !== lastLevel) {
      lastLevel = l;
      onLevel(l);
    }
    frame = requestAnimationFrame(meter);
  }

  // One sentence after another: wait for its audio, play it after the one before, show it as
  // it starts. A sentence with nothing to say (a code block, text past the cap) is shown when
  // the audio before it has played.
  async function run() {
    while (on) {
      const item = queue.shift();
      if (!item) {
        if (textDone) break;
        await new Promise((resolve) => { wake = resolve; });
        wake = null;
        continue;
      }
      if (!item.pcm) {
        await untilPlayed();
        reveal(item.end);
        continue;
      }
      // Text does not wait long for a voice that is not ready.
      // (The audio clock may have run for a long time before this reply: never a negative wait.)
      later(Math.max(0, playEnd - ctx.currentTime) * 1000 + LEAD_MS, () => reveal(item.end));
      let pcm = null;
      try {
        pcm = await item.pcm;
      } catch (_) {}
      if (!on) return;
      if (pcm && pcm.length) {
        const t0 = play(pcm);
        later((t0 - ctx.currentTime) * 1000, () => reveal(item.end));
      } else {
        await untilPlayed();
        reveal(item.end);
      }
    }
    if (!on) return;
    await untilPlayed();
    finish({ silence: false });
  }

  function cutSentences(final) {
    for (const end of sentenceEnds(raw, cut, final)) {
      const text = speakable(raw.slice(cut, end));
      const say = text && spoken < MAX_CHARS;
      if (say) spoken += text.length;
      const pcm = say ? tts.synth(text, { voice: VOICE, signal: abort.signal }) : null;
      // A sentence that is dropped before it is awaited must not report an unhandled rejection.
      if (pcm) pcm.catch(() => {});
      queue.push({ end, pcm });
      cut = end;
    }
    if (wake) wake();
  }

  function handle(e) {
    if (!e || !on) return;
    if (plain) return finish({ silence: false });
    // The caller is told "nothing shown yet" only once the reply has begun: the app starts
    // following a voice after `thinking` (voice.mjs's speaker does it on the `voice` event).
    if (e.type === "thinking") return;
    if (!started) {
      started = true;
      reveal(0);
      frame = requestAnimationFrame(meter);
      run();
    }
    if (e.type === "chunk" && typeof e.text === "string") {
      raw += e.text;
      cutSentences(false);
    } else if (e.type === "done") {
      textDone = true;
      cutSentences(true);
    } else if (e.type === "error") {
      stop();
    }
  }

  return { handle, stop };
}
