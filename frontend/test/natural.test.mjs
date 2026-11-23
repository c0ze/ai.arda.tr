import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createNaturalSpeaker, sentenceEnds, speakable } from '../build/dev/javascript/frontend/natural.mjs';

// The natural voice reads a reply sentence by sentence while its text is still
// streaming in, so the cut must only ever return sentences that are complete.
// A sentence ends after its end mark, before the space that follows.
test('a sentence is cut when it is complete: an end mark and a space, or a line break', () => {
  const raw = 'Arda lives in Tokyo. He builds';
  assert.deepEqual(sentenceEnds(raw, 0, false), [20]);
  assert.deepEqual(sentenceEnds(raw, 20, false), [], 'the rest may still grow');
  assert.deepEqual(sentenceEnds(raw, 20, true), [raw.length], 'the reply is over: the rest is a sentence');
  assert.deepEqual(sentenceEnds('Really? Yes!\nNext', 0, false), [7, 12]);
  assert.deepEqual(sentenceEnds('He said "stop." Then left. ', 0, false), [15, 26]);
});

// "1. Go" and "e.g. Go" are not two sentences: the voice would read "one." alone.
test('a list number or a single letter does not end a sentence', () => {
  assert.deepEqual(sentenceEnds('1. Go and Ruby. ', 0, false), [15]);
  assert.deepEqual(sentenceEnds('Plan B. is fine. ', 0, false), [16]);
});

// The voice says the words, never the markup, and a link by its label.
test('markdown is spoken as its words', () => {
  assert.equal(speakable('**Arda** wrote [tincan](https://github.com/c0ze/tincan) in `Go`.'), 'Arda wrote tincan in Go.');
  assert.equal(speakable('## Skills\n- Go\n- Ruby'), 'Skills Go Ruby');
  assert.equal(speakable('```go\nfmt.Println("x")\n```'), '');
  assert.equal(speakable('See https://arda.tr for more.'), 'See for more.');
});

// A fake audio clock and model: `advance(seconds)` moves the clock and runs due timers.
// voice.mjs keeps one AudioContext for the page, so the tests share one too. Its clock starts
// late, as a real one has when a visitor asks their second question.
let now = 600;
const ctx = (() => {
  return {
    get currentTime() { return now; },
    state: 'running',
    sampleRate: 24000,
    destination: {},
    resume: async () => {},
    createGain: () => ({ gain: { value: 1 }, connect: (n) => n }),
    createAnalyser: () => ({ fftSize: 1024, connect: (n) => n, getFloatTimeDomainData() {} }),
    createBuffer: (_c, length, rate) => ({ duration: length / rate, getChannelData: () => ({ set() {} }) }),
    createBufferSource: () => ({ connect() {}, start() {}, stop() {} }),
  };
})();

function stage(t, { synthMs = 0 } = {}) {
  const timers = [];
  const store = new Map();
  globalThis.window = {
    AudioContext: function () { return ctx; },
    localStorage: { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v), removeItem: (k) => store.delete(k) },
  };
  const realSetTimeout = globalThis.setTimeout, realClear = globalThis.clearTimeout;
  globalThis.setTimeout = (fn, ms = 0) => { const id = { at: now + ms / 1000, fn }; timers.push(id); return id; };
  globalThis.clearTimeout = (id) => { const i = timers.indexOf(id); if (i >= 0) timers.splice(i, 1); };
  globalThis.requestAnimationFrame = () => 0;
  globalThis.cancelAnimationFrame = () => {};
  t.after(() => {
    globalThis.setTimeout = realSetTimeout;
    globalThis.clearTimeout = realClear;
    delete globalThis.window;
    delete globalThis.requestAnimationFrame;
    delete globalThis.cancelAnimationFrame;
  });
  const said = [];
  const tts = {
    sampleRate: 24000,
    // one second of audio per sentence, ready after `synthMs`
    synth: (text) => { said.push(text); return new Promise((resolve) => globalThis.setTimeout(() => resolve(new Float32Array(24000)), synthMs)); },
  };
  const settle = () => new Promise((resolve) => realSetTimeout(resolve, 0));
  async function advance(seconds) {
    const target = now + seconds;
    for (;;) {
      await settle();
      timers.sort((a, b) => a.at - b.at);
      if (!timers.length || timers[0].at > target) break;
      const next = timers.shift();
      now = next.at;
      next.fn();
    }
    now = target;
    await settle();
  }
  return { tts, said, advance };
}

// The reply appears as it is spoken: a sentence is shown when its audio starts,
// and the whole reply once the voice has finished.
test('each sentence is shown as its audio starts, and everything at the end', async (t) => {
  const { tts, said, advance } = stage(t);
  const shown = [];
  let ended = 0;
  const s = createNaturalSpeaker({ tts, onReveal: (n) => shown.push(n), onEnd: () => ended++ });
  // The app follows a voice only after `thinking`, so it is told nothing before the reply begins.
  s.handle({ type: 'thinking' });
  assert.deepEqual(shown, []);
  s.handle({ type: 'chunk', text: 'One sentence. ' });
  assert.deepEqual(shown, [0], 'nothing shows before the voice starts');
  s.handle({ type: 'chunk', text: 'And a second one.' });
  await advance(0.1);
  assert.deepEqual(said, ['One sentence.']);
  assert.deepEqual(shown, [0, 13]);
  s.handle({ type: 'done', text: 'One sentence. And a second one.' });
  await advance(0.5);
  assert.deepEqual(shown, [0, 13], 'the second waits for the first to finish playing');
  await advance(0.6);
  assert.deepEqual(shown, [0, 13, 31]);
  assert.equal(ended, 0, 'still speaking');
  await advance(1.2);
  assert.deepEqual(shown.at(-1), Infinity);
  assert.equal(ended, 1);
});

// On a slow device the model falls behind. Reading must not wait for it: the
// sentence is shown after a short lead and the voice follows.
test('text does not wait long for a voice that is not ready', async (t) => {
  const { tts, advance } = stage(t, { synthMs: 9000 });
  const shown = [];
  const s = createNaturalSpeaker({ tts, onReveal: (n) => shown.push(n) });
  s.handle({ type: 'chunk', text: 'A slow sentence. ' });
  await advance(2);
  assert.deepEqual(shown, [0]);
  await advance(1);
  assert.deepEqual(shown, [0, 16], 'shown after the lead, before its audio exists');
});

// A new question, a language switch or the mute button: silence at once, and
// the reply is not left half shown.
test('stopping reveals everything and ends once', async (t) => {
  const { tts, advance } = stage(t);
  const shown = [];
  let ended = 0;
  const s = createNaturalSpeaker({ tts, onReveal: (n) => shown.push(n), onEnd: () => ended++ });
  s.handle({ type: 'chunk', text: 'First. Second. ' });
  await advance(0.1);
  s.stop();
  s.stop();
  s.handle({ type: 'chunk', text: 'Third. ' });
  assert.equal(shown.at(-1), Infinity);
  assert.equal(ended, 1);
});

// Without a model (or without Web Audio) it behaves like a muted client.
test('with no model the reply is plain text', (t) => {
  stage(t);
  const shown = [];
  let ended = 0;
  const s = createNaturalSpeaker({ tts: null, onReveal: (n) => shown.push(n), onEnd: () => ended++ });
  assert.deepEqual(shown, []);
  s.handle({ type: 'thinking' });
  assert.deepEqual(shown, [Infinity]);
  assert.equal(ended, 1);
});
