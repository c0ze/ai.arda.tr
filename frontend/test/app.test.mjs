import assert from 'node:assert/strict';
import { test } from 'node:test';
import { init, update, UserTypedInput, UserClickedSend, UserPickedLanguage, StreamEventReceived } from '../build/dev/javascript/frontend/frontend.mjs';
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
  const html = to_string(view(start()));
  // The voice toggle is named by its content: a hidden label plus the visible word.
  const voice = html.match(/<button[^>]*class="voice-toggle"[^>]*>(.*?)<\/button>/);
  assert.equal(attr(voice[0], 'aria-label'), undefined);
  assert.match(voice[1], /Read replies aloud/);
  assert.match(voice[1], /<span class="voice-word"> On<\/span>/);
});

test('labels follow the UI language', () => {
  const html = to_string(view(step(start(), new UserPickedLanguage(new Jp()))));
  assert.equal(attr(tagWith(html, 'class="language-toggle"'), 'aria-label'), '言語');
  assert.match(attr(tagWith(html, 'class="lang-btn active"'), 'aria-label'), /^JP/);
  assert.match(attr(tagWith(html, 'class="lang-btn active"'), 'aria-label'), /日本語/);
  assert.match(attr(tagWith(html, 'class="theme-toggle"'), 'aria-label'), /^テーマ/);
  assert.match(attr(tagWith(html, 'id="send-btn"'), 'aria-label'), /送信/);
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
    const nav = html.match(/<nav[^>]*class="input-hint family"[^>]*>(.*?)<\/nav>/);
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
