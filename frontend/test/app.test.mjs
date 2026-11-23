import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import {
  init, update, UserTypedInput, UserClickedSend, UserPickedLanguage, UserToggledVoice, StreamEventReceived,
  SpeechRevealed, SpeechEnded,
} from '../build/dev/javascript/frontend/frontend.mjs';
import { Jp, Tr } from '../build/dev/javascript/frontend/frontend/i18n.mjs';

// The app's update function, driven without a DOM. Effects are returned, not
// run, so no request is ever made.
function start() {
  const [model] = init(undefined);
  return model;
}
const step = (model, msg) => update(model, msg)[0];
const texts = (model) => model.history.toArray().map((m) => m.text);

test('switching language mid-reply drops the old reply instead of adding it to the new conversation', () => {
  let model = start();
  model = step(model, new UserTypedInput('Where has Arda worked?'));
  model = step(model, new UserClickedSend());
  const oldGeneration = model.generation;
  model = step(model, new StreamEventReceived(oldGeneration, '{"type":"thinking"}'));
  model = step(model, new StreamEventReceived(oldGeneration, '{"type":"chunk","text":"He worked at"}'));
  model = step(model, new UserPickedLanguage(new Jp()));
  const welcomeOnly = texts(model);
  assert.equal(welcomeOnly.length, 1, 'the new conversation starts with just its welcome');
  // Late events from the aborted request must not reach the new conversation.
  model = step(model, new StreamEventReceived(oldGeneration, '{"type":"chunk","text":" Acme."}'));
  model = step(model, new StreamEventReceived(oldGeneration, '{"type":"done","text":"He worked at Acme."}'));
  model = step(model, new StreamEventReceived(oldGeneration, '{"type":"error","message":"HTTP 500"}'));
  assert.deepEqual(texts(model), welcomeOnly);
  assert.equal(model.stream_state.constructor.name, 'Idle');
});

test('events of the current request are still applied', () => {
  let model = start();
  model = step(model, new UserTypedInput('Hi'));
  model = step(model, new UserClickedSend());
  const gen = model.generation;
  model = step(model, new StreamEventReceived(gen, '{"type":"thinking"}'));
  model = step(model, new StreamEventReceived(gen, '{"type":"done","text":"Hello."}'));
  assert.equal(texts(model).at(-1), 'Hello.');
});

// ---------------------------------------------------------------------------
// Screen readers: the reply is announced once, when it is complete.
// ---------------------------------------------------------------------------

import { view } from '../build/dev/javascript/frontend/frontend.mjs';
import { to_string } from '../build/dev/javascript/lustre/lustre/element.mjs';

test('a reply is announced once, when it completes, not on every chunk', () => {
  let model = start();
  model = step(model, new UserTypedInput('Hi'));
  model = step(model, new UserClickedSend());
  const gen = model.generation;
  model = step(model, new StreamEventReceived(gen, '{"type":"thinking"}'));
  model = step(model, new StreamEventReceived(gen, '{"type":"chunk","text":"Hel"}'));
  assert.equal(model.announcement, '', 'nothing is announced while the reply streams');
  model = step(model, new StreamEventReceived(gen, '{"type":"chunk","text":"lo."}'));
  assert.equal(model.announcement, '');
  model = step(model, new StreamEventReceived(gen, '{"type":"done","text":"Hello."}'));
  assert.equal(model.announcement, 'Hello.');
  // The next question clears it, so an identical reply is announced again.
  model = step(model, new UserTypedInput('Hi again'));
  model = step(model, new UserClickedSend());
  assert.equal(model.announcement, '');
});

test('the transcript is a log that does not announce itself; a polite region carries the reply', () => {
  let model = start();
  model = step(model, new UserTypedInput('Hi'));
  model = step(model, new UserClickedSend());
  model = step(model, new StreamEventReceived(model.generation, '{"type":"thinking"}'));
  model = step(model, new StreamEventReceived(model.generation, '{"type":"done","text":"Hello there."}'));
  const html = to_string(view(model));
  const messages = html.match(/<div[^>]*id="messages"[^>]*>/)[0];
  assert.match(messages, /role="log"/);
  assert.match(messages, /aria-live="off"/);
  const announcer = html.match(/<div[^>]*id="reply-announcer"[^>]*>([^<]*)<\/div>/);
  assert.match(announcer[0], /aria-live="polite"/);
  assert.equal(announcer[1], 'Hello there.');
});

// ---------------------------------------------------------------------------
// Errors and empty replies are not the model's words: they stay out of the
// history sent with the next question, and errors read in the UI language.
// ---------------------------------------------------------------------------

import { wire_history } from '../build/dev/javascript/frontend/frontend.mjs';

const wire = (model) => wire_history(model.history).toArray().map((m) => [m.role, m.content]);

function ask(model, text) {
  model = step(model, new UserTypedInput(text));
  return step(model, new UserClickedSend());
}

test('an error is flagged, localised, and not sent back to the model as its own turn', () => {
  let model = ask(start(), 'Hi');
  model = step(model, new StreamEventReceived(model.generation, '{"type":"error","message":"HTTP 429"}'));
  const last = model.history.toArray().at(-1);
  assert.equal(last.is_error, true);
  assert.match(last.text, /minute/);
  assert.deepEqual(wire(model), [['user', 'Hi']]);
});

test('an empty reply is not sent back to the model as an empty turn', () => {
  let model = ask(start(), 'Hi');
  model = step(model, new StreamEventReceived(model.generation, '{"type":"thinking"}'));
  model = step(model, new StreamEventReceived(model.generation, '{"type":"done","text":""}'));
  model = ask(model, 'Again');
  model = step(model, new StreamEventReceived(model.generation, '{"type":"thinking"}'));
  model = step(model, new StreamEventReceived(model.generation, '{"type":"done","text":"Sure."}'));
  assert.deepEqual(wire(model), [['user', 'Hi'], ['user', 'Again'], ['model', 'Sure.']]);
});

test('offline and timeout errors read in the UI language', () => {
  let model = step(start(), new UserPickedLanguage(new Jp()));
  model = ask(model, 'こんにちは');
  model = step(model, new StreamEventReceived(model.generation, '{"type":"error","message":"Network error"}'));
  assert.match(model.history.toArray().at(-1).text, /ネットワーク/);
  model = ask(model, 'もう一度');
  model = step(model, new StreamEventReceived(model.generation, '{"type":"error","message":"Response timed out. Please try again."}'));
  assert.match(model.history.toArray().at(-1).text, /タイムアウト/);
});

// ---------------------------------------------------------------------------
// Accessible names contain the visible text (WCAG 2.5.3) and follow the UI
// language; the scrolling transcript can be reached from the keyboard.
// ---------------------------------------------------------------------------

const tagWith = (html, needle) => html.match(new RegExp('<[a-z]+[^>]*' + needle + '[^>]*>'))?.[0] ?? '';
const attr = (tag, name) => tag.match(new RegExp(name + '="([^"]*)"'))?.[1];

test('the send and voice buttons are named by what they show', () => {
  // Speech control users say what they see: in every language the send
  // button's accessible name must contain its visible label.
  for (const lang of [null, new Jp(), new Tr()]) {
    const html = to_string(view(lang ? step(start(), new UserPickedLanguage(lang)) : start()));
    const send = html.match(/<button[^>]*id="send-btn"[^>]*>([^<]*)<\/button>/);
    assert.ok(send[1].length > 0, 'the send button shows a label');
    assert.ok(attr(send[0], 'aria-label').toLowerCase().includes(send[1].toLowerCase()),
      `"${attr(send[0], 'aria-label')}" contains "${send[1]}"`);
  }
  // The voice toggle is a plain labelled button: its text is its name, and it
  // says the state in words as well as in aria-pressed (and a filled chip).
  // The bar has room for one word, so what the voice does is in the title.
  const voiceToggle = (model) => to_string(view(model)).match(/<button[^>]*class="ix-chip voice-toggle"[^>]*>(.*?)<\/button>/);
  const on = voiceToggle(start());
  assert.equal(attr(on[0], 'aria-label'), undefined);
  assert.equal(on[1], 'Voice: On');
  assert.equal(attr(on[0], 'title'), 'Read replies aloud');
  assert.equal(attr(on[0], 'aria-pressed'), 'true');
  const off = voiceToggle(step(start(), new UserToggledVoice()));
  assert.equal(off[1], 'Voice: Off');
  assert.equal(attr(off[0], 'aria-pressed'), 'false');
  for (const [lang, shown, title] of [[new Jp(), '音声: オン', '返答を読み上げる'], [new Tr(), 'Ses: Açık', 'Yanıtları sesli oku']]) {
    const toggle = voiceToggle(step(start(), new UserPickedLanguage(lang)));
    assert.equal(toggle[1], shown);
    assert.equal(attr(toggle[0], 'title'), title);
  }
});

test('labels follow the UI language', () => {
  const html = to_string(view(step(start(), new UserPickedLanguage(new Jp()))));
  assert.equal(attr(tagWith(html, 'class="language-toggle"'), 'aria-label'), '言語');
  // Exactly one language is marked as the one in use.
  const pressed = [...html.matchAll(/<button[^>]*aria-pressed="true"[^>]*class="ix-navlink"[^>]*>/g)];
  assert.equal(pressed.length, 1);
  assert.match(attr(pressed[0][0], 'aria-label'), /^JP/);
  assert.match(attr(pressed[0][0], 'aria-label'), /日本語/);
  assert.match(attr(tagWith(html, 'id="send-btn"'), 'aria-label'), /送信/);
});

// ---------------------------------------------------------------------------
// The scheme switch. Both labels are in the markup and brand.css shows the one
// that fits <html data-theme>, so the label is right before the app starts and
// the app keeps no scheme state. A label under the wrong `data-when` would
// offer "Dark" on a page that is already dark.
// ---------------------------------------------------------------------------

test('the scheme switch offers the other scheme, by name, in every language', () => {
  for (const [lang, light, dark, lightName] of [
    [null, 'Light', 'Dark', 'Switch to Light scheme'],
    [new Jp(), 'ライト', 'ダーク', 'ライトテーマに切り替える'],
    [new Tr(), 'Açık', 'Koyu', 'Açık temaya geç'],
  ]) {
    const html = to_string(view(lang ? step(start(), new UserPickedLanguage(lang)) : start()));
    const button = html.match(/<button[^>]*class="ix-scheme ix-navlink"[^>]*>(.*)<\/span><\/button>/);
    // Named by its content, since CSS decides which label there is.
    assert.equal(attr(button[0], 'aria-label'), undefined);
    const labels = Object.fromEntries(button[1].split('<span data-when="').slice(1).map((part) => {
      const [when, rest] = [part.slice(0, part.indexOf('"')), part.slice(part.indexOf('>') + 1)];
      return [when, {
        visible: rest.replace(/<span class="ix-sr">[^<]*<\/span>/g, '').replace(/<[^>]*>/g, ''),
        name: rest.replace(/<[^>]*>/g, ''),
      }];
    }));
    assert.deepEqual(Object.keys(labels).sort(), ['dark', 'light']);
    assert.equal(labels.dark.visible, light, 'a dark page offers light');
    assert.equal(labels.light.visible, dark, 'a light page offers dark');
    assert.equal(labels.dark.name, lightName);
    // The accessible name contains what is shown (WCAG 2.5.3).
    for (const label of Object.values(labels)) assert.ok(label.name.includes(label.visible));
  }
});

// ---------------------------------------------------------------------------
// The assistant is the ember (`.ix-mark`), nothing else. It glows (`data-busy`)
// while a reply is awaited or written; while the voice speaks, `ffi.mjs` sets
// the loudness on the ember of the `.is-streaming` reply instead, so that
// reply must be findable and must not also pulse.
// ---------------------------------------------------------------------------

const marks = (model) => [...to_string(view(model)).matchAll(/<span[^>]*class="ix-mark"[^>]*>/g)].map((m) => m[0]);
const busy = (model) => marks(model).map((tag) => attr(tag, 'data-busy') === 'true');
const event = (model, obj) => step(model, new StreamEventReceived(model.generation, JSON.stringify(obj)));

test('the ember is busy while a reply is awaited or written, and at rest once it is complete', () => {
  let model = start();
  assert.deepEqual(busy(model), [false], 'the welcome is a finished message');
  model = ask(model, 'Hi');
  assert.deepEqual(busy(model), [false, true], 'sent, nothing back yet');
  // The wait is said in words beside the ember too: it does not pulse under
  // reduced motion.
  assert.match(to_string(view(model)), /<p[^>]*class="txt ix-muted"[^>]*>Thinking…<\/p>/);
  model = event(model, { type: 'thinking' });
  assert.deepEqual(busy(model), [false, true], 'the model is thinking');
  model = event(model, { type: 'chunk', text: 'Hello' });
  assert.deepEqual(busy(model), [false, true], 'the reply is being written');
  assert.doesNotMatch(to_string(view(model)), /Thinking…<\/p>/);
  model = event(model, { type: 'done', text: 'Hello.' });
  assert.deepEqual(busy(model), [false, false]);
});

test('while the voice speaks a reply, its ember stops pulsing and can be found by the voice', () => {
  const spoken = /<div[^>]*class="ix-msg msg bot is-streaming"[^>]*><span[^>]*class="ix-mark"/;
  let model = ask(start(), 'Hi');
  model = event(model, { type: 'thinking' });
  model = step(model, new SpeechRevealed(0)); // the server said voice on; nothing spoken yet
  model = event(model, { type: 'chunk', text: 'Hello there.' });
  assert.deepEqual(busy(model), [false, true], 'the audio has not started');
  model = step(model, new SpeechRevealed(5));
  assert.deepEqual(busy(model), [false, false], 'speaking: the loudness drives the ember');
  assert.match(to_string(view(model)), spoken);
  // The reply shows only as far as the voice has got.
  assert.match(to_string(view(model)), /<p>Hello<\/p>/);
  assert.doesNotMatch(to_string(view(model)), /there/);
  model = event(model, { type: 'done', text: 'Hello there.' });
  assert.match(to_string(view(model)), spoken, 'the text is done, the voice is not');
  model = step(model, new SpeechRevealed(-1));
  model = step(model, new SpeechEnded());
  assert.doesNotMatch(to_string(view(model)), /is-streaming/);
  assert.match(to_string(view(model)), /<p>Hello there\.<\/p>/);
});

test('what the assistant is doing is said in a status line for screen readers', () => {
  const status = (model) => to_string(view(model)).match(/<p[^>]*role="status"[^>]*>([^<]*)<\/p>/);
  let model = start();
  assert.equal(status(model)[1], 'Ready');
  assert.equal(attr(status(model)[0], 'aria-live'), 'polite');
  model = ask(model, 'Hi');
  assert.equal(status(model)[1], 'Thinking…');
  model = event(model, { type: 'thinking' });
  model = event(model, { type: 'chunk', text: 'Hello' });
  assert.equal(status(model)[1], 'Writing…');
});

// ---------------------------------------------------------------------------
// Who said what does not depend on seeing the layout: the visitor's words are
// in the family's box on the surface colour, each message names its speaker
// for screen readers, and an error is told by a label and a written message,
// not by its colour alone.
// ---------------------------------------------------------------------------

const messageTags = (model) => to_string(view(model)).match(/<div[^>]*id="messages"[^>]*>(.*)<div[^>]*id="reply-announcer"/s)[1]
  .split(/(?=<div[^>]*data-msg-id=")/).filter((part) => part.includes('data-msg-id='));

test('each message names its speaker; the visitor\'s is the boxed one', () => {
  let model = ask(start(), 'Hi');
  model = event(model, { type: 'thinking' });
  model = event(model, { type: 'done', text: 'Hello.' });
  const [welcome, question, reply] = messageTags(model);
  assert.match(welcome, /^<div[^>]*class="ix-msg msg bot/);
  assert.match(welcome, /<span class="ix-sr">Construct<\/span>/);
  assert.match(question, /^<div[^>]*class="ix-msg ix-msg--you msg user/);
  assert.match(question, /<span class="ix-sr">You<\/span>/);
  assert.doesNotMatch(question, /ix-mark/, 'the ember is the assistant');
  assert.match(reply, /<span class="ix-sr">Construct<\/span>/);
});

test('an error carries the word "Error", in the UI language, and no ember', () => {
  for (const [lang, label] of [[null, 'Error'], [new Jp(), 'エラー'], [new Tr(), 'Hata']]) {
    let model = ask(lang ? step(start(), new UserPickedLanguage(lang)) : start(), 'Hi');
    model = event(model, { type: 'error', message: 'HTTP 500' });
    const line = messageTags(model).at(-1);
    assert.match(line, /^<div[^>]*class="ix-msg msg bot is-error/);
    // The family's error colour (brand.css `.ix-error`) is on the whole line:
    // the label and the message it carries.
    const body = line.match(/<div class="ix-msg__body ix-error">(.*)$/s);
    assert.ok(body, 'the line is an .ix-error');
    assert.ok(body[1].includes(`<p class="ix-label">${label}</p>`), label);
    assert.match(body[1], /HTTP 500/);
    // An error is not the assistant's words.
    assert.doesNotMatch(line, /ix-mark/);
    // Heard as it is seen: the label, then the line.
    assert.equal(model.announcement, `${label}: HTTP 500`);
  }
});

test('a Japanese message is marked as Japanese when the page is in another language', () => {
  // brand.css gives `:lang(ja)` text the Japanese face and size; a screen
  // reader picks its Japanese voice the same way.
  let model = ask(start(), 'Ardaはどこで働いてきましたか？');
  model = event(model, { type: 'thinking' });
  model = event(model, { type: 'done', text: 'はい、Ardaは東京で働いています。' });
  const [welcome, question, reply] = messageTags(model).map((tag) => attr(tag.match(/^<div[^>]*>/)[0], 'lang'));
  assert.deepEqual([welcome, question, reply], [undefined, 'ja', 'ja']);
});

test('the scrolling transcript is focusable and labelled', () => {
  const container = tagWith(to_string(view(start())), 'id="messages-container"');
  assert.equal(attr(container, 'tabindex'), '0');
  assert.equal(attr(container, 'aria-label'), 'Conversation');
});

test('the input allows as much as the server accepts', () => {
  // maxlength counts UTF-16 units, the server counts graphemes (each at least
  // one unit), so nothing the input allows is rejected.
  assert.equal(attr(tagWith(to_string(view(start())), 'id="user-input"'), 'maxlength'), '20000');
});

// ---------------------------------------------------------------------------
// The arda.tr family: the chat links to its sibling sites in every language,
// and never to coze.org (the owner keeps that domain apart from this family).
// ---------------------------------------------------------------------------

const familyHosts = ['arda.tr', 'blog.arda.tr', 'resume.arda.tr', 'lind.arda.tr'];
const decode = (s) => s.replace(/&#39;/g, "'").replace(/&quot;/g, '"').replace(/&amp;/g, '&');

for (const [name, lang, label] of [
  ['EN', null, 'Other sites by Arda'],
  ['JP', new Jp(), 'Ardaの他のサイト'],
  ['TR', new Tr(), "Arda'nın diğer siteleri"],
]) {
  test(`the footer links the four family sites under a ${name} label`, () => {
    const model = lang ? step(start(), new UserPickedLanguage(lang)) : start();
    const html = to_string(view(model));
    const nav = html.match(/<nav[^>]*class="family ix-small ix-muted"[^>]*>(.*?)<\/nav>/);
    assert.ok(nav, 'a family nav is rendered');
    assert.equal(decode(attr(nav[0], 'aria-label')), label);
    const links = [...nav[1].matchAll(/<a href="([^"]*)">([^<]*)<\/a>/g)].map((m) => [m[1], m[2]]);
    // Link texts are hostnames, the same in every language.
    assert.deepEqual(links, familyHosts.map((h) => ['https://' + h, h]));
  });
}

test('the rendered app has no link to coze.org', () => {
  for (const lang of [null, new Jp(), new Tr()]) {
    const model = lang ? step(start(), new UserPickedLanguage(lang)) : start();
    assert.doesNotMatch(to_string(view(model)), /coze\.org/);
  }
});

// ---------------------------------------------------------------------------
// The bar is the family's (Kara Duman): the emblem and the arda.tr wordmark,
// this site's name, then the sibling sites and this site's own switches.
// ---------------------------------------------------------------------------

const eachLanguage = (check) => {
  for (const lang of [null, new Jp(), new Tr()]) check(to_string(view(lang ? step(start(), new UserPickedLanguage(lang)) : start())));
};
const barOf = (html) => html.match(/<header class="ix-bar">(.*?)<\/header>/)[1];

test('the bar links arda.tr from the emblem and wordmark, then the works, the blog and the résumé', () => {
  eachLanguage((html) => {
    const bar = barOf(html);
    // One link, named by the wordmark; the emblem beside it is decoration.
    const brand = bar.match(/<a class="ix-bar__brand" href="https:\/\/arda\.tr">(.*?)<\/a>/)[1];
    assert.match(brand, /^<img alt class="ix-emblem"[^>]*><svg[^>]*aria-label="arda\.tr"/);
    assert.match(bar, /<span class="ix-bar__site">ask<\/span>/);
    // The family's names for its sites, the same in every language.
    const links = [...bar.matchAll(/<a href="([^"]*)">([^<]*)<\/a>/g)].map((m) => [m[1], m[2]]);
    assert.deepEqual(links, [['https://arda.tr', 'works'], ['https://blog.arda.tr', 'blog'], ['https://resume.arda.tr', 'résumé']]);
  });
});

test('after the sites, pushed to the right: the voice toggle, the languages, the scheme switch', () => {
  eachLanguage((html) => {
    const nav = barOf(html).match(/<div class="ix-bar__nav ix-bar__nav--end">(.*)$/s)[1];
    const order = ['class="bar-sites"', 'class="ix-chip voice-toggle"', 'class="language-toggle"', 'class="ix-scheme ix-navlink"'].map((part) => nav.indexOf(part));
    assert.ok(order.every((at) => at >= 0), 'all four are in the bar');
    assert.deepEqual(order, [...order].sort((a, b) => a - b));
  });
});

test('the inline wordmark is the family logo, in one colour: the text\'s', () => {
  // The outline is pasted into frontend/wordmark.gleam; it must stay the one
  // of the vendored logo file (Grenze Gotisch, outlined).
  const logo = readFileSync(new URL('../../public/brand/logo/wordmark.svg', import.meta.url), 'utf8');
  const inline = to_string(view(start())).match(/<svg[^>]*class="ix-wordmark"[^>]*>.*?<\/svg>/)[0];
  const paths = (svg) => [...svg.matchAll(/<path[^>]*>/g)].map((m) => m[0]);
  assert.equal(attr(inline, 'viewBox'), attr(logo, 'viewBox'));
  assert.equal(paths(inline).length, 1);
  assert.deepEqual(paths(inline).map((tag) => [attr(tag, ' d'), attr(tag, 'transform')]),
    paths(logo).map((tag) => [attr(tag, ' d'), attr(tag, 'transform')]));
  // It follows the page's text colour, on soot and on bone paper.
  assert.equal(attr(paths(inline)[0], 'fill'), 'currentColor');
  assert.doesNotMatch(inline, /--color-accent|#[0-9a-f]{3,8}\b/i);
});

// ---------------------------------------------------------------------------
// The page: one heading (the theme sets an h1 in blackletter, and it is the
// only blackletter here) beside the large ember; the quick prompts; a wisp of
// smoke in the margin. Pictures are the vendored brand artwork.
// ---------------------------------------------------------------------------

test('the page has one heading, in every language, beside the large ember', () => {
  const headings = (html) => [...html.matchAll(/<h1[^>]*>([^<]*)<\/h1>/g)].map((m) => m[1]);
  assert.deepEqual(headings(to_string(view(start()))), ['Ask about Arda']);
  eachLanguage((html) => {
    assert.equal(headings(html).length, 1);
    const intro = html.match(/<header class="intro">(.*?)<\/header>/)[1];
    // The ember is the assistant's picture, not content: screen readers skip it.
    assert.match(intro, /^<span aria-hidden="true" class="ix-mark ix-mark--lg"><\/span><div><h1 class="ix-emerge">/);
    // One secondary line under the heading.
    assert.equal([...intro.matchAll(/<p class="ix-muted">[^<]+<\/p>/g)].length, 1);
  });
});

test('a reply\'s own headings are not page headings in blackletter', () => {
  // Blackletter names the page; a reply's markdown heading stays in the body
  // face (style.css), or every "# Title" from the model would be set like one.
  const css = readFileSync(new URL('../../public/style.css', import.meta.url), 'utf8');
  assert.match(css, /\.txt :is\(h1, h2, h3, h4, h5, h6\) \{[^}]*font-family: var\(--font-family-body\);/);
});

test('the quick prompts are a group named "Try asking", at the end of the conversation', () => {
  for (const [lang, label] of [[null, 'Try asking'], [new Jp(), '質問の例'], [new Tr(), 'Örnek sorular']]) {
    const html = to_string(view(lang ? step(start(), new UserPickedLanguage(lang)) : start()));
    // Inside the scrolling region, after the transcript: the pinned composer
    // keeps only the input, so a phone has room for the conversation.
    const scroller = html.match(/<div[^>]*id="messages-container"[^>]*>(.*)<div class="composer">/s)[1];
    const group = scroller.match(/<div id="quick-topics"><p class="ix-label" id="([^"]*)">([^<]*)<\/p><div aria-labelledby="([^"]*)" class="ix-chips" role="group">(.*?)<\/div>/);
    assert.ok(group, 'a labelled group of chips');
    assert.equal(group[2], label);
    assert.equal(group[3], group[1], 'the label names the group');
    assert.ok(scroller.indexOf('id="quick-topics"') > scroller.indexOf('id="messages"'));
    assert.equal([...group[4].matchAll(/<button class="ix-chip" type="button">[^<]+<\/button>/g)].length, 5);
  }
});

test('the wisp is decoration, on a soot plate', () => {
  // Bone lines: on bone paper they need the plate's soot ground. It says
  // nothing, so it is hidden from screen readers and has an empty alt.
  const wisp = to_string(view(start())).match(/<div aria-hidden="true" class="wisp ix-plate ix-smoke"><img([^>]*)><\/div>/);
  assert.ok(wisp, 'a plate with one picture');
  assert.match(wisp[1], /^ alt class="ix-art ix-art--drift"/);
  assert.match(wisp[1], /src="\/brand\/art\/wisp\.webp"/);
});

test('every picture the page shows is a file in public/', () => {
  const srcs = [...to_string(view(start())).matchAll(/<img[^>]*src="([^"]*)"/g)].map((m) => m[1]);
  assert.deepEqual(srcs, ['/brand/art/emblem.webp', '/brand/art/wisp.webp']);
  for (const src of srcs) assert.ok(existsSync(new URL('../../public' + src, import.meta.url)), src);
});
