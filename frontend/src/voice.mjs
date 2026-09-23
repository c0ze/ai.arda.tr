/*
 * voice.js: the construct's spoken replies, shared by ai.arda.tr, arda.tr and resume.arda.tr.
 *
 * There is no shared package: each site keeps a verbatim copy of this file (ai.arda.tr:
 * frontend/src/voice.mjs). Keep the copies identical; change it here first
 * (design-previews/onebit/voice.js), then copy it to the sites. No dependencies, no build step.
 *
 * ---------------------------------------------------------------- protocol
 *
 * POST https://ai-arda-tr-api-599610058688.asia-northeast1.run.app/api/chat/stream
 *   {"message": "...", "history": [...], "voice": true, "lang": "en" | "ja" | "tr"}
 * Leave "voice"/"lang" out entirely when muted: the stream is then exactly the text-only one.
 *
 * SSE events (`data: {json}` frames). Text-only: thinking → chunk* → done | error. With voice, all of
 * these arrive before `done`:
 *   {"type":"voice","on":true|false}            right after thinking; false = no speech will follow
 *   {"type":"speech","seq":n,"start":a,"end":b,"audio":"<base64>"|null,"mime":"audio/mpeg",
 *    "marks":[{"o":offset,"t":seconds},...]}     one sentence, in seq order; audio null = reveal silently
 *   {"type":"speech_end","upto":offset}         no more audio; text past `upto` shows after the audio
 * Offsets index the RAW reply (the concatenated chunk texts) in UTF-16 code units, i.e. JS string
 * indices: show `raw.slice(0, offset)`. A mark says "by t seconds into this clip, raw[..o) is spoken".
 * `done.text` is the final reply (it may add a contact notice); show it once everything is revealed.
 *
 * ---------------------------------------------------------------- API
 *
 *   unlockAudio()            Call inside the user's send gesture (click / Enter / quick prompt).
 *                            Creates or resumes the shared AudioContext; browsers refuse audio that
 *                            was not started from a gesture.
 *   voiceEnabled()           The visitor's choice, localStorage "voice" = "on" | "off"; default on.
 *   setVoiceEnabled(on)      Persist it and notify subscribers (a muting speaker stops at once).
 *   onVoiceChange(fn)        fn(on) on every change; returns an unsubscribe function.
 *   requestFields(lang)      {voice: true, lang} when voice is on, else {}: spread into the body.
 *   createSpeaker({onReveal, onLevel, onEnd}) → {handle(event), stop()}   one per reply:
 *     handle(event)          feed EVERY parsed SSE event (thinking/voice/chunk/speech/speech_end/done/error)
 *     stop()                 new message, language switch or reset: silence it and reveal everything
 *     onReveal(offset)       how much of the raw reply may be shown; Infinity = all of it (no gating).
 *                            Called only when the value grows. Starts at 0 once the server says voice on.
 *     onLevel(level)         0..1 loudness each animation frame while speaking (for an orb, meter, ...)
 *     onEnd()                once, when the speaker has nothing more to do (always after onReveal(Infinity))
 *   robotChain(ctx)          → {input, output, analyser}: the voice effect, exported for offline tests.
 *
 * Behaviour: text is gated only while voice is on, the server said voice on, and audio can play.
 * Otherwise (muted, voice:false, an old server, no Web Audio, a context that will not start) the
 * speaker reveals everything at once, exactly like a text-only client. Muting mid-reply stops the
 * audio and reveals everything; unmuting only affects the next reply. If the text is done and no
 * speech has arrived for 4 s, everything is revealed.
 *
 * Minimal integration:
 *   send() { unlockAudio(); const speaker = createSpeaker({ onReveal: n => render(raw.slice(0, n)) });
 *            fetch(url, {method: "POST", body: JSON.stringify({message, history, ...requestFields("en")})})
 *            ... for each SSE event: speaker.handle(event); if (event.type === "chunk") raw += event.text; }
 */

const KEY = "voice";
const listeners = new Set();
let memory = true; // the choice when localStorage is unavailable (private mode, blocked storage)

export function voiceEnabled() {
  try {
    const v = window.localStorage.getItem(KEY);
    if (v !== null) return v !== "off";
  } catch (_) {}
  return memory;
}

export function setVoiceEnabled(on) {
  memory = !!on;
  try {
    window.localStorage.setItem(KEY, memory ? "on" : "off");
  } catch (_) {}
  for (const fn of [...listeners]) {
    try { fn(memory); } catch (_) {}
  }
}

export function onVoiceChange(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function requestFields(lang) {
  return voiceEnabled() ? { voice: true, lang } : {};
}

/* ---------------------------------------------------------------- audio context */

let ctx = null;
let chain = null;

export function unlockAudio() {
  try {
    if (!ctx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return null;
      ctx = new AC();
    }
    if (ctx.state !== "running") ctx.resume().catch(() => {});
    // iOS only unlocks output once something has started inside the gesture.
    const blip = ctx.createBufferSource();
    blip.buffer = ctx.createBuffer(1, 1, ctx.sampleRate);
    blip.connect(ctx.destination);
    blip.start(0);
  } catch (_) {
    return null;
  }
  return ctx;
}

/*
 * The robot: decoded speech → ring modulator (a gain driven by a 58 Hz sine, 55% wet / 45% dry so
 * words stay intelligible) → gentle bit-crush (a 16-step staircase blended 40% into the straight
 * line) → 5.2 kHz low-pass to take the fizz off → short metallic comb (4.5 ms delay, 0.42
 * feedback, 35% mix) → 0.95 gain → limiter (−6 dB, 12:1) → meter → speakers. The classic 80s synth robot: mechanical, not harsh.
 */
export function robotChain(ac) {
  const input = ac.createGain();

  const osc = ac.createOscillator();
  osc.type = "sine";
  osc.frequency.value = 58;
  const ring = ac.createGain();
  ring.gain.value = 0; // the oscillator alone drives it: output = input × sin(2π·58·t)
  osc.connect(ring.gain);
  osc.start();
  const dry = ac.createGain();
  dry.gain.value = 0.45;
  const wet = ac.createGain();
  wet.gain.value = 0.55;
  input.connect(dry);
  input.connect(ring).connect(wet);
  const mix = ac.createGain();
  dry.connect(mix);
  wet.connect(mix);

  const crush = ac.createWaveShaper();
  const N = 4096, steps = 16, blend = 0.4, curve = new Float32Array(N);
  for (let i = 0; i < N; i++) {
    const x = (i / (N - 1)) * 2 - 1;
    curve[i] = (1 - blend) * x + blend * (Math.round(x * steps) / steps);
  }
  crush.curve = curve;
  mix.connect(crush);
  const lowpass = ac.createBiquadFilter();
  lowpass.type = "lowpass";
  lowpass.frequency.value = 5200;
  lowpass.Q.value = 0.5;
  crush.connect(lowpass);

  const comb = ac.createDelay(0.05);
  comb.delayTime.value = 0.0045;
  const feedback = ac.createGain();
  feedback.gain.value = 0.42;
  const combMix = ac.createGain();
  combMix.gain.value = 0.35;
  lowpass.connect(comb);
  comb.connect(feedback).connect(comb);
  comb.connect(combMix);
  const sum = ac.createGain();
  sum.gain.value = 0.95;
  lowpass.connect(sum);
  combMix.connect(sum);

  const limiter = ac.createDynamicsCompressor();
  limiter.threshold.value = -6;
  limiter.knee.value = 4;
  limiter.ratio.value = 12;
  limiter.attack.value = 0.002;
  limiter.release.value = 0.15;
  sum.connect(limiter);
  const analyser = ac.createAnalyser();
  analyser.fftSize = 1024;
  limiter.connect(analyser);
  return { input, output: analyser, analyser };
}

function ensureChain() {
  if (!ctx) return null;
  if (!chain) {
    chain = robotChain(ctx);
    chain.output.connect(ctx.destination);
    chain.samples = new Float32Array(chain.analyser.fftSize);
  }
  return chain;
}

function level() {
  if (!chain) return 0;
  chain.analyser.getFloatTimeDomainData(chain.samples);
  let sum = 0;
  for (const v of chain.samples) sum += v * v;
  return Math.min(1, Math.sqrt(sum / chain.samples.length) * 4);
}

function decode(b64) {
  const bin = atob(b64), bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  // callback form: older Safari has no promise-returning decodeAudioData
  return new Promise((resolve, reject) => {
    const p = ctx.decodeAudioData(bytes.buffer, resolve, reject);
    p?.catch?.(() => {}); // newer browsers also return a promise; the callbacks already handle the failure
  });
}

/* ---------------------------------------------------------------- speaker */

const QUIET_MS = 4000; // text done and no speech for this long: reveal everything
const STALLED_MS = 1500; // a context that will not run: give up on audio

export function createSpeaker({ onReveal = () => {}, onLevel = () => {}, onEnd = () => {} } = {}) {
  let mode = "pending"; // pending → voiced | off
  let shown = -1;
  const clips = new Map(); // seq → {start, end, marks, buffer, ready}
  let received = 0, scheduled = 0;
  const timeline = []; // {t0, dur, start, end, points}
  const sources = [];
  let playEnd = 0;
  let upto = null; // from speech_end
  let textDone = false, lastNews = Date.now(), stalledSince = 0;
  let frame = 0, timer = 0, lastLevel = -1;
  const unsubscribe = onVoiceChange((on) => { if (!on) stop(); });

  function reveal(n) {
    if (n > shown) {
      shown = n;
      onReveal(n);
    }
  }

  // Reveal everything and stop reacting: no gating from here on.
  function off({ silence }) {
    if (mode === "off") return;
    mode = "off";
    unsubscribe();
    if (frame) cancelAnimationFrame(frame);
    if (timer) clearInterval(timer);
    if (silence) for (const s of sources) { try { s.stop(); } catch (_) {} }
    if (lastLevel !== 0) onLevel(0);
    reveal(Infinity);
    onEnd();
  }

  function stop() {
    off({ silence: true });
  }

  function schedule(clip) {
    const t0 = Math.max(ctx.currentTime + 0.05, playEnd);
    let dur = 0;
    if (clip.buffer) {
      const src = ctx.createBufferSource();
      src.buffer = clip.buffer;
      src.connect(ensureChain().input);
      src.start(t0);
      sources.push(src);
      src.onended = () => sources.splice(sources.indexOf(src), 1);
      dur = clip.buffer.duration;
    }
    // Reveal curve through the clip: its start at 0 s, each mark, its end at the last sample.
    const points = [{ o: clip.start, t: 0 }];
    for (const m of clip.marks) {
      if (m.t > points.at(-1).t && m.t < dur) points.push({ o: Math.max(m.o, points.at(-1).o), t: m.t });
    }
    points.push({ o: clip.end, t: dur });
    timeline.push({ t0, dur, end: clip.end, points });
    playEnd = t0 + dur;
  }

  function pump() {
    while (clips.has(scheduled) && clips.get(scheduled).ready) {
      const clip = clips.get(scheduled);
      clips.delete(scheduled);
      scheduled++;
      schedule(clip);
    }
    tick();
  }

  // Raw offset reached by the audio at the current playback time.
  function position(t) {
    let n = 0;
    for (const c of timeline) {
      if (t < c.t0) break;
      const x = t - c.t0;
      if (x >= c.dur) { n = c.end; continue; }
      const p = c.points;
      let i = 0;
      while (i < p.length - 2 && x >= p[i + 1].t) i++;
      const a = p[i], b = p[i + 1], f = b.t > a.t ? (x - a.t) / (b.t - a.t) : 1;
      n = Math.floor(a.o + (b.o - a.o) * Math.min(1, Math.max(0, f)));
    }
    return n;
  }

  function tick() {
    if (mode !== "voiced") return;
    if (ctx.state !== "running") {
      if (!stalledSince) stalledSince = Date.now();
      if (Date.now() - stalledSince > STALLED_MS) return off({ silence: true });
    } else stalledSince = 0;
    const t = ctx.currentTime;
    reveal(position(t));
    const playing = t < playEnd;
    const l = playing ? level() : 0;
    if (l !== lastLevel) { lastLevel = l; onLevel(l); }
    if (t < playEnd) return;
    // Everything announced has played: the end.
    if (upto !== null && scheduled === received) return off({ silence: false });
    // Safety net: the text is complete and the speech went quiet (lost or undecodable events).
    if (textDone && Date.now() - lastNews > QUIET_MS) return off({ silence: false });
  }

  function loop() {
    tick();
    if (mode === "voiced") frame = requestAnimationFrame(loop);
  }

  function handle(e) {
    if (!e || mode === "off") return;
    if (mode === "pending") {
      if (e.type === "thinking") return;
      if (e.type === "voice" && e.on && voiceEnabled() && unlockAudio() && ensureChain()) {
        mode = "voiced";
        reveal(0);
        frame = requestAnimationFrame(loop);
        timer = setInterval(tick, 250); // rAF sleeps in background tabs; audio does not
        return;
      }
      // voice:false, muted, no Web Audio, or a server that never speaks: plain text.
      return off({ silence: false });
    }
    switch (e.type) {
      case "speech": {
        lastNews = Date.now();
        received++;
        const clip = { start: e.start, end: e.end, marks: Array.isArray(e.marks) ? e.marks : [], buffer: null, ready: false };
        clips.set(e.seq, clip);
        if (typeof e.audio === "string" && e.audio) {
          decode(e.audio)
            .then((b) => { clip.buffer = b; })
            .catch(() => {}) // undecodable: reveal it silently at its turn
            .finally(() => { clip.ready = true; if (mode === "voiced") pump(); });
        } else {
          clip.ready = true;
          pump();
        }
        break;
      }
      case "speech_end":
        lastNews = Date.now();
        upto = typeof e.upto === "number" ? e.upto : 0;
        tick();
        break;
      case "done":
        textDone = true;
        lastNews = Date.now();
        tick();
        break;
      case "error":
        stop();
        break;
    }
  }

  return { handle, stop };
}
