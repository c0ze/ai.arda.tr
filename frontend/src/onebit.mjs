/*
 * onebit.js: the 1-bit core shared by arda.tr, blog.arda.tr, resume.arda.tr and ai.arda.tr.
 *
 * There is no shared package: each site keeps its own copy of this file. Keep the copies identical;
 * change it here first (design-previews/onebit/onebit.js), then copy it to the sites.
 *
 * Colours come from CSS custom properties on the canvas (or its ancestors), re-read every frame so theme
 * switches apply immediately:
 *   --ob-ink     pixels that are "on"      (hex, e.g. #e4e0d4)
 *   --ob-ground  pixels that are "off"     (hex)
 *   --ob-signal  the site's accent         (hex)
 *
 * Every animation pauses while its canvas is off-screen or the tab is hidden, and draws a single still
 * frame under prefers-reduced-motion.
 */

/* ---------------------------------------------------------------- primitives */

export const B8 = Float32Array.from(
  [0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
   3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25, 15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21],
  v => (v + 0.5) / 64,
);

export const reducedMotion = () =>
  typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

export function rng(seed) {
  let s = seed >>> 0 || 1;
  return () => ((s = (Math.imul(s ^ (s >>> 15), 2246822519) + 0x9e3779b9) >>> 0) / 4294967296);
}

export function hash(str) {
  let h = 2166136261;
  for (const c of String(str)) { h ^= c.codePointAt(0); h = Math.imul(h, 16777619); }
  return h >>> 0;
}

function rgb(c, fallback) {
  c = (c || "").trim();
  if (!c) return fallback;
  if (c[0] === "#") {
    let h = c.slice(1);
    if (h.length === 3) h = [...h].map(x => x + x).join("");
    const n = parseInt(h.slice(0, 6), 16);
    return [n >> 16, (n >> 8) & 255, n & 255];
  }
  const m = c.match(/[\d.]+/g);
  return m && m.length >= 3 ? m.slice(0, 3).map(Number) : fallback;
}

function palette(el) {
  const cs = getComputedStyle(el);
  const ground = rgb(cs.getPropertyValue("--ob-ground"), [6, 7, 8]);
  return {
    ink: rgb(cs.getPropertyValue("--ob-ink"), [228, 224, 212]),
    ground,
    signal: rgb(cs.getPropertyValue("--ob-signal"), [198, 255, 58]),
    // on a light ground ink is dark, so pictures must print as positives (ink = darkness)
    light: (0.299 * ground[0] + 0.587 * ground[1] + 0.114 * ground[2]) / 255 > 0.5,
  };
}

/* periodic 1D value noise, period 1 in u; n cells per period */
function pnoise(seed, n) {
  const R = rng(seed), v = Array.from({ length: n }, R);
  return u => {
    const x = (((u % 1) + 1) % 1) * n, i = Math.floor(x), f = x - i, t = f * f * (3 - 2 * f);
    return v[i % n] + (v[(i + 1) % n] - v[i % n]) * t;
  };
}
function pfbm(seed, n) {
  const a = pnoise(seed, n), b = pnoise(seed + 1, n * 2), c = pnoise(seed + 2, n * 4), d = pnoise(seed + 3, n * 8);
  return u => a(u) * 0.55 + b(u) * 0.27 + c(u) * 0.13 + d(u) * 0.05;
}

/* periodic 2D value noise tile, w×h cells, sampled in cell units */
function tile2(seed, gw, gh) {
  const R = rng(seed), a = Array.from({ length: gw * gh }, R), s = t => t * t * (3 - 2 * t);
  return (x, y) => {
    const xf = Math.floor(x), yf = Math.floor(y), fx = s(x - xf), fy = s(y - yf);
    const x0 = ((xf % gw) + gw) % gw, y0 = ((yf % gh) + gh) % gh, x1 = (x0 + 1) % gw, y1 = (y0 + 1) % gh;
    const A = a[y0 * gw + x0], B = a[y0 * gw + x1], C = a[y1 * gw + x0], D = a[y1 * gw + x1];
    return A + (B - A) * fx + (C - A) * fy + (A - B - C + D) * fx * fy;
  };
}

/* the pine: half-width at dy below the tip of a tree of height h and base width w */
function pineHalf(dy, h, w) {
  if (dy < 0 || dy > h) return -1;
  const t = dy / h, tiers = Math.max(4, Math.round(h / 7)), f = (t * tiers) % 1;
  if (t > 0.94) return Math.max(0.6, w * 0.05);
  return w * 0.5 * Math.pow(t, 0.85) * (0.42 + 0.58 * f);
}

/* ---------------------------------------------------------------- lifecycle */

function animate(canvas, step, { fps = 24, still = false } = {}) {
  const reduce = reducedMotion() || still;
  let raf = 0, last = 0, running = false, visible = true, dead = false;
  const t0 = performance.now(), now = () => (performance.now() - t0) / 1000;
  const tick = ts => {
    raf = requestAnimationFrame(tick);
    if (ts - last < 1000 / fps - 2) return;
    last = ts;
    step(now());
  };
  const sync = () => {
    const want = !dead && !reduce && visible && !document.hidden;
    if (want && !running) { running = true; raf = requestAnimationFrame(tick); }
    else if (!want && running) { running = false; cancelAnimationFrame(raf); }
  };
  const io = typeof IntersectionObserver === "function"
    ? new IntersectionObserver(es => { visible = es[es.length - 1].isIntersecting; sync(); })
    : null;
  io?.observe(canvas);
  document.addEventListener("visibilitychange", sync);
  step(0);
  sync();
  return {
    redraw: () => step(now()),
    get reduced() { return reduce; },
    destroy() { dead = true; sync(); io?.disconnect(); document.removeEventListener("visibilitychange", sync); },
  };
}

function onResize(canvas, fn) {
  if (typeof ResizeObserver !== "function") return () => {};
  let w = canvas.clientWidth, h = canvas.clientHeight, t = 0;
  const ro = new ResizeObserver(() => {
    if (canvas.clientWidth === w && canvas.clientHeight === h) return;
    w = canvas.clientWidth; h = canvas.clientHeight;
    clearTimeout(t); t = setTimeout(fn, 120);
  });
  ro.observe(canvas);
  return () => ro.disconnect();
}

/* ---------------------------------------------------------------- forest: the scrolling night scene */

/**
 * A moonlit spruce valley in fog, scrolling sideways in parallax, ordered-dithered to 1 bit.
 * opts: seed, speed (1 = default drift), maxWidth (low-res pixel cap, for CPU), onMast(x, y) in CSS px.
 */
export function forest(canvas, opts = {}) {
  const o = { seed: 2004, speed: 1, maxWidth: 640, px: 2, fps: 30, onMast: null, ...opts };
  let SW, SH, VH, OY, Z, P, PX, sky, strips, fog, E, img, ctx, mast;
  const FGW = 256, FGH = 96;

  function build() {
    const W = Math.max(1, canvas.clientWidth), H = Math.max(1, canvas.clientHeight);
    PX = Math.max(o.px, W / o.maxWidth);
    SW = Math.ceil(W / PX); SH = Math.ceil(H / PX); P = SW * 2;
    canvas.width = SW; canvas.height = SH;
    ctx = canvas.getContext("2d");
    img = ctx.createImageData(SW, SH);
    // The scene is laid out in a band VH tall, anchored to the bottom; on portrait screens the band is
    // landscape-shaped and plain night sky fills the space above it. Z is the scale of trees and moon.
    VH = Math.min(SH, Math.round(SW * 1.1)); OY = SH - VH; Z = Math.min(VH, SW / 1.3);
    const R = rng(o.seed), U = Z / 300;

    // sky: haze, stars, moon + halo (static)
    sky = new Float32Array(SW * SH);
    const moon = { x: SW * 0.8, y: OY + VH * 0.3, r: Z * 0.075 }, crater = tile2(o.seed + 5, 8, 8);
    for (let y = 0; y < SH; y++) for (let x = 0; x < SW; x++) {
      let L = Math.min(0.34, 0.34 * Math.pow(Math.max(0, (y - OY) / VH - 0.22) / 0.36, 1.7));
      if (y < OY + VH * 0.5 && R() < 0.0022) L = 0.5 + R() * 0.5;
      const dm = Math.hypot(x - moon.x, y - moon.y);
      if (dm < moon.r) L = 0.9 - 0.25 * crater(x / moon.r * 4, y / moon.r * 4) * (1 - dm / moon.r);
      else L += 0.2 * Math.exp(-(dm - moon.r) / (Z * 0.05));
      sky[y * SW + x] = L;
    }

    // parallax strips, near → far. Each is P wide (wraps). 255 = transparent,
    // <128 = solid (lum v/127, tree fog weight), ≥128 = mist/ridge (lum (v-128)/126, mist fog weight)
    const mk = (y0, speed, treeFw, mistFw) => ({ y0, speed, treeFw, mistFw, a: new Uint8Array(P * (SH - y0)).fill(255) });
    const put = (s, x, y, v) => { if (y < s.y0 || y >= SH) return; s.a[(y - s.y0) * P + (((Math.round(x) % P) + P) % P)] = v; };
    const mist = L => 128 + Math.round(Math.max(0, Math.min(1, L)) * 126);
    const solid = L => Math.round(Math.max(0, Math.min(1, L)) * 127);

    const ridgeF = pfbm(o.seed + 66, 7), ridge2F = pfbm(o.seed + 67, 11);
    const ridge = mk(Math.floor(OY + VH * 0.3), 1.5, 0.5, 0.5), ridge2 = mk(Math.floor(OY + VH * 0.4), 3.5, 0.5, 0.5);
    for (let x = 0; x < P; x++) {
      const ry = Math.floor(OY + VH * (0.5 + 0.2 * (ridgeF(x / P) - 0.5) * 2.2));
      for (let y = ry; y < SH; y++) put(ridge, x, y, mist(0.5 + 0.12 * Math.max(0, 1 - (y - ry) / (VH * 0.04))));
      const r2 = Math.floor(OY + VH * (0.58 + 0.14 * (ridge2F(x / P) - 0.5) * 2));
      for (let y = r2; y < SH; y++) put(ridge2, x, y, mist(0.42 + 0.12 * Math.min(1, (y - r2) / (VH * 0.08))));
    }
    // the radio mast, on the highest point of the far ridge
    let best = 1e9, bx = 0;
    for (let x = 0; x < P; x++) { const ry = OY + VH * (0.5 + 0.2 * (ridgeF(x / P) - 0.5) * 2.2); if (ry < best) { best = ry; bx = x; } }
    mast = { x: bx, top: Math.floor(best - Z * 0.12), base: Math.floor(best) };
    for (let y = mast.top; y < mast.base; y++) {
      const k = (y - mast.top) / (mast.base - mast.top);
      put(ridge, bx, y, solid(0.05));
      if (y % 4 === 0 && k > 0.1) { put(ridge, bx - 1, y, solid(0.05)); put(ridge, bx + 1, y + 2, solid(0.05)); }
    }

    // tree layers: [base y, tree lum, spacing, min h, max h, width, mist fog, tree fog, mist lum, speed, clustered]
    const defs = [
      [0.7, 0.16, 4.5, 0.05, 0.11, 0.4, 0.35, 0.12, 0.64, 7, false],
      [0.84, 0.02, 8, 0.1, 0.2, 0.42, 0.25, 0, 0.52, 15, false],
      [1.02, 0, 11, 0.24, 0.4, 0.3, 0, 0, 0, 32, true],
    ];
    const layers = defs.map(([by, lum, step, h0, h1, wf, mfw, tfw, floor, speed, clustered]) => {
      const baseY = Math.floor(OY + VH * by), top = Math.floor(OY + VH * by - Z * h1 * 1.4);
      const s = mk(Math.max(0, top), speed, tfw, mfw);
      for (let y = baseY; y < SH; y++) for (let x = 0; x < P; x++) put(s, x, y, mist(floor * (1 - 0.35 * Math.min(1, (y - baseY) / (VH * 0.12)))));
      const plant = (cx, h) => {
        const w = h * wf * (0.8 + R() * 0.4), tip = baseY - h;
        for (let y = Math.max(s.y0, Math.floor(tip)); y <= baseY && y < SH; y++) {
          const hw = pineHalf(y - tip, h, w);
          if (hw < 0) continue;
          for (let dx = -Math.floor(hw); dx <= Math.floor(hw); dx++) put(s, cx + dx, y, solid(lum));
        }
      };
      if (clustered) {
        // near spruces come in stands with clearings between, so the valley shows through as it scrolls
        for (let c = 0; c < 6; c++) {
          const cx = (c / 6) * P + R() * P / 12, n = 2 + Math.floor(R() * 3);
          for (let k = 0; k < n; k++) plant(cx + k * (6 + R() * 10) * U, Z * (h0 + R() * (h1 - h0)));
        }
      } else {
        for (let x = 0; x < P; x += (step + R() * step * 1.4) * U) plant(x, Z * (h0 + R() * (h1 - h0)));
      }
      return s;
    });
    strips = [layers[2], layers[1], layers[0], ridge2, ridge]; // near → far

    fog = new Float32Array(FGW * FGH);
    const n1 = tile2(o.seed + 9, 16, 6), n2 = tile2(o.seed + 10, 32, 12);
    for (let y = 0; y < FGH; y++) for (let x = 0; x < FGW; x++) fog[y * FGW + x] = n1(x / 16, y / 16) * 0.7 + n2(x / 8, y / 8) * 0.3;
    E = new Float32Array(SW * SH);
  }

  function draw(t) {
    const { ink, ground, signal, light } = palette(canvas), d = img.data;
    const offs = strips.map(s => (t * s.speed * o.speed * (Z / 300)) % P);
    const fogOff = t * 6 * o.speed, blink = Math.floor(t * 1.4) % 2 === 0;
    const mastSx = ((mast.x - offs[4]) % P + P) % P;
    for (let y = 0; y < SH; y++) {
      const yn = (y - OY) / VH;
      const band = Math.exp(-(((yn - 0.7) / 0.05) ** 2)) * 0.5 + Math.exp(-(((yn - 0.84) / 0.06) ** 2)) * 0.4 + Math.exp(-(((yn - 0.6) / 0.04) ** 2)) * 0.2;
      const fy = Math.max(0, Math.min(FGH - 1, Math.floor(yn * FGH))), row = (y & 7) * 8;
      for (let x = 0; x < SW; x++) {
        const i = y * SW + x;
        let L = sky[i], fw = 0.05, kind = 0; // 0 sky, 1 solid, 2 mist
        for (let k = 0; k < strips.length; k++) {
          const s = strips[k];
          if (y < s.y0) continue;
          const v = s.a[(y - s.y0) * P + (((x + offs[k]) | 0) % P)];
          if (v === 255) continue;
          if (v < 128) { L = v / 127; fw = s.treeFw; kind = 1; } else { L = (v - 128) / 126; fw = s.mistFw; kind = 2; }
          break;
        }
        // xerox: the same valley on an overcast day, printed as a positive: pale sky and mist, black spruces
        if (light) L = kind === 0 ? 1 - 0.32 * L : kind === 2 ? 0.55 + 0.45 * L : L;
        if (band > 0.01 && fw > 0) L += fw * band * Math.max(0, fog[fy * FGW + (((x * 0.7 + fogOff * (1 + fy / FGH)) | 0) % FGW)] - 0.32) * 1.25;
        let C = (light ? 1 - L : L) > B8[row + (x & 7)] ? ink : ground;
        if (blink && Math.abs(x - mastSx) <= 1 && Math.abs(y - mast.top) <= 1) C = signal;
        const j = i * 4;
        d[j] = C[0]; d[j + 1] = C[1]; d[j + 2] = C[2]; d[j + 3] = 255;
      }
    }
    ctx.putImageData(img, 0, 0);
    if (o.onMast) o.onMast(mastSx < SW ? mastSx * PX : null, mast.top * PX);
  }

  build();
  const a = animate(canvas, draw, { fps: o.fps });
  const unres = onResize(canvas, () => { build(); a.redraw(); });
  return { ...a, destroy() { a.destroy(); unres(); } };
}

/* ---------------------------------------------------------------- treeline: the family signature */

/** A strip of spruces along the bottom of the canvas. opts: seed, px (css px per pixel), speed (px/s, 0 = still). */
export function treeline(canvas, opts = {}) {
  const o = { seed: 1, px: 2, speed: 0, fps: 20, ...opts };
  let W, H, P, a, ctx, img;
  function build() {
    W = Math.ceil(Math.max(1, canvas.clientWidth) / o.px); H = Math.max(4, Math.round(Math.max(1, canvas.clientHeight) / o.px));
    P = W * 2; canvas.width = W; canvas.height = H; ctx = canvas.getContext("2d"); img = ctx.createImageData(W, H);
    a = new Uint8Array(P * H);
    const R = rng(o.seed), ground = pfbm(o.seed + 9, 24);
    for (let x = 0; x < P; x++) for (let y = H - 1 - Math.round(ground(x / P) * 1.5); y < H; y++) a[y * P + x] = 1;
    for (let cx = 0; cx < P; cx += 4 + R() * 10) {
      const tip = H * (0.02 + R() * 0.5), h = H - tip, w = 7 + R() * 6;
      for (let y = Math.floor(tip); y < H; y++) {
        const hw = pineHalf(y - tip, h, w);
        if (hw < 0) continue;
        for (let dx = -Math.floor(hw); dx <= Math.floor(hw); dx++) a[y * P + (((Math.round(cx) + dx) % P) + P) % P] = 1;
      }
    }
  }
  function draw(t) {
    const { ink, ground } = palette(canvas), d = img.data, off = Math.floor(t * o.speed) % P;
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const C = a[y * P + ((x + off) % P)] ? ink : ground, j = (y * W + x) * 4;
      d[j] = C[0]; d[j + 1] = C[1]; d[j + 2] = C[2]; d[j + 3] = 255;
    }
    ctx.putImageData(img, 0, 0);
  }
  build();
  const anim = animate(canvas, draw, { fps: o.fps, still: !o.speed });
  const unres = onResize(canvas, () => { build(); anim.redraw(); });
  return { ...anim, destroy() { anim.destroy(); unres(); } };
}

/* ---------------------------------------------------------------- dithered images (the OG effect) */

const imageCache = new Map();
function loadImage(src) {
  if (!src) return Promise.resolve(null);
  if (typeof src !== "string") return Promise.resolve(src);
  if (!imageCache.has(src)) {
    imageCache.set(src, new Promise(res => {
      const i = new Image();
      i.decoding = "async";
      i.onload = () => res(i);
      i.onerror = () => res(null);
      i.src = src;
    }));
  }
  return imageCache.get(src);
}

/**
 * An image, Atkinson-dithered to 1 bit, alive: it develops out of noise when it first appears, and a slow
 * fog drifts through its threshold afterwards. hot(true) redraws it in the signal colour; develop() replays.
 * opts: px (css px per pixel), invert ("auto" | true | false), contrast, motion ("drift" | "still"), fallbackSeed.
 */
export function dithered(canvas, src, opts = {}) {
  const o = { px: 2, invert: "auto", contrast: 1.25, lift: 0, motion: "drift", fps: 14, fallbackSeed: null, ...opts };
  let W = 0, H = 0, base = null, E, ctx, img, hot = false, dev = 0, devT0 = 0, curT = 0, fogT;
  let anim = null, unres = () => {}, dead = false, source = null, builtLight = null;

  function build(image) {
    source = image; builtLight = palette(canvas).light;
    W = Math.max(1, Math.round(canvas.clientWidth / o.px)); H = Math.max(1, Math.round(canvas.clientHeight / o.px));
    canvas.width = W; canvas.height = H; ctx = canvas.getContext("2d", { willReadFrequently: true });
    base = new Float32Array(W * H); E = new Float32Array(W * H); img = ctx.createImageData(W, H);
    fogT = tile2(hash(String(src)) + 3, 12, 8);
    if (!image) { // no image: a seeded mirrored sigil
      const R = rng(o.fallbackSeed ?? hash(String(src))), G = 9, cell = Math.max(1, Math.floor(H * 0.6 / G));
      const ox = Math.floor((W - G * cell) / 2), oy = Math.floor((H - G * cell) / 2);
      for (let r = 0; r < G; r++) for (let q = 0; q <= G >> 1; q++) if (R() < 0.42 + (q === G >> 1 ? 0.2 : 0))
        for (let yy = 0; yy < cell; yy++) for (let xx = 0; xx < cell; xx++) {
          base[(oy + r * cell + yy) * W + ox + q * cell + xx] = 1;
          base[(oy + r * cell + yy) * W + ox + (G - 1 - q) * cell + xx] = 1;
        }
      return;
    }
    const c = document.createElement("canvas"); c.width = W; c.height = H;
    const x = c.getContext("2d", { willReadFrequently: true });
    x.fillStyle = "#000"; x.fillRect(0, 0, W, H);
    const s = Math.max(W / image.naturalWidth, H / image.naturalHeight), dw = image.naturalWidth * s, dh = image.naturalHeight * s;
    x.drawImage(image, (W - dw) / 2, (H - dh) / 2, dw, dh);
    const px = x.getImageData(0, 0, W, H).data;
    let mean = 0;
    for (let i = 0; i < W * H; i++) { base[i] = (0.299 * px[i * 4] + 0.587 * px[i * 4 + 1] + 0.114 * px[i * 4 + 2]) / 255; mean += base[i]; }
    mean /= W * H;
    // "auto" always picks the sparse print: ink goes on the minority tone, on light and dark grounds alike
    const inv = o.invert === "auto" ? mean > 0.6 : o.invert;
    for (let i = 0; i < base.length; i++) {
      const v = inv ? 1 - base[i] : base[i];
      base[i] = Math.min(1, Math.max(0, (v - 0.5) * o.contrast + 0.5 + o.lift));
    }
  }

  function draw(t) {
    if (!base) return;
    const pal = palette(canvas);
    if (pal.light !== builtLight) build(source); // the rendition flipped between light and dark: re-print
    const { ink, ground, signal } = pal, F = hot ? signal : ink, d = img.data;
    curT = t;
    if (dev > 0) dev = Math.max(0, 1 - (t - devT0) / 0.9);
    const drift = o.motion === "drift" && !(anim && anim.reduced);
    const R = rng((t * 1000) | 0);
    for (let i = 0; i < base.length; i++) {
      let v = base[i];
      if (dev > 0) v = v * (1 - dev) + R() * dev;
      if (drift) { const x = i % W, y = (i / W) | 0; v += (fogT(x / 18 + t * 0.35, y / 14 + t * 0.08) - 0.5) * 0.22; }
      E[i] = v;
    }
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const i = y * W + x, old = E[i], nv = old > 0.5 ? 1 : 0, err = (old - nv) / 8;
      if (x + 1 < W) E[i + 1] += err;
      if (x + 2 < W) E[i + 2] += err;
      if (y + 1 < H) { if (x > 0) E[i + W - 1] += err; E[i + W] += err; if (x + 1 < W) E[i + W + 1] += err; }
      if (y + 2 < H) E[i + 2 * W] += err;
      const C = nv ? F : ground, j = i * 4;
      d[j] = C[0]; d[j + 1] = C[1]; d[j + 2] = C[2]; d[j + 3] = 255;
    }
    ctx.putImageData(img, 0, 0);
  }

  const ready = loadImage(src).then(image => {
    if (dead) return; // destroyed before the image arrived: never start an animation nobody can stop
    build(image);
    anim = animate(canvas, t => draw(t), { fps: o.fps, still: o.motion === "still" });
    if (!anim.reduced) { dev = 1; devT0 = 0; }
    unres = onResize(canvas, () => { build(image); anim.redraw(); });
  });

  return {
    ready,
    hot(on) { hot = !!on; anim?.redraw(); },
    develop() { if (anim && !anim.reduced) { dev = 1; devT0 = curT; } anim?.redraw(); },
    destroy() { dead = true; anim?.destroy(); unres(); },
  };
}

/* ---------------------------------------------------------------- orb: the construct */

/**
 * A dithered planet that revolves constantly. sizzle(amount) makes it crackle: call it on every streamed
 * chunk. opts: size (pixels across), speed (radians/s), seed.
 */
export function orb(canvas, opts = {}) {
  const o = { size: 40, speed: 0.55, seed: 7, fps: 24, ...opts };
  const S = o.size; canvas.width = S; canvas.height = S;
  const ctx = canvas.getContext("2d"), img = ctx.createImageData(S, S);
  const TW = 128, TH = 64, tex = new Float32Array(TW * TH), n1 = tile2(o.seed, 8, 4), n2 = tile2(o.seed + 1, 16, 8), n3 = tile2(o.seed + 2, 32, 16);
  for (let y = 0; y < TH; y++) for (let x = 0; x < TW; x++) {
    const v = n1(x / 16, y / 16) * 0.55 + n2(x / 8, y / 8) * 0.3 + n3(x / 4, y / 4) * 0.15;
    tex[y * TW + x] = v > 0.52 ? 0.95 : 0.28 + v * 0.3; // continents and seas
  }
  let heat = 0, lastT = 0;
  function draw(t) {
    const { ink, ground, signal } = palette(canvas), d = img.data, dt = Math.max(0, t - lastT);
    lastT = t; heat *= Math.pow(0.08, dt); // decays to ~8% per second
    const R = rng(((t * 997) | 0) + 1), rot = t * o.speed, c = S / 2 - 0.5, r = S / 2 - 1 - heat * 0.5;
    for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
      const dx = (x - c) / r, dy = (y - c) / r, r2 = dx * dx + dy * dy, j = (y * S + x) * 4;
      let on = false, sig = false;
      if (r2 <= 1) {
        const z = Math.sqrt(1 - r2), lng = Math.atan2(dx, z) + rot, lat = Math.asin(Math.max(-1, Math.min(1, dy)));
        const u = ((lng / (2 * Math.PI)) % 1 + 1) % 1, v = lat / Math.PI + 0.5;
        const albedo = tex[Math.min(TH - 1, (v * TH) | 0) * TW + ((u * TW) | 0)];
        let L = albedo * (0.18 + 0.82 * Math.max(0, -0.45 * dx - 0.35 * dy + 0.82 * z));
        L += heat * (R() - 0.5) * 1.1 + heat * 0.15;
        on = L > B8[(y & 7) * 8 + (x & 7)];
        sig = on && heat > 0.25 && R() < heat * 0.35;
      } else if (heat > 0.05 && r2 < (1 + heat * 0.45) ** 2) {
        on = R() < heat * 0.28 * (1 - (Math.sqrt(r2) - 1) / (heat * 0.45 + 0.01));
        sig = on;
      }
      const C = sig ? signal : on ? ink : ground;
      d[j] = C[0]; d[j + 1] = C[1]; d[j + 2] = C[2]; d[j + 3] = 255;
    }
    ctx.putImageData(img, 0, 0);
  }
  const anim = animate(canvas, draw, { fps: o.fps });
  return {
    ...anim,
    // under reduced motion the orb stays still: a sizzle would freeze as a single noisy frame
    sizzle(amount = 1) { if (!anim.reduced) heat = Math.min(1.2, Math.max(heat, 0) + amount * 0.6); },
  };
}

/* ---------------------------------------------------------------- crackle: a sizzling block cursor */

/** A small block of 1-bit static, e.g. the cursor at the end of a streaming reply. */
export function crackle(canvas, opts = {}) {
  const o = { w: 5, h: 9, density: 0.55, fps: 20, ...opts };
  canvas.width = o.w; canvas.height = o.h;
  const ctx = canvas.getContext("2d"), img = ctx.createImageData(o.w, o.h);
  const anim = animate(canvas, t => {
    const { ink, ground, signal } = palette(canvas), R = rng(((t * 1000) | 0) + 3), d = img.data;
    for (let i = 0; i < o.w * o.h; i++) {
      const r = R(), C = r < o.density * 0.25 ? signal : r < o.density ? ink : ground;
      d[i * 4] = C[0]; d[i * 4 + 1] = C[1]; d[i * 4 + 2] = C[2]; d[i * 4 + 3] = 255;
    }
    ctx.putImageData(img, 0, 0);
  }, { fps: o.fps });
  return anim;
}
