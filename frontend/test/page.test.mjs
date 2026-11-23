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
const publicDir = new URL('../../public/', import.meta.url);

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

// ---------------------------------------------------------------------------
// The scheme and the theme are on <html> before first paint. ai.arda.tr is
// dark unless the visitor pins light; the pin lives under "theme", the key
// the earlier designs used, so a returning visitor keeps their choice.
// ---------------------------------------------------------------------------

const head = html.match(/<head>(.*)<\/head>/s)[1];
const scheme = await import('../../public/brand/scheme.js');
const BOOT = scheme.bootSnippet('theme', 'dark') + 'document.documentElement.setAttribute("data-astryx-theme","arda");';
// Classic inline scripts: they run as the parser meets them, before any paint.
const inlineScripts = [...head.matchAll(/<script>(.*?)<\/script>/gs)].map((m) => m[1]);

test('the boot script is scheme.js\'s own snippet for this site, then the theme scope', () => {
  // Pasted into gleam.toml; when public/brand/scheme.js changes, paste again.
  assert.deepEqual(inlineScripts, [BOOT]);
  // It rewrites the color-scheme meta, which must already be parsed.
  const metaAt = head.indexOf('name="color-scheme"');
  assert.ok(metaAt >= 0 && metaAt < head.indexOf('<script>'), 'the color-scheme meta comes before the script');
  assert.equal(meta('name', 'color-scheme'), 'dark');
});

// Runs the page's own inline script against a stand-in for the browser.
function boot(stored, { blocked = false } = {}) {
  const store = new Map(stored === null ? [] : [['theme', stored]]);
  const root = new Map();
  const colorScheme = new Map([['content', 'dark']]);
  const localStorage = {
    getItem: (k) => { if (blocked) throw new Error('blocked'); return store.has(k) ? store.get(k) : null; },
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  };
  const document = {
    documentElement: { setAttribute: (k, v) => root.set(k, v) },
    querySelector: (selector) => (selector === 'meta[name="color-scheme"]'
      ? { setAttribute: (k, v) => colorScheme.set(k, v) } : null),
  };
  new Function('localStorage', 'document', inlineScripts[0])(localStorage, document);
  return { theme: root.get('data-theme'), scope: root.get('data-astryx-theme'), meta: colorScheme.get('content'), stored: store.get('theme') };
}

test('a first visit is dark, and nothing is stored', () => {
  assert.deepEqual(boot(null), { theme: 'dark', scope: 'arda', meta: 'dark', stored: undefined });
});

test('a pinned light scheme is applied before first paint', () => {
  assert.deepEqual(boot('light'), { theme: 'light', scope: 'arda', meta: 'light', stored: 'light' });
});

test('a rendition stored by the earlier designs becomes light or dark by its role', () => {
  for (const [old, now] of [['xerox', 'light'], ['xerox-hc', 'light'], ['paper', 'light'],
    ['night', 'dark'], ['night-hc', 'dark'], ['carbon', 'dark']]) {
    assert.deepEqual(boot(old), { theme: now, scope: 'arda', meta: now, stored: now }, old);
  }
  // An id nobody knows is dropped, and the page is dark.
  assert.deepEqual(boot('purple'), { theme: 'dark', scope: 'arda', meta: 'dark', stored: undefined });
});

test('with storage blocked the page is still dark and themed', () => {
  assert.deepEqual(boot(null, { blocked: true }), { theme: 'dark', scope: 'arda', meta: 'dark', stored: undefined });
});

test('scheme.js is loaded for the switch before the app starts', () => {
  // ffi.mjs reads window.ardaScheme. Module scripts run in document order, so
  // this one must come before the app's.
  const modules = [...head.matchAll(/<script([^>]*)>(.*?)<\/script>/gs)].filter((m) => /type="module"/.test(m[1]));
  assert.equal(modules.length, 3);
  assert.match(modules[0][2], /^import \* as scheme from '\/brand\/scheme\.js\?v=\d+';window\.ardaScheme=scheme;$/);
  // the wisp's film: the family's smoke.js, started once the app has drawn the wisp
  assert.match(modules[1][2], /^import\{startSmoke\}from'\/brand\/smoke\.js\?v=\d+';/);
  assert.match(modules[2][1], /src="\/frontend\.js"/);
});

// ---------------------------------------------------------------------------
// The stylesheets: the layer order first, then the fonts, the theme's tokens,
// the family patterns, and last this site's own rules.
// ---------------------------------------------------------------------------

const styleTags = [...head.matchAll(/<style>(.*?)<\/style>|<link [^>]*rel="stylesheet"[^>]*>/gs)];
const sheetHrefs = styleTags.filter((m) => m[0].startsWith('<link')).map((m) => attrs(m[0]).href);

test('the layer order is declared before any stylesheet', () => {
  // Otherwise the first stylesheet to mention a layer decides the order.
  assert.equal(styleTags[0][1], '@layer reset, astryx-base, astryx-theme, brand;');
  assert.equal(styleTags.filter((m) => m[0].startsWith('<style')).length, 1);
});

test('the theme, the family patterns and the site styles load in that order', () => {
  assert.deepEqual(sheetHrefs.slice(1).map((href) => href.replace(/\?v=\d+$/, '')),
    ['/brand/arda.css', '/brand/brand.css', '/style.css']);
  // Each carries a cache-busting number to bump when the file changes.
  for (const href of sheetHrefs.slice(1)) assert.match(href, /\?v=\d+$/);
});

test('the fonts are the family\'s four faces, swapped in, from a preconnected host', () => {
  const fonts = new URL(sheetHrefs[0]);
  assert.equal(fonts.origin + fonts.pathname, 'https://fonts.googleapis.com/css2');
  // Exactly the weights the brand sets type in: a face or weight that is not
  // loaded is faked by the browser, and one that is not used is dead weight.
  assert.deepEqual(fonts.searchParams.getAll('family'), [
    'Grenze Gotisch:wght@700;800;900', // blackletter: the page's heading (the wordmark is outlines)
    'JetBrains Mono:wght@400;700', // code in replies
    'Spectral:ital,wght@0,400;0,600;1,400', // everything else
    'Zen Antique', // the UI has Japanese; one weight, 400
  ]);
  assert.equal(fonts.searchParams.get('display'), 'swap');
  const preconnect = [...html.matchAll(/<link [^>]*>/g)].map((m) => attrs(m[0]).href === undefined ? null : m[0])
    .filter((tag) => tag && /rel="preconnect"/.test(tag));
  assert.deepEqual(preconnect.map((tag) => attrs(tag).href), ['https://fonts.googleapis.com', 'https://fonts.gstatic.com']);
  // Font files are fetched without credentials.
  assert.match(preconnect[1], /\bcrossorigin\b/);
});

test('the browser\'s own chrome is soot, the ground of the default scheme', () => {
  assert.equal(meta('name', 'theme-color'), '#0D0C0A');
});

test('the assistant has its picture: style.css points brand.css at the vendored ember', () => {
  // brand.css draws `.ix-mark` from --ix-ember-art; without it the assistant
  // is an empty soot disc.
  const css = readFileSync(new URL('style.css', publicDir), 'utf8');
  const art = css.match(/:root\s*\{[^}]*--ix-ember-art:\s*url\("(\/[^"]*)"\)/);
  assert.ok(art, '--ix-ember-art is set on :root, as a root-relative url');
  assert.equal(art[1], '/brand/art/ember.webp');
  assert.ok(existsSync(new URL('.' + art[1], publicDir)));
});

test('style.css is written on the theme\'s tokens: no colour and no font size of its own', () => {
  const css = readFileSync(new URL('style.css', publicDir), 'utf8').replace(/\/\*.*?\*\//gs, '');
  assert.deepEqual(css.match(/#[0-9a-f]{3,8}\b|\b(?:rgba?|hsla?|oklch|oklab)\(/gi) ?? [], [], 'a colour that is not a token');
  assert.deepEqual(css.match(/font(?:-size)?\s*:[^;]*\d(?:px|pt)\b[^;]*/gi) ?? [], [], 'a font size in px');
  // The few tokens it defines are the ones the theme leaves to the Astryx base.
  assert.match(css, /@layer astryx-base\s*\{/);
});

// After a Lustre build (deploy-ui.yml builds before it tests), the file that
// is published must be exactly what these tests checked.
const built = new URL('../../public/index.html', import.meta.url);
test('the built public/index.html is the page checked above', { skip: !existsSync(built) && 'no Lustre build in ../public' }, () => {
  assert.equal(readFileSync(built, 'utf8'), html);
});

// ---------------------------------------------------------------------------
// The family brand ("Kara Duman"). arda.css (the theme's tokens), brand.css
// (the shared patterns), scheme.js (the light/dark pin), the artwork and the
// logo files are verbatim copies from the arda.tr repository's brand/ folder:
// a copy edited here would drift from the other three sites. Checked against
// the sibling checkout where there is one (CI has none).
// ---------------------------------------------------------------------------

const brandSource = new URL('../../../arda.tr/brand/', import.meta.url);
const BRAND_COPIES = [
  ['brand/arda.css', 'arda.css'],
  ['brand/brand.css', 'brand.css'],
  ['brand/scheme.js', 'scheme.js'],
  ['brand/smoke.js', 'smoke.js'],
  ['brand/art/wisp-smoke.mp4', 'art/wisp-smoke.mp4'],
  ['brand/art/emblem.webp', 'art/emblem.webp'],
  ['brand/art/ember.webp', 'art/ember.webp'],
  ['brand/art/wisp.webp', 'art/wisp.webp'],
  ['brand/logo/wordmark.svg', 'logo/wordmark.svg'],
  ['favicon.svg', 'logo/favicon.svg'],
];

test('the brand files are verbatim copies of arda.tr/brand', { skip: !existsSync(brandSource) && 'no ../arda.tr checkout beside this one' }, () => {
  for (const [copy, source] of BRAND_COPIES) {
    assert.ok(readFileSync(new URL(copy, publicDir)).equals(readFileSync(new URL(source, brandSource))),
      `public/${copy} differs from arda.tr/brand/${source}: copy it again, do not edit it here`);
  }
});
