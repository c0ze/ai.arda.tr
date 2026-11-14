import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

// The page's <head> and static <body> come from [tools.lustre.html] in
// gleam.toml; lustre_dev_tools copies them into public/index.html as they are
// (the `body` string verbatim). These tests read the config, so they run
// without a Lustre build.

const toml = readFileSync(new URL('../gleam.toml', import.meta.url), 'utf8');
const section = toml.split('[tools.lustre.html]')[1];

// The values are one-line TOML basic strings; their escapes (\" and \\) read
// the same as JSON's.
const unquote = (literal) => JSON.parse(literal);
const STRING = '("(?:[^"\\\\]|\\\\.)*")';

const topLevel = (key) => {
  const all = [...section.matchAll(new RegExp('^' + key + ' = ' + STRING, 'gm'))];
  assert.equal(all.length, 1, `one ${key} in [tools.lustre.html]`);
  return unquote(all[0][1]);
};
const meta = (kind, name) => {
  const all = [...section.matchAll(new RegExp('\\{ ' + kind + ' = "' + name + '", content = ' + STRING + ' \\}', 'g'))];
  assert.equal(all.length, 1, `one ${kind}=${name} meta`);
  return unquote(all[0][1]);
};

const TITLE = "Arda's AI Construct - Ask about Arda Karaduman";
const DESCRIPTION = "An AI chat that answers questions about Arda Karaduman's work, projects and music.";

test('the title says whose construct it is, with the surname, everywhere it is shared', () => {
  assert.equal(topLevel('title'), TITLE);
  assert.equal(meta('property', 'og:title'), TITLE);
  assert.equal(meta('name', 'twitter:title'), TITLE);
});

test('one description says what the page is, and does not promise to pass messages on', () => {
  // The contact handoff is not configured in production, so the page must
  // not claim it in search results or link previews.
  for (const [kind, name] of [['name', 'description'], ['property', 'og:description'], ['name', 'twitter:description']]) {
    const text = meta(kind, name);
    assert.equal(text, DESCRIPTION, name);
    assert.doesNotMatch(text, /pass|message/i, name);
  }
});

test('the page config never links coze.org', () => {
  assert.doesNotMatch(section, /coze\.org/);
});
