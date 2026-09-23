import assert from 'node:assert/strict';
import { test } from 'node:test';
import { stream_chat, reveal_prefix } from '../build/dev/javascript/frontend/ffi.mjs';
import { createSpeaker, requestFields, setVoiceEnabled, voiceEnabled } from '../build/dev/javascript/frontend/voice.mjs';

async function collect(t, chunks, { delayed = false } = {}) {
  const events = [];
  const encoded = chunks.map((chunk) => new TextEncoder().encode(chunk));
  t.mock.method(globalThis, 'fetch', async () => new Response(new ReadableStream({
    async start(controller) {
      for (const chunk of encoded) {
        if (delayed) await new Promise((resolve) => setImmediate(resolve));
        controller.enqueue(chunk);
      }
      controller.close();
    },
  })));
  await new Promise((resolve) => {
    stream_chat('https://example.test/chat', '{}', (raw) => {
      const event = JSON.parse(raw);
      events.push(event);
      if (event.type === 'done' || event.type === 'error') resolve();
    });
  });
  return events;
}

test('forwards complete LF events in order', async (t) => {
  assert.deepEqual(await collect(t, [
    'data: {"type":"thinking"}\n\n',
    'data: {"type":"chunk","text":"hello"}\n\n',
    'data: {"type":"done","text":"hello"}\n\n',
  ]), [{ type: 'thinking' }, { type: 'chunk', text: 'hello' }, { type: 'done', text: 'hello' }]);
});

test('accepts CRLF framing and data fields without a space', async (t) => {
  assert.deepEqual(await collect(t, ['data:{"type":"done","text":"hello"}\r', '\n\r\n']),
    [{ type: 'done', text: 'hello' }]);
});

test('truncated streams report an error so the composer can leave its busy state', async (t) => {
  const events = await collect(t, ['data: {"type":"thinking"}\n\n']);
  assert.equal(events.at(-1)?.type, 'error');
  assert.equal(events.filter((event) => event.type === 'error').length, 1);
});

test('does not forward stale events after a terminal event', async (t) => {
  assert.deepEqual(await collect(t, [
    'data: {"type":"done","text":"finished"}\n\ndata: {"type":"chunk","text":"stale"}\n\n',
  ]), [{ type: 'done', text: 'finished' }]);
});

test('an incomplete terminal frame does not count as successful completion', async (t) => {
  const events = await collect(t, ['data: {"type":"done","text":"partial"}']);
  assert.equal(events.at(-1)?.type, 'error');
});

test('invalid events are ignored without hiding a later valid completion', async (t) => {
  assert.deepEqual(await collect(t, [
    'data: null\n\ndata: not-json\n\ndata: {"type":"done"}\n\n',
    'data: {"type":"done",\n', 'data: "text":"hello"}\n\n',
  ]), [{ type: 'done', text: 'hello' }]);
});

test('a stalled request times out once and aborts its network connection', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let signal;
  const events = [];
  t.mock.method(globalThis, 'fetch', (_url, options) => new Promise((_resolve, reject) => {
    signal = options.signal;
    signal.addEventListener('abort', () => reject(new Error('aborted')));
  }));
  stream_chat('https://example.test/chat', '{}', (event) => events.push(JSON.parse(event)));
  t.mock.timers.tick(45000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(signal.aborted, true);
  assert.equal(events.length, 1);
  assert.equal(events[0].type, 'error');
});


test('waits for delayed reads before asserting terminal completion', async (t) => {
  assert.deepEqual(await collect(t, [
    'data: {"type":"chunk","text":"hello"}\n\n',
    'data: {"type":"done","text":"hello"}\n\n',
  ], { delayed: true }), [{ type: 'chunk', text: 'hello' }, { type: 'done', text: 'hello' }]);
});

test('a healthy stream may run longer than 45 seconds while data keeps arriving', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let signal;
  let controller;
  const events = [];
  t.mock.method(globalThis, 'fetch', async (_url, options) => {
    signal = options.signal;
    return new Response(new ReadableStream({ start(c) { controller = c; } }));
  });
  stream_chat('https://example.test/chat', '{}', (event) => events.push(JSON.parse(event)));
  await new Promise((resolve) => setImmediate(resolve));
  t.mock.timers.tick(30000);
  controller.enqueue(new TextEncoder().encode('data: {"type":"chunk","text":"still working"}\n\n'));
  await new Promise((resolve) => setImmediate(resolve));
  t.mock.timers.tick(30000);
  assert.equal(signal.aborted, false);
  controller.enqueue(new TextEncoder().encode('data: {"type":"done","text":"complete"}\n\n'));
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(events, [{ type: 'chunk', text: 'still working' }, { type: 'done', text: 'complete' }]);
});

test('a missing response body reports an empty response rather than HTTP 200', async (t) => {
  t.mock.method(globalThis, 'fetch', async () => new Response(null));
  const event = await new Promise((resolve) => {
    stream_chat('https://example.test/chat', '{}', (raw) => resolve(JSON.parse(raw)));
  });
  assert.deepEqual(event, { type: 'error', message: 'Empty response body' });
});

// ---------------------------------------------------------------------------
// Voice replies
// ---------------------------------------------------------------------------

test('voice and speech events reach the app before done, in order', async (t) => {
  const speech = { type: 'speech', seq: 0, start: 0, end: 3, audio: null, mime: 'audio/mpeg', marks: [] };
  assert.deepEqual(await collect(t, [
    'data: {"type":"thinking"}\n\n',
    'data: {"type":"voice","on":true}\n\n',
    'data: {"type":"chunk","text":"Hi."}\n\n',
    'data: ' + JSON.stringify(speech) + '\n\n',
    'data: {"type":"speech_end","upto":3}\n\n',
    'data: {"type":"done","text":"Hi."}\n\n',
  ]), [
    { type: 'thinking' }, { type: 'voice', on: true }, { type: 'chunk', text: 'Hi.' },
    speech, { type: 'speech_end', upto: 3 }, { type: 'done', text: 'Hi.' },
  ]);
});

test('malformed speech events are dropped without ending the stream', async (t) => {
  assert.deepEqual(await collect(t, [
    'data: {"type":"voice"}\n\n',
    'data: {"type":"speech","start":0,"end":3}\n\n',
    'data: {"type":"speech_end","upto":"3"}\n\n',
    'data: {"type":"done","text":"ok"}\n\n',
  ]), [{ type: 'done', text: 'ok' }]);
});

test('reveal_prefix never shows half a character or a dangling marker', () => {
  assert.equal(reveal_prefix('Hi **Arda** there', 7), 'Hi **Ar**');
  assert.equal(reveal_prefix('see [my blog](https://x.y) ok', 16), 'see my blog');
  assert.equal(reveal_prefix('see [my blog](u)', 10), 'see my bl');
  assert.equal(reveal_prefix('a 👋 b', 3), 'a ');
  assert.equal(reveal_prefix('use `gleam` now', 7), 'use `gl`');
  assert.equal(reveal_prefix('all of it', -1), 'all of it');
  assert.equal(reveal_prefix('all of it', 99), 'all of it');
});

// A browser-ish `window` with localStorage and no Web Audio, for this test only.
function fakeWindow(t) {
  const m = new Map();
  globalThis.window = { localStorage: { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)) } };
  t.after(() => { delete globalThis.window; });
}

test('voice defaults on, persists a mute, and a muted request has no voice fields', (t) => {
  fakeWindow(t);
  assert.equal(voiceEnabled(), true);
  assert.deepEqual(requestFields('ja'), { voice: true, lang: 'ja' });
  setVoiceEnabled(false);
  assert.equal(window.localStorage.getItem('voice'), 'off');
  assert.equal(voiceEnabled(), false);
  assert.deepEqual(requestFields('ja'), {});
  setVoiceEnabled(true);
});

test('without Web Audio a voiced reply is shown at once, like text-only', (t) => {
  fakeWindow(t);
  const calls = [];
  const s = createSpeaker({ onReveal: (n) => calls.push(['reveal', n]), onEnd: () => calls.push(['end']) });
  s.handle({ type: 'thinking' });
  s.handle({ type: 'voice', on: true });
  s.handle({ type: 'chunk', text: 'Hi.' });
  s.handle({ type: 'done', text: 'Hi.' });
  s.stop();
  assert.deepEqual(calls, [['reveal', Infinity], ['end']]);
});

test('voice:false from the server means no gating at all', (t) => {
  fakeWindow(t);
  const calls = [];
  const s = createSpeaker({ onReveal: (n) => calls.push(n), onEnd: () => calls.push('end') });
  s.handle({ type: 'voice', on: false });
  assert.deepEqual(calls, [Infinity, 'end']);
});
