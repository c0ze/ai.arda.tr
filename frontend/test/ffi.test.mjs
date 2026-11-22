import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  stream_chat, reveal_prefix, abort_stream, render_markdown, set_mark_level, speech_begin, speech_stop,
  scheme_toggle, scheme_watch,
} from '../build/dev/javascript/frontend/ffi.mjs';
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

test('reveal_prefix drops a bold or code opener that has nothing after it yet', () => {
  // the voice often rests right before a bold word; closing the empty opener would show "****"
  assert.equal(reveal_prefix('はい、Ardaは**Go**の経験', 10), 'はい、Ardaは');
  assert.equal(reveal_prefix('はい、Ardaは**Go**の経験', 9), 'はい、Ardaは', 'half a ** marker');
  assert.equal(reveal_prefix('はい、Ardaは**Go**の経験', 11), 'はい、Ardaは**G**');
  assert.equal(reveal_prefix('run `make` now', 5), 'run ');
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

// ---------------------------------------------------------------------------
// The voice's loudness shows on the ember of the reply being spoken, as the
// custom property --ix-level (0 to 1) that brand.css turns into its glow. It
// must not outlive the voice, or an ember stays lit.
// ---------------------------------------------------------------------------

// A `document` whose querySelector finds the embers given by selector.
function fakeMarks(t, marks) {
  const mark = () => {
    const props = new Map();
    return { props, style: { setProperty: (k, v) => props.set(k, v), removeProperty: (k) => props.delete(k) } };
  };
  const found = Object.fromEntries(marks.map((selector) => [selector, mark()]));
  globalThis.document = { querySelector: (selector) => found[selector] ?? null };
  t.after(() => { set_mark_level('', 0); delete globalThis.document; });
  return found;
}

test('the loudness is set on the speaking reply\'s ember, between 0 and 1', (t) => {
  const { '.speaking': mark } = fakeMarks(t, ['.speaking']);
  set_mark_level('.speaking', 0.5);
  assert.equal(mark.props.get('--ix-level'), '0.50');
  set_mark_level('.speaking', 3);
  assert.equal(mark.props.get('--ix-level'), '1.00');
});

test('silence takes the loudness off the ember again', (t) => {
  const { '.speaking': mark } = fakeMarks(t, ['.speaking']);
  set_mark_level('.speaking', 0.7);
  set_mark_level('.speaking', 0);
  assert.equal(mark.props.has('--ix-level'), false);
});

test('when another reply starts speaking, the previous ember is released', (t) => {
  const marks = fakeMarks(t, ['.first', '.second']);
  set_mark_level('.first', 0.7);
  set_mark_level('.second', 0.4);
  assert.equal(marks['.first'].props.has('--ix-level'), false);
  assert.equal(marks['.second'].props.get('--ix-level'), '0.40');
});

test('stopping the voice (a new question, a language switch) releases the ember', (t) => {
  fakeWindow(t);
  const { '.speaking': mark } = fakeMarks(t, ['.speaking']);
  speech_begin('.speaking', () => {}, () => {});
  set_mark_level('.speaking', 0.6); // as the speaker's onLevel would, mid-sentence
  speech_stop();
  assert.equal(mark.props.has('--ix-level'), false);
});

// ---------------------------------------------------------------------------
// The colour scheme belongs to the family's scheme.js (public/brand/, loaded
// by index.html as window.ardaScheme). ai.arda.tr is dark unless the visitor
// pins light, under the key the earlier designs used ("theme"), which is how
// a returning visitor's choice survives: the same key and default as the boot
// script in frontend/gleam.toml.
// ---------------------------------------------------------------------------

test('the scheme switch asks scheme.js to toggle "theme", dark by default', (t) => {
  const calls = [];
  globalThis.window = { ardaScheme: {
    toggleScheme: (...args) => calls.push(['toggle', ...args]),
    watchScheme: (...args) => calls.push(['watch', ...args]),
  } };
  t.after(() => { delete globalThis.window; });
  scheme_toggle();
  scheme_watch();
  assert.deepEqual(calls, [['toggle', 'theme', 'dark'], ['watch', 'theme', 'dark']]);
});

test('without scheme.js the switch does nothing, and nothing breaks', (t) => {
  globalThis.window = {};
  t.after(() => { delete globalThis.window; });
  scheme_toggle();
  scheme_watch();
  delete globalThis.window;
  scheme_toggle(); // outside a browser (these tests, the app tests)
});

// ---------------------------------------------------------------------------
// One request at a time: a new send or a reset aborts the one in flight.
// ---------------------------------------------------------------------------

function controllableFetch(t) {
  const calls = [];
  t.mock.method(globalThis, 'fetch', async (_url, options) => {
    const call = { signal: options.signal };
    calls.push(call);
    return new Response(new ReadableStream({ start(c) { call.controller = c; } }));
  });
  return calls;
}
const tick = () => new Promise((resolve) => setImmediate(resolve));
const sse = (obj) => new TextEncoder().encode('data: ' + JSON.stringify(obj) + '\n\n');

test('a new request aborts the one in flight and silences it', async (t) => {
  const calls = controllableFetch(t);
  const first = [];
  const second = [];
  stream_chat('https://example.test/chat', '{}', (e) => first.push(JSON.parse(e)));
  await tick();
  stream_chat('https://example.test/chat', '{}', (e) => second.push(JSON.parse(e)));
  await tick();
  assert.equal(calls[0].signal.aborted, true);
  try { calls[0].controller.enqueue(sse({ type: 'done', text: 'stale' })); } catch (_) {}
  calls[1].controller.enqueue(sse({ type: 'done', text: 'fresh' }));
  await tick();
  assert.deepEqual(first, []);
  assert.deepEqual(second, [{ type: 'done', text: 'fresh' }]);
});

test('abort_stream stops the request in flight without reporting an error', async (t) => {
  const calls = controllableFetch(t);
  const events = [];
  stream_chat('https://example.test/chat', '{}', (e) => events.push(JSON.parse(e)));
  await tick();
  abort_stream();
  await tick();
  assert.equal(calls[0].signal.aborted, true);
  assert.deepEqual(events, []);
});

test('a network failure is reported as "Network error", which the app localises', async (t) => {
  t.mock.method(globalThis, 'fetch', async () => { throw new TypeError('Failed to fetch'); });
  const event = await new Promise((resolve) => {
    stream_chat('https://example.test/chat', '{}', (raw) => resolve(JSON.parse(raw)));
  });
  assert.deepEqual(event, { type: 'error', message: 'Network error' });
});

// ---------------------------------------------------------------------------
// Markdown: links open in a new tab through a DOMPurify hook (not a regex on
// the sanitised string), and only the tags and attributes markdown needs are
// allowed: a reply can carry no beacon (an image, a video poster, a table
// background) and no overlay (a fixed-position div).
// ---------------------------------------------------------------------------

const MARKDOWN_TAGS = ['p', 'br', 'strong', 'b', 'em', 'i', 'del', 's', 'code', 'pre', 'blockquote',
  'ul', 'ol', 'li', 'a', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr', 'table', 'thead', 'tbody', 'tr', 'th', 'td'];

// Renders with a stub DOMPurify that records the config it is given. These
// tests check the configuration (and the hook on fake nodes), not DOMPurify's
// output: Node has no DOM and the frontend has no dependencies to bring one,
// so URI filtering and the final target/rel are not exercised here.
function sanitizerConfig(t) {
  const hooks = {};
  const seen = {};
  globalThis.window = {
    marked: { parse: (text) => text },
    DOMPurify: {
      addHook: (name, fn) => { hooks[name] = fn; },
      sanitize: (html, cfg) => { seen.config = cfg; return html; },
    },
  };
  t.after(() => { delete globalThis.window; });
  seen.html = render_markdown('<a href="https://x.y">x</a>');
  seen.hooks = hooks;
  return seen;
}

// Tags and attributes in an HTML string (what marked emits, or a payload).
function elements(html) {
  return [...html.matchAll(/<([a-zA-Z][\w-]*)([^>]*)>/g)].map(([, tag, rest]) => ({
    tag: tag.toLowerCase(),
    attrs: [...rest.matchAll(/([^\s=/"']+)(?:=(?:"[^"]*"|'[^']*'|[^\s>]+))?/g)].map((m) => m[1].toLowerCase()),
  }));
}

function survives(config, { tag, attrs }) {
  if (!config.ALLOWED_TAGS.includes(tag)) return [];
  return attrs.filter((a) => config.ALLOWED_ATTR.includes(a));
}

test('sanitiser config: render_markdown passes DOMPurify an allowlist of the markdown tags and attributes', (t) => {
  const { config, html } = sanitizerConfig(t);
  // The sanitised string comes back untouched: no regex rewriting of "<a href".
  assert.equal(html, '<a href="https://x.y">x</a>');
  assert.deepEqual([...config.ALLOWED_TAGS].sort(), [...MARKDOWN_TAGS].sort());
  assert.deepEqual([...config.ALLOWED_ATTR].sort(), ['align', 'href', 'start', 'title']);
  // data-* and aria-* would otherwise be allowed on top of ALLOWED_ATTR.
  assert.equal(config.ALLOW_DATA_ATTR, false);
  assert.equal(config.ALLOW_ARIA_ATTR, false);
});

test('sanitiser config: the allowlist admits no tag or attribute of the beacon and overlay payloads', (t) => {
  const { config } = sanitizerConfig(t);
  const payloads = [
    '<svg><image href="https://beacon.example/1"></image></svg>',
    '<video src="https://beacon.example/2" poster="https://beacon.example/3"></video>',
    '<audio src="https://beacon.example/4"></audio>',
    '<picture><source srcset="https://beacon.example/5"></picture>',
    '<table background="https://beacon.example/6"><tr><td>x</td></tr></table>',
    '<div style="position:fixed;inset:0;background:url(https://beacon.example/7)">x</div>',
    '<p style="position:fixed;inset:0">x</p>',
    '<img src="https://beacon.example/8">',
    '<form action="https://evil.example"><input name="q"><button>go</button></form>',
    '<style>body{display:none}</style>',
    '<a href="https://x.y" class="ix-btn ix-btn--primary" style="position:fixed">x</a>',
  ];
  for (const payload of payloads) {
    for (const el of elements(payload)) {
      // Whatever survives may not load anything or move anything.
      for (const attr of survives(config, el)) {
        assert.ok(attr === 'href' && el.tag === 'a' || ['title', 'start', 'align'].includes(attr),
          `${payload}: <${el.tag} ${attr}> survives`);
      }
      for (const tag of ['svg', 'image', 'video', 'audio', 'picture', 'source', 'div', 'img', 'form',
        'input', 'button', 'style']) {
        if (el.tag === tag) assert.ok(!config.ALLOWED_TAGS.includes(tag), `${payload}: <${tag}> allowed`);
      }
    }
  }
});

test('sanitiser config: the allowlist admits every tag and attribute marked 18 emits for normal markdown', async (t) => {
  const { config } = sanitizerConfig(t);
  const { createRequire } = await import('node:module');
  const marked = createRequire(import.meta.url)('../../public/vendor/marked.min.js');
  const html = marked.parse([
    '# Title', '## Section', '### Sub', '#### Small',
    '', 'Some **bold**, *italic*, ~~gone~~ and `code`; a [link](https://arda.tr "Arda") and <https://x.y>.',
    'line one  ', 'line two',
    '', '- one', '- two', '  1. nested',
    '', '3. third', '4. fourth',
    '', '> quoted', '', '---',
    '', '| left | centre | right |', '|:--|:-:|--:|', '| 1 | 2 | 3 |',
    '', '```gleam', 'pub fn main() { Nil }', '```',
    '', '- [ ] a task', '- [x] done',
  ].join('\n'));
  const dropped = [];
  for (const el of elements(html)) {
    if (!config.ALLOWED_TAGS.includes(el.tag)) { dropped.push(el.tag); continue; }
    for (const attr of el.attrs) {
      if (!config.ALLOWED_ATTR.includes(attr)) dropped.push(`${el.tag}[${attr}]`);
    }
  }
  // Only the task-list checkboxes (forbidden before as well) and the code
  // block's language class go. Nothing styles that class, and a reply could
  // otherwise borrow the page's own classes.
  assert.deepEqual([...new Set(dropped)].sort(), ['code[class]', 'input']);
  const { readFile } = await import('node:fs/promises');
  const css = await readFile(new URL('../../public/style.css', import.meta.url), 'utf8');
  assert.equal(/language-|\.txt [^{]*\[class/.test(css.replace(/\.language-toggle/g, '')), false);
  // Ordered-list starts, table alignment, titles and links are all kept.
  for (const needed of ['ol start', 'th align', 'td align', 'a href', 'a title']) {
    const [tag, attr] = needed.split(' ');
    assert.ok(elements(html).some((el) => el.tag === tag && el.attrs.includes(attr)), needed);
  }
});

test('sanitiser hook: on fake nodes, links get target and rel; registered once per DOMPurify instance', (t) => {
  const { hooks } = sanitizerConfig(t);
  assert.equal(typeof hooks.afterSanitizeAttributes, 'function');
  const attrs = (initial) => {
    const a = new Map(Object.entries(initial));
    return { a, node: { hasAttribute: (k) => a.has(k), setAttribute: (k, v) => a.set(k, v) } };
  };
  const link = attrs({ href: 'https://x.y' });
  hooks.afterSanitizeAttributes({ tagName: 'A', ...link.node });
  assert.equal(link.a.get('target'), '_blank');
  assert.equal(link.a.get('rel'), 'noopener noreferrer');
  const para = attrs({});
  hooks.afterSanitizeAttributes({ tagName: 'P', ...para.node });
  assert.equal(para.a.size, 0);

  // The hook is registered once per DOMPurify instance, not on every render.
  let added = 0;
  window.DOMPurify.addHook = () => { added += 1; };
  render_markdown('again');
  assert.equal(added, 0);
});

// ---------------------------------------------------------------------------
// A fresh conversation (first load, a language switch) is shown from its top:
// the page's heading and the welcome. A reply scrolls to its end instead.
// ---------------------------------------------------------------------------

test('a fresh conversation is scrolled to its top, a reply to its end', async (t) => {
  const { scroll_to_top, scroll_to_bottom } = await import('../build/dev/javascript/frontend/ffi.mjs');
  const scroller = { scrollTop: 240, scrollHeight: 900 };
  const frames = [];
  globalThis.document = { querySelector: (selector) => (selector === '#messages-container' ? scroller : null) };
  globalThis.requestAnimationFrame = (run) => frames.push(run);
  t.after(() => { delete globalThis.document; delete globalThis.requestAnimationFrame; });
  const settle = () => { while (frames.length) frames.shift()(); };
  scroll_to_bottom('#messages-container');
  settle();
  assert.equal(scroller.scrollTop, 900);
  scroll_to_top('#messages-container');
  assert.equal(scroller.scrollTop, 900, 'after the render, not before it');
  settle();
  assert.equal(scroller.scrollTop, 0);
});
