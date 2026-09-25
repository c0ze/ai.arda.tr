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

/* ---------------------------------------------------------------- the valley's residents */

// A werewolf and a bat, drawn as small vector rigs and thresholded to 1 bit, so they scale with the scene
// and animate smoothly. Each returns a mask (1 = body) in its own box, plus where that box sits.
const creatureCanvas = () => {
  const c = document.createElement("canvas");
  return { c, g: c.getContext("2d", { willReadFrequently: true }) };
};
function rasterize(cc, w, h, paint) {
  w = Math.max(1, Math.ceil(w)); h = Math.max(1, Math.ceil(h));
  if (cc.c.width !== w || cc.c.height !== h) { cc.c.width = w; cc.c.height = h; }
  const g = cc.g;
  g.setTransform(1, 0, 0, 1, 0, 0); g.clearRect(0, 0, w, h);
  g.fillStyle = g.strokeStyle = "#000"; g.lineCap = "round"; g.lineJoin = "round";
  paint(g);
  const a = g.getImageData(0, 0, w, h).data, m = new Uint8Array(w * h);
  for (let i = 0; i < m.length; i++) m[i] = a[i * 4 + 3] > 110 ? 1 : 0;
  return { m, w, h };
}
const ease = p => p * p * (3 - 2 * p);

/* the werewolf: a man's frame with a wolf's head, running upright and hunched; it stops, straightens,
   throws its arms out and howls at the moon. phase = stride, h = 0 run … 1 howl. Units: ground at y = 0,
   about 17 units tall; +x is the direction it runs. */
function paintWerewolf(g, u, ox, oy, phase, h) {
  g.translate(ox, oy); g.scale(u, u);
  const TAU = Math.PI * 2, th = phase * TAU, mix = (a, b) => a + (b - a) * h;
  const bob = (1 - h) * 0.45 * Math.abs(Math.sin(th));
  const limb = (x, y, segs) => { // segs: [angle from straight down (+ = forward), length, width], angles accumulate
    let a = 0;
    for (const [da, len, w] of segs) {
      a += da; const nx = x + Math.sin(a) * len, ny = y + Math.cos(a) * len;
      g.lineWidth = w; g.beginPath(); g.moveTo(x, y); g.lineTo(nx, ny); g.stroke(); x = nx; y = ny;
    }
    return [x, y, a];
  };
  const claws = (x, y, a) => { for (const k of [-0.5, 0, 0.5]) { g.lineWidth = 0.35; g.beginPath(); g.moveTo(x, y); g.lineTo(x + Math.sin(a + k) * 0.9, y + Math.cos(a + k) * 0.9); g.stroke(); } };
  const pelvis = [0, -8.2 + bob];
  // legs: digitigrade (thigh, shin, long foot); running swing, or planted wide to howl
  for (const side of [0, 1]) {
    const t = th + side * Math.PI, sw = Math.sin(t), lift = Math.max(0, Math.sin(t + 1.3));
    limb(pelvis[0], pelvis[1], [
      [mix(0.75 * sw, side ? -0.3 : 0.35), 3.9, 1.7],
      [mix(-0.35 - 1.1 * lift, -0.35), 3.3, 1.2],
      [mix(1.05 + 0.4 * lift, 0.9), 1.9, 0.8],
    ]);
  }
  // tail
  g.lineWidth = 1.1; g.beginPath(); g.moveTo(pelvis[0] - 0.6, pelvis[1] - 0.4);
  g.quadraticCurveTo(mix(-3.2, -2.2), pelvis[1] + mix(-0.6, 1.4), mix(-4.6, -3), pelvis[1] + mix(0.4, 3.4)); g.stroke();
  // torso leans into the run, arches back to howl; broad hunched shoulders
  const lean = mix(0.5, -0.18), sx = pelvis[0] + Math.sin(lean) * 6.2, sy = pelvis[1] - Math.cos(lean) * 6.2;
  const px = Math.cos(lean), py = Math.sin(lean); // perpendicular to the spine
  g.beginPath();
  g.moveTo(pelvis[0] - px * 1.2, pelvis[1] - py * 1.2); g.lineTo(pelvis[0] + px * 1.1, pelvis[1] + py * 1.1);
  g.lineTo(sx + px * 1.9, sy + py * 1.9); g.lineTo(sx - px * 2.3, sy - py * 2.3); g.closePath(); g.fill();
  g.beginPath(); g.ellipse(sx - px * 0.4, sy - py * 0.4 + 0.3, 2.2, 1.6, lean, 0, TAU); g.fill();
  // mane: fur bristling off the back of the neck and shoulders
  for (let k = 0; k < 4; k++) {
    const f = 0.35 + k * 0.2, bx = pelvis[0] + (sx - pelvis[0]) * f - px * 1.7, by = pelvis[1] + (sy - pelvis[1]) * f - py * 1.7;
    g.beginPath(); g.moveTo(bx + Math.sin(lean) * 0.7, by - Math.cos(lean) * 0.7); g.lineTo(bx - px * 1.2 - Math.sin(lean) * 0.6, by - py * 1.2 + 0.2); g.lineTo(bx - Math.sin(lean) * 0.5, by + Math.cos(lean) * 0.5); g.fill();
  }
  // arms: swing against the legs with bent elbows; flung out wide and raised to howl
  for (const side of [0, 1]) {
    const sw = Math.sin(th + side * Math.PI + Math.PI);
    const [hx, hy, a] = limb(sx, sy + 0.4, [
      [mix(1.15 * sw, side ? -2.0 : 2.05), 3.4, 1.3],
      [mix(0.6 + 0.5 * Math.max(0, sw), side ? -0.75 : 0.7), 3.3, 1],
    ]);
    claws(hx, hy, a);
  }
  // wolf head on a thick neck: muzzle forward at a run, thrown back to the sky to howl
  const na = lean + mix(0.55, -0.1), hx = sx + Math.sin(na) * 1.7, hy = sy - Math.cos(na) * 1.7;
  g.lineWidth = 1.6; g.beginPath(); g.moveTo(sx, sy); g.lineTo(hx, hy); g.stroke();
  g.save(); g.translate(hx, hy); g.rotate(mix(0.15, -1.25));
  g.beginPath(); g.ellipse(0, 0, 1.45, 1.15, 0, 0, TAU); g.fill();
  g.beginPath(); g.moveTo(0.7, -0.75); g.lineTo(3.1, -0.3); g.lineTo(3.1, 0.05); g.lineTo(0.8, 0.2); g.fill(); // upper jaw
  g.save(); g.translate(0.8, 0.2); g.rotate(0.35 * h); // the jaw drops as it howls
  g.beginPath(); g.moveTo(0, 0); g.lineTo(2.1, 0.15); g.lineTo(1.9, 0.5); g.lineTo(0, 0.75); g.fill(); g.restore();
  g.beginPath(); g.moveTo(-0.5, -0.8); g.lineTo(-0.15, -2.5); g.lineTo(0.35, -0.9); g.fill(); // ears
  g.beginPath(); g.moveTo(-1.15, -0.55); g.lineTo(-1.35, -2.2); g.lineTo(-0.45, -0.95); g.fill();
  g.restore();
}

/* the bat: f = wing flap (+1 up … -1 down); f ≈ 0 is the spread silhouette you see against the moon */
function paintBat(g, u, ox, oy, f) {
  g.translate(ox, oy); g.scale(u, u);
  const wing = [[0.7, -0.8], [2.2, -1.9], [4.4, -2.2], [6.5, -1.2], [6, 0.6], [5.2, -0.2], [4.3, 1.4], [3.4, 0.4], [2.2, 1.8], [1.3, 0.7], [0.7, 1]];
  for (const side of [1, -1]) {
    g.beginPath();
    wing.forEach(([x, y], i) => { const yy = y - f * 2.6 * Math.pow(x / 6.5, 1.2); i ? g.lineTo(side * x, yy) : g.moveTo(side * x, yy); });
    g.closePath(); g.fill();
    g.beginPath(); g.moveTo(side * 0.6, -1.6); g.lineTo(side * 0.45, -2.8); g.lineTo(side * 0.1, -1.9); g.fill();
  }
  g.beginPath(); g.ellipse(0, 0.2, 0.85, 1.6, 0, 0, Math.PI * 2); g.fill();
  g.beginPath(); g.ellipse(0, -1.3, 0.75, 0.75, 0, 0, Math.PI * 2); g.fill();
}

/**
 * A moonlit spruce valley in fog, scrolling sideways in parallax, ordered-dithered to 1 bit.
 * Now and then a werewolf crosses the valley and howls at the moon, or a bat hangs in front of it; they take
 * turns, one roughly every creatureEvery seconds. summon("wolf" | "bat") calls one up right away.
 * opts: seed, speed (1 = default drift), maxWidth (low-res pixel cap, for CPU), onMast(x, y) in CSS px,
 * creatures (bool), creatureFirst / creatureEvery (seconds), onCreature(kind, moment) for "howl" etc.,
 * werewolfSprite: { src, frames: 8, run: [0, 5], rise: 6, howl: 7 }: a horizontal sheet (e.g. exported from
 * Aseprite), dark figure with light rim lines on transparency. Its shading is dithered to 1 bit here. Without
 * it (or until it loads) the werewolf is drawn from the vector rig.
 */
export function forest(canvas, opts = {}) {
  const o = { seed: 2004, speed: 1, maxWidth: 640, px: 2, fps: 30, onMast: null, creatures: true, creatureFirst: 40, creatureEvery: 60, onCreature: null, werewolfSprite: null, ...opts };
  let SW, SH, VH, OY, Z, P, PX, sky, strips, fog, E, img, ctx, mast, moonAt, lastT = 0, summoned = null, howled = -1;
  const cc = creatureCanvas();
  // the werewolf sprite sheet, scaled per scene size into masks + shading
  let sheet = null, sheetFrames = null, sheetH = 0;
  if (o.werewolfSprite?.src) loadImage(o.werewolfSprite.src).then(im => { sheet = im; sheetFrames = null; });
  function spriteFrames(targetH) {
    if (!sheet) return null;
    if (sheetFrames && sheetH === targetH) return sheetFrames;
    const n = o.werewolfSprite.frames || 8, fw = sheet.naturalWidth / n, fh = sheet.naturalHeight;
    const w = Math.max(1, Math.round(fw * targetH / fh)), h = targetH;
    const c = document.createElement("canvas"); c.width = w; c.height = h;
    const g = c.getContext("2d", { willReadFrequently: true }); g.imageSmoothingEnabled = true; g.imageSmoothingQuality = "high";
    sheetFrames = [];
    for (let i = 0; i < n; i++) {
      g.clearRect(0, 0, w, h); g.drawImage(sheet, i * fw, 0, fw, fh, 0, 0, w, h);
      const px = g.getImageData(0, 0, w, h).data, m = new Uint8Array(w * h), lum = new Float32Array(w * h);
      for (let k = 0; k < w * h; k++) { const al = px[k * 4 + 3]; if (al > 110) { m[k] = 1; lum[k] = (px[k * 4] / 255) * (255 / al); } }
      sheetFrames.push({ m, lum, w, h });
    }
    sheetH = targetH;
    return sheetFrames;
  }
  const DUR = { wolf: 13, bat: 11 };
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
    moonAt = moon;
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
    drawCreature(t, d, offs, light ? ink : ground, light ? ground : ink, signal);
    ctx.putImageData(img, 0, 0);
    if (o.onMast) o.onMast(mastSx < SW ? mastSx * PX : null, mast.top * PX);
  }

  // which resident, if any, is out at time t, and how far into its walk-on
  function creatureAt(t) {
    if (summoned && t - summoned.t0 >= 0 && t - summoned.t0 < DUR[summoned.kind]) return { kind: summoned.kind, lt: t - summoned.t0, id: "s" + summoned.t0 };
    if (!o.creatures || t < o.creatureFirst) return null;
    const k = Math.floor((t - o.creatureFirst) / o.creatureEvery), start = o.creatureFirst + k * o.creatureEvery, kind = k % 2 ? "bat" : "wolf";
    return t - start < DUR[kind] ? { kind, lt: t - start, id: k } : null;
  }

  // where the wolf should sit: the spot nearest the centre that stays in a clearing between the near
  // spruce stands for the whole howl, allowing for both the stands and the ground scrolling by
  const stops = new Map();
  function stopFor(ev, t, u, ground) {
    if (stops.has(ev.id)) return stops.get(ev.id);
    const near = strips[0], t0 = t - ev.lt, drift = strips[1].speed * o.speed * (Z / 300), rows = [ground - 12 * u, ground - 6 * u, ground - 1];
    const nearOff = T => (T * near.speed * o.speed * (Z / 300)) % P;
    const covered = x => {
      let n = 0;
      for (let T = t0 + 5; T <= t0 + 8.7; T += 0.3) for (let dx = -11 * u; dx <= 11 * u; dx += 2) for (const yy of rows) {
        const X = x - drift * (T - t0 - 5) + dx, Y = Math.round(yy);
        if (Y >= near.y0 && Y < SH && near.a[(Y - near.y0) * P + ((((X + nearOff(T)) | 0) % P) + P) % P] !== 255) n++;
      }
      return n;
    };
    let best = SW * 0.5, bestScore = Infinity;
    for (let x = SW * 0.3; x <= SW * 0.72; x += 4) { const sc = covered(x) * 1000 + Math.abs(x - SW * 0.5); if (sc < bestScore) { bestScore = sc; best = x; } }
    stops.clear(); stops.set(ev.id, best);
    return best;
  }

  function drawCreature(t, d, offs, dark, lit, signal) {
    lastT = t;
    const ev = creatureAt(t);
    if (!ev) return;
    const put = (x, y, C) => { if (x < 0 || y < 0 || x >= SW || y >= SH) return; const j = (y * SW + x) * 4; d[j] = C[0]; d[j + 1] = C[1]; d[j + 2] = C[2]; };
    const near = strips[0], hidden = (x, y) => y >= near.y0 && near.a[(y - near.y0) * P + (((x + offs[0]) | 0) % P)] !== 255;
    const blit = (r, ox, oy, occlude) => {
      ox = Math.round(ox); oy = Math.round(oy);
      for (let y = 0; y < r.h; y++) for (let x = 0; x < r.w; x++) {
        const X = ox + x, Y = oy + y;
        if (occlude && hidden(X, Y)) continue;
        if (r.m[y * r.w + x]) {
          // the sprite's own moonlit lines, ordered-dithered like the rest of the valley
          const l = r.lum ? r.lum[y * r.w + x] : 0;
          put(X, Y, l > 0.08 && l * 0.95 > B8[((Y & 7) << 3) + (X & 7)] ? lit : dark);
          continue;
        }
        // a moonlit rim: solid on the side facing the moon (upper right), half-toned on the shadow side,
        // so the silhouette reads against dark trees as well as bright mist
        const m = (dx, dy) => { const xx = x + dx, yy = y + dy; return xx >= 0 && yy >= 0 && xx < r.w && yy < r.h && r.m[yy * r.w + xx]; };
        if (m(-1, 0) || m(0, 1)) put(X, Y, lit);
        else if (((X + Y) & 1) === 0 && (m(1, 0) || m(0, -1))) put(X, Y, lit);
      }
    };
    if (ev.kind === "wolf") {
      const u = Math.max(1.5, Z * 0.012), L = 14 * u, ground = OY + VH * 0.93, lt = ev.lt;
      const cx = stopFor(ev, t, u, ground);
      let x, h = 0;
      // while it sits it stays put on the ground, which scrolls with the middle forest
      const drift = strips[1].speed * o.speed * (Z / 300), sx = cx - drift * 3.7;
      if (lt < 5) { const p = lt / 5; x = -L + (cx + L) * (1 - (1 - p) * (1 - p)); }
      else if (lt < 8.7) { x = cx - drift * (lt - 5); h = lt < 5.6 ? ease((lt - 5) / 0.6) : lt < 8.2 ? 1 : 1 - ease((lt - 8.2) / 0.5); }
      else { const p = (lt - 8.7) / 4.3; x = sx + (SW + L - sx) * p * p; }
      const phase = (x + L) / (11 * u); // one full stride cycle every 11 units
      // behind the foremost spruce line, in front of everything else; stopFor() picks a clearing for the howl
      const frames = spriteFrames(Math.round(21 * u));
      if (frames) {
        const S = o.werewolfSprite, [r0, r1] = S.run || [0, 5], cyc = r1 - r0 + 1;
        const fi = lt >= 5 && lt < 8.7 ? (lt < 5.35 || lt >= 8.3 ? S.rise ?? 6 : S.howl ?? 7) : r0 + (Math.floor(phase * cyc) % cyc);
        const f = frames[fi];
        blit(f, x - f.w / 2, ground - f.h + 1, true);
      } else {
        const r = rasterize(cc, 24 * u + 4, 22 * u + 4, g => paintWerewolf(g, u, 11 * u + 2, 20 * u + 2, phase, h));
        blit(r, x - 11 * u - 2, ground - 20 * u - 2, true);
      }
      if (lt >= 5.6 && lt < 8.2 && howled !== ev.id) { howled = ev.id; o.onCreature?.("wolf", "howl"); }
    } else {
      const m = moonAt, u = (1.8 * m.r) / 13, lt = ev.lt, TAU = Math.PI * 2;
      let x, y, f;
      if (lt < 4) { const p = ease(lt / 4); x = SW + 8 * u + (m.x - SW - 8 * u) * p; y = m.y + Z * 0.22 * (1 - p) + Math.sin(lt * 5) * u * 0.4; f = Math.sin(lt * TAU * 4.5) * (1 - 0.8 * p); }
      else if (lt < 7.5) { x = m.x; y = m.y + Math.sin(lt * 2.4) * 0.6; f = 0.12 * Math.sin(lt * TAU * 0.9); }
      else { const p = (lt - 7.5) / 3.5; x = m.x - Z * 0.25 * p; y = m.y - (m.y + 8 * u) * p * p; f = Math.sin(lt * TAU * 5); } // climbs away off the top
      const r = rasterize(cc, 14 * u + 4, 9 * u + 4, g => paintBat(g, u, 7 * u + 2, 4.8 * u + 2, f));
      blit(r, x - 7 * u - 2, y - 4.8 * u - 2, false);
    }
  }

  build();
  const a = animate(canvas, draw, { fps: o.fps });
  const unres = onResize(canvas, () => { build(); a.redraw(); });
  return { ...a, summon(kind) { if (!a.reduced && DUR[kind]) summoned = { kind, t0: lastT + 0.05 }; }, destroy() { a.destroy(); unres(); } };
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
 * opts: px (css px per pixel), invert ("auto" | true | false), contrast, motion ("drift" | "still"), fallbackSeed,
 * reveal: { hold, fade, onDone }: after developing and holding `hold` s, the dither burns off pixel by pixel
 * in random order over `fade` s (a band of static runs just ahead of it) until the canvas is transparent, so
 * whatever sits underneath (the real image) shows through; then it stops and calls onDone. Under reduced
 * motion, or with no image (a sigil), onDone is called straight away for an image, never for a sigil.
 */
export function dithered(canvas, src, opts = {}) {
  const o = { px: 2, invert: "auto", contrast: 1.25, lift: 0, motion: "drift", fps: 14, fallbackSeed: null, ...opts };
  let W = 0, H = 0, base = null, E, ctx, img, hot = false, dev = 0, devT0 = 0, curT = 0, fogT;
  let anim = null, unres = () => {}, dead = false, source = null, builtLight = null, order = null, revealed = false;

  function build(image) {
    source = image; builtLight = palette(canvas).light;
    W = Math.max(1, Math.round(canvas.clientWidth / o.px)); H = Math.max(1, Math.round(canvas.clientHeight / o.px));
    canvas.width = W; canvas.height = H; ctx = canvas.getContext("2d", { willReadFrequently: true });
    base = new Float32Array(W * H); E = new Float32Array(W * H); img = ctx.createImageData(W, H);
    fogT = tile2(hash(String(src)) + 3, 12, 8);
    if (o.reveal) { const R = rng(hash(String(src)) + 11); order = new Float32Array(W * H); for (let i = 0; i < order.length; i++) order[i] = R(); }
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
    // the burn-off: 0 = all dither … 1 = all gone
    const rv = o.reveal && source ? o.reveal : null, t0 = rv ? 0.9 + (rv.hold ?? 0.6) : 0;
    const dis = rv ? Math.min(1, Math.max(0, (t - t0) / (rv.fade ?? 1.1))) : 0, band = 0.09;
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
      let C = nv ? F : ground, a = 255;
      if (dis > 0) {
        const k = order[i] - dis * (1 + band);
        if (k < -band) a = 0; // burnt off: the real image shows through
        else if (k < 0 && R() < 0.65) C = R() < 0.5 ? signal : ink; // the sizzle, just ahead of the edge
      }
      const j = i * 4;
      d[j] = C[0]; d[j + 1] = C[1]; d[j + 2] = C[2]; d[j + 3] = a;
    }
    ctx.putImageData(img, 0, 0);
    if (dis >= 1 && !revealed) finish();
  }

  function finish() {
    if (revealed) return;
    revealed = true;
    ctx?.clearRect(0, 0, canvas.width, canvas.height);
    anim?.destroy(); unres();
    o.reveal?.onDone?.();
  }

  const ready = loadImage(src).then(image => {
    if (dead) return; // destroyed before the image arrived: never start an animation nobody can stop
    build(image);
    if (o.reveal && image && reducedMotion()) { finish(); return; } // no burn-off to watch: show the real image
    anim = animate(canvas, t => draw(t), { fps: o.reveal && image ? Math.max(o.fps, 24) : o.fps, still: o.motion === "still" && !(o.reveal && image) });
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
export const __rigs = { paintWerewolf, paintBat }; // for the rig test page in design-previews
