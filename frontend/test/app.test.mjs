import assert from 'node:assert/strict';
import { test } from 'node:test';
import { init, update, UserTypedInput, UserClickedSend, UserPickedLanguage, StreamEventReceived } from '../build/dev/javascript/frontend/frontend.mjs';
import { Jp } from '../build/dev/javascript/frontend/frontend/i18n.mjs';

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
