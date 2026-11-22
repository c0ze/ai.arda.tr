# Design: ai.arda.tr

ai.arda.tr follows the family brand **The Index** (`../DESIGN-SYSTEM.md` in the parent
workspace, adopted 2026-11-22; it replaced One Bit Forest). That file is binding. This one
records how the site applies it. How the pieces are wired (files, the boot script, tests) is
in [PROJECT.md](PROJECT.md#frontend-design-the-index).

## Where it stands in the family

Level 2 of 4: **"The index, asked."**

| | ai.arda.tr |
|---|---|
| Display type | the wordmark only |
| Vermilion | the dot (the wordmark's full stop, the assistant's square) and the primary button |
| Imagery | none |
| Density | one column, 720px wide (`--ix-max: 45rem`) |
| Scheme | dark unless the visitor pins light |

## Where the brand comes from

Nothing here is drawn from scratch. Colours, sizes and faces are tokens of the Astryx `arda`
theme (`public/brand/arda.css`); the bar, labels, chips, buttons, the input, the thread and the
square are classes of `public/brand/brand.css` (prefixed `ix-`). Both are verbatim copies from
the arda.tr repository, as are `scheme.js` and the logo. `public/style.css` holds only what is
particular to this site and uses the tokens: no colour and no px font size of its own.

There is no React on this site, so there are no Astryx components: the Lustre view writes the
markup and the classes.

## The page

One column, left-aligned, pinned to the viewport. Only the conversation scrolls.

1. **The bar.** The `arda.tr` wordmark (inline SVG: letters in the text colour, the full stop in
   vermilion), linking arda.tr, then `/ ask` in muted mono. At right, in mono blue: `index`,
   `blog`, `résumé`; the language switch `EN / JP / TR` (the one in use is in the text colour
   and underlined); the scheme switch, which names the scheme it would switch to. A 1px rule
   beneath.
2. **The heading.** The assistant's title, set as Heading 3 in IBM Plex Sans (22/28, 600), and
   one line of small muted text. It is modest on purpose, and it scrolls away with the
   conversation.
3. **The conversation.** A 2px ink rule opens it, as it opens every list in the family.
   - The assistant is **the square dot from the wordmark, nothing else**: a 24px vermilion
     square beside each reply. No orb, no robot, no sparkles. Replies are left-aligned, without
     a bubble, in IBM Plex Sans; links in them are blue and underlined.
   - The visitor's words are right-aligned in a square sunken box.
   - An error has no square. It is set in the theme's error colour (crimson, not vermilion)
     under a mono label that says "Error" in the UI language.
4. **The composer.** Quick prompts as square chips; a real text field (2px radius) with the
   vermilion primary button; under it the voice toggle (a chip that fills when voice is on, and
   says so in words) and the disclaimer in small muted text. A 1px rule above.
5. **The footer.** The family's other sites, as hostnames, in small text.

## Motion

The square is the only thing that moves.

- While a reply is awaited or written it blinks (`data-busy`), and "Thinking…" stands beside it
  until the first words arrive.
- While the voice speaks, it swells with the loudness (`--ix-level`, 0 to 1), and the reply
  appears as it is spoken.
- Under `prefers-reduced-motion` it does neither: it dims while busy, and the words carry the
  state.

## Scheme

Dark is the default here; the rest of the family follows the system. The switch pins light, and
switching back to dark clears the pin. High contrast is the visitor's `prefers-contrast: more`
(hairlines and muted text darken), not a separate rendition. The four One Bit Forest renditions
are gone; a stored one becomes light or dark by its role.

## Language

English, Japanese, Turkish. In Japanese the body is 16/29 in Noto Sans JP (brand.css,
`:lang(ja)`), and labels take Noto Sans JP too, because IBM Plex Mono has no kana or kanji. A
Japanese message on an English or Turkish page is marked `lang="ja"`, so it is set the same way.
The bar's `index`, `blog`, `résumé` and `/ ask`, and the footer's hostnames, are the same in
every language.

## Small screens

- Below 640px wide: 24px side margins, and the bar keeps the wordmark, the languages and the
  scheme switch (the sibling sites are in the footer).
- Short screens give their room to the conversation: the footer goes below 640px of height,
  the quick prompts below 576px.
- Nothing scrolls sideways. A wide table or a code block scrolls inside the reply.
- Targets are at least 24px high, 44px for a finger.

## Accessibility

One `h1`. Every control has a visible label that its accessible name contains. Focus is the
theme's 2px blue ring, 2px off. Text passes WCAG AA on every background in both schemes. The
transcript is a `role="log"` that does not announce itself; a finished reply is announced once,
and what the assistant is doing is said by a status line.
