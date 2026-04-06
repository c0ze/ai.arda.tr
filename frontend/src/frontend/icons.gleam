//// Inline SVG icons, copied byte-for-byte from the old `index.html`.
////
//// We render them via `element.unsafe_raw_html` wrapped in a `<span>` so
//// we don't have to rebuild each <path>/<line>/<circle> through the
//// typed Lustre SVG API. The SVG literals below are trusted, static
//// constants — no XSS surface.

import lustre/attribute
import lustre/element.{type Element}

fn raw(class: String, svg: String) -> Element(msg) {
  element.unsafe_raw_html("", "span", [attribute.class(class)], svg)
}

pub fn moon() -> Element(msg) {
  raw(
    "icon-slot",
    "<svg class=\"icon-moon\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z\"/></svg>",
  )
}

pub fn sun() -> Element(msg) {
  raw(
    "icon-slot",
    "<svg class=\"icon-sun\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"12\" cy=\"12\" r=\"5\"/><line x1=\"12\" y1=\"1\" x2=\"12\" y2=\"3\"/><line x1=\"12\" y1=\"21\" x2=\"12\" y2=\"23\"/><line x1=\"4.22\" y1=\"4.22\" x2=\"5.64\" y2=\"5.64\"/><line x1=\"18.36\" y1=\"18.36\" x2=\"19.78\" y2=\"19.78\"/><line x1=\"1\" y1=\"12\" x2=\"3\" y2=\"12\"/><line x1=\"21\" y1=\"12\" x2=\"23\" y2=\"12\"/><line x1=\"4.22\" y1=\"19.78\" x2=\"5.64\" y2=\"18.36\"/><line x1=\"18.36\" y1=\"5.64\" x2=\"19.78\" y2=\"4.22\"/></svg>",
  )
}

pub fn dracula() -> Element(msg) {
  raw(
    "icon-slot",
    "<svg class=\"icon-dracula\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2z\"/><path d=\"M8 14l2-4 2 4\"/><path d=\"M12 14l2-4 2 4\"/></svg>",
  )
}

pub fn terminal() -> Element(msg) {
  raw(
    "welcome-svg",
    "<svg width=\"44\" height=\"44\" viewBox=\"0 0 44 44\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2\" y=\"6\" width=\"40\" height=\"32\" rx=\"4\" ry=\"4\"/><line x1=\"2\" y1=\"14\" x2=\"42\" y2=\"14\"/><circle cx=\"8\" cy=\"10\" r=\"1.5\" fill=\"currentColor\" stroke=\"none\"/><circle cx=\"13\" cy=\"10\" r=\"1.5\" fill=\"currentColor\" stroke=\"none\"/><circle cx=\"18\" cy=\"10\" r=\"1.5\" fill=\"currentColor\" stroke=\"none\"/><path d=\"M10 23l5 4-5 4\"/><line x1=\"19\" y1=\"31\" x2=\"32\" y2=\"31\"/></svg>",
  )
}

pub fn briefcase() -> Element(msg) {
  raw(
    "topic-svg",
    "<svg width=\"15\" height=\"15\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2\" y=\"7\" width=\"20\" height=\"14\" rx=\"2\" ry=\"2\"/><path d=\"M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16\"/></svg>",
  )
}

pub fn cap() -> Element(msg) {
  raw(
    "topic-svg",
    "<svg width=\"15\" height=\"15\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M22 10v6M2 10l10-5 10 5-10 5z\"/><path d=\"M6 12v5c3 3 9 3 12 0v-5\"/></svg>",
  )
}

pub fn code() -> Element(msg) {
  raw(
    "topic-svg",
    "<svg width=\"15\" height=\"15\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><polyline points=\"16 18 22 12 16 6\"/><polyline points=\"8 6 2 12 8 18\"/></svg>",
  )
}

pub fn calendar() -> Element(msg) {
  raw(
    "topic-svg",
    "<svg width=\"15\" height=\"15\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"3\" y=\"4\" width=\"18\" height=\"18\" rx=\"2\" ry=\"2\"/><line x1=\"16\" y1=\"2\" x2=\"16\" y2=\"6\"/><line x1=\"8\" y1=\"2\" x2=\"8\" y2=\"6\"/><line x1=\"3\" y1=\"10\" x2=\"21\" y2=\"10\"/></svg>",
  )
}

pub fn info() -> Element(msg) {
  raw(
    "topic-svg",
    "<svg width=\"15\" height=\"15\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"12\" cy=\"12\" r=\"10\"/><line x1=\"12\" y1=\"16\" x2=\"12\" y2=\"12\"/><line x1=\"12\" y1=\"8\" x2=\"12.01\" y2=\"8\"/></svg>",
  )
}

pub fn send() -> Element(msg) {
  raw(
    "send-svg",
    "<svg width=\"18\" height=\"18\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><line x1=\"22\" y1=\"2\" x2=\"11\" y2=\"13\"/><polygon points=\"22 2 15 22 11 13 2 9 22 2\"/></svg>",
  )
}
