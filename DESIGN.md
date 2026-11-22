# Design: ai.arda.tr

ai.arda.tr follows the family brand **Kara Duman** (`../DESIGN-SYSTEM.md` in the parent
workspace, adopted 2026-11-23; it replaced The Index of the day before, and One Bit Forest
before that). That file is binding. This one records how the site applies it. The design itself
is slide 15 of the brand (`../output/rebrand-kara-duman/15-ai-chat.png`). How the pieces are
wired (files, the boot script, tests) is in [PROJECT.md](PROJECT.md#frontend-design-kara-duman).

## Where it stands in the family

**The assistant is the ember; the smoke is Arda.**

| | ai.arda.tr |
|---|---|
| Blackletter | the page's `h1`, "Ask about Arda", and nothing else (the wordmark is a drawing) |
| Ember | the assistant, the primary button, links, the focus ring, the language in use |
| Artwork | the emblem in the bar, the ember, one wisp in the far right margin |
| Width | one 720px column under a bar as wide as the family's pages (1200px) |
| Scheme | dark (soot) unless the visitor pins light (bone paper) |

## Where the brand comes from

Nothing here is drawn from scratch. Colours, sizes and faces are tokens of the Astryx `arda`
theme (`public/brand/arda.css`); the bar, labels, chips, buttons, the input, the thread, the
ember, the artwork and its plate are classes of `public/brand/brand.css` (prefixed `ix-`). Both
are verbatim copies from the arda.tr repository, as are `scheme.js`, the artwork
(`public/brand/art/`) and the logo. `public/style.css` holds only what is particular to this
site and uses the tokens: no colour and no px font size of its own.

There is no React on this site, so there are no Astryx components: the Lustre view writes the
markup and the classes.

## The page

Pinned to the viewport. Only the conversation scrolls.

1. **The bar.** The round emblem and the `arda.tr` wordmark (inline SVG in the text colour),
   one link to arda.tr, then `ask` in secondary text. Pushed right, in Spectral: `works`,
   `blog`, `résumé`; the voice toggle (a chip that fills when voice is on, and says so in
   words); the language switch `EN / JP / TR` (the one in use is ember and underlined); the
   scheme switch, which names the scheme it would switch to. No rule beneath.
2. **The header.** The large ember (64px) beside the `h1` in Grenze Gotisch (64px; 44px on a
   phone) and one line of secondary text. A 1px rule closes it. It scrolls away with the
   conversation.
3. **The conversation.**
   - The assistant is **the ember, nothing else**: a small one (28px) beside each reply. No
     orb, no robot, no sparkles. Replies are left-aligned, without a bubble, in Spectral at the
     body size; links in them are ember and underlined; their headings stay in Spectral.
   - The visitor's words are right-aligned on the surface colour, 2px corners.
   - An error has no ember. It is set in the family's error colour (`.ix-error`) under a label
     in capitals that says "Error" in the UI language, and it always carries a written message.
   - **Try asking**: a label in Spectral capitals over the quick prompts (outlined chips, 44px
     high). They follow the last message; while the conversation is short they sit at the foot
     of the scroller, just above the input.
4. **The composer.** A hairline across the column, a real text field on the surface colour with
   the primary button (soot on ember; bone on soot on paper), and the disclaimer in small
   secondary text.
5. **The footer.** The family's other sites, as hostnames, in small secondary text.
6. **The wisp.** A thin wisp of smoke in the far right margin, its right edge on the bar's,
   from 1200px of width. It does not scroll and covers nothing. It is bone lines: on the dark
   page it sits on the soot, on bone paper on a soot plate (`.ix-plate`).

## Motion

The ember is the only thing that moves.

- While a reply is awaited or written it glows in a slow pulse (`data-busy`), and "Thinking…"
  stands beside it until the first words arrive.
- While the voice speaks, it glows with the loudness (`--ix-level`, 0 to 1), and the reply
  appears as it is spoken.
- Under `prefers-reduced-motion` it does not pulse: it is only brighter while busy, and the
  words carry the state. The wisp is still.

## Scheme

Dark is the default here. The switch pins light, and switching back to dark clears the pin.
On bone paper the emblem and the ember keep their soot ground (round), and the wisp its plate.
High contrast is the visitor's `prefers-contrast: more` (hairlines and secondary text darken),
not a separate rendition. A rendition stored by an earlier design becomes light or dark by its
role.

## Language

English, Japanese, Turkish. Japanese is set in Zen Antique through `:lang(ja)` (brand.css),
never in blackletter: the Japanese `h1` is Heading 2's size at weight 400. A Japanese message
on an English or Turkish page is marked `lang="ja"`, so it is set the same way. The bar's
`works`, `blog`, `résumé` and `ask`, and the footer's hostnames, are the same in every language.

## Small screens

- Up to 720px wide: 20px side margins, and the bar drops the sibling sites (the footer has
  them). Up to 480px the bar is two lines: the brand and the voice toggle, then the languages
  and the scheme switch.
- Short screens give their room to the conversation: the footer goes below 640px of height; in
  phone landscape the bar is one line.
- Nothing scrolls sideways. A wide table or a code block scrolls inside the reply.
- Controls are 48px high (chips 44px); nothing is set below 18px.

## Accessibility

One `h1`. Every control has a visible label that its accessible name contains. Focus is the
theme's 2px ring (ember on soot, soot on paper), 3px off. Text passes WCAG AA on every
background in both schemes. The emblem, the embers and the wisp are decoration: hidden from
screen readers. The transcript is a `role="log"` that does not announce itself; a finished reply
is announced once, and what the assistant is doing is said by a status line.
