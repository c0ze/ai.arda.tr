import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { test } from 'node:test';

// The page's <head> and static <body> come from [tools.lustre.html] in
// gleam.toml. These tests check the index.html that lustre_dev_tools makes of
// it: they parse gleam.toml with the same TOML parser (tom) and run the same
// generator (lustre_dev_tools/build/html), both compiled to JavaScript by
// `gleam build`, so they need no Lustre build (CI runs them before one). A key
// the generator does not read, or a table that swallows one, fails here.

const build = '../build/dev/javascript/';
const tom = await import(build + 'tom/tom.mjs');
const { Project } = await import(build + 'lustre_dev_tools/lustre_dev_tools/project.mjs');
const { generate } = await import(build + 'lustre_dev_tools/lustre_dev_tools/build/html.mjs');
const { None } = await import(build + 'gleam_stdlib/gleam/option.mjs');
const { toList } = await import(build + 'prelude.mjs');

function generatedIndexHtml() {
  const parsed = tom.parse(readFileSync(new URL('../gleam.toml', import.meta.url), 'utf8'));
  assert.equal(parsed.constructor.name, 'Ok', 'gleam.toml parses');
  const lustre = tom.get_table(parsed[0], toList(['tools', 'lustre']));
  assert.equal(lustre.constructor.name, 'Ok', 'gleam.toml has [tools.lustre]');
  // What `lustre/dev build --minify` does: the entry is the project name.
  const project = new Project('frontend', lustre[0], './', 'src', 'dev', 'assets', '.lustre/bin', '.lustre/build', false);
  return generate(project, 'frontend', new None(), true);
}

const html = generatedIndexHtml();

const decode = (s) => s.replace(/&#39;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
const attrs = (tag) => Object.fromEntries([...tag.matchAll(/([a-z:-]+)="([^"]*)"/g)].map((m) => [m[1], decode(m[2])]));
const metas = [...html.matchAll(/<meta [^>]*>/g)].map((m) => attrs(m[0]));
const meta = (kind, name) => {
  const found = metas.filter((m) => m[kind] === name);
  assert.equal(found.length, 1, `one ${kind}=${name} meta`);
  return found[0].content;
};
const body = () => html.match(/<body>(.*)<\/body>/s)[1];

const TITLE = "Arda's AI Construct - Ask about Arda Karaduman";
const DESCRIPTION = 'AI assistant for Arda Karaduman. Answers questions about his work, projects, and music.';

test('the title says whose construct it is, with the surname, everywhere it is shared', () => {
  const titles = [...html.matchAll(/<title>(.*?)<\/title>/g)].map((m) => decode(m[1]));
  assert.deepEqual(titles, [TITLE]);
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

test('the link preview image is described as what it shows: a title card', () => {
  // og-image.png is a card with the site's name and one line about it, not a
  // screenshot: the alt text says what is on it.
  assert.equal(meta('property', 'og:image:alt'), "Arda's AI Construct: an AI assistant that answers questions about Arda.");
});

test('the canonical URL is the site root', () => {
  const canonical = [...html.matchAll(/<link [^>]*>/g)].map((m) => attrs(m[0])).filter((l) => l.rel === 'canonical');
  assert.deepEqual(canonical.map((l) => l.href), ['https://ai.arda.tr/']);
});

test('without JavaScript, the page still links Arda\'s site, résumé and blog', () => {
  const noscript = body().match(/<noscript>(.*?)<\/noscript>/s);
  assert.ok(noscript, 'a <noscript> fallback');
  const hrefs = [...noscript[1].matchAll(/<a href="([^"]*)">/g)].map((m) => m[1]);
  assert.deepEqual(hrefs, ['https://arda.tr', 'https://resume.arda.tr', 'https://blog.arda.tr']);
});

test('the JSON-LD names the site and points at the one Person shared by the family', () => {
  const blocks = [...body().matchAll(/<script type="application\/ld\+json">(.*?)<\/script>/gs)];
  assert.equal(blocks.length, 1, 'one JSON-LD block');
  const ld = JSON.parse(blocks[0][1]);
  assert.equal(ld['@context'], 'https://schema.org');
  assert.equal(ld['@type'], 'WebSite');
  assert.equal(ld['@id'], 'https://ai.arda.tr/#website');
  assert.equal(ld.url, 'https://ai.arda.tr/');
  // arda.tr defines the Person; every family site refers to the same
  // identity: the same @id, name and URL.
  assert.deepEqual(ld.about, {
    '@type': 'Person',
    '@id': 'https://arda.tr/#person',
    name: 'Arda Karaduman',
    url: 'https://arda.tr/',
  });
  assert.deepEqual(ld.author, { '@id': 'https://arda.tr/#person' });
});

test('the page never links coze.org', () => {
  assert.doesNotMatch(html, /coze\.org/);
});

// After a Lustre build (deploy-ui.yml builds before it tests), the file that
// is published must be exactly what these tests checked.
const built = new URL('../../public/index.html', import.meta.url);
test('the built public/index.html is the page checked above', { skip: !existsSync(built) && 'no Lustre build in ../public' }, () => {
  assert.equal(readFileSync(built, 'utf8'), html);
});

// ---------------------------------------------------------------------------
// The family brand ("The Index"). arda.css (the theme's tokens), brand.css
// (the shared patterns), scheme.js (the light/dark pin) and the logo files are
// verbatim copies from the arda.tr repository's brand/ folder: a copy edited
// here would drift from the other three sites. Checked against the sibling
// checkout where there is one (CI has none).
// ---------------------------------------------------------------------------

const publicDir = new URL('../../public/', import.meta.url);
const brandSource = new URL('../../../arda.tr/brand/', import.meta.url);
const BRAND_COPIES = [
  ['brand/arda.css', 'arda.css'],
  ['brand/brand.css', 'brand.css'],
  ['brand/scheme.js', 'scheme.js'],
  ['brand/logo/wordmark.svg', 'logo/wordmark.svg'],
  ['favicon.svg', 'logo/favicon.svg'],
];

test('the brand files are verbatim copies of arda.tr/brand', { skip: !existsSync(brandSource) && 'no ../arda.tr checkout beside this one' }, () => {
  for (const [copy, source] of BRAND_COPIES) {
    assert.ok(readFileSync(new URL(copy, publicDir)).equals(readFileSync(new URL(source, brandSource))),
      `public/${copy} differs from arda.tr/brand/${source}: copy it again, do not edit it here`);
  }
});
