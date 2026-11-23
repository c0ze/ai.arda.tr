/**
 * Kara Duman: the smoke moves.
 *
 * startSmoke() finds every <img data-smoke-video="/art/plume-smoke.mp4">
 * inside an .ix-smoke wrapper and plays that looping film of the same artwork
 * over it. The film is the artwork on black, so brand.css lays it down with
 * mix-blend-mode: lighten and only its lines show.
 *
 * The image stays in the page. It keeps the layout, it is what shows until
 * the film can play, and it is all there is without script, when printing,
 * and under reduced motion. The film is fetched only when the artwork comes
 * near the screen, and pauses while it is off screen. It is not fetched at all
 * for a visitor who asked their browser to save data, or while the image's
 * data-smoke-media query (say "(min-width: 60rem)") does not match.
 */

const reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

/** Plays the film over one image. Returns a function that stops it and restores the image. */
export function smoke(img) {
  const wrap = img.closest(".ix-smoke");
  const film = img.dataset.smokeVideo;
  if (!wrap || !film || wrap.dataset.smoke) return () => {};
  if (navigator.connection?.saveData) return () => {};
  if (img.dataset.smokeMedia && !matchMedia(img.dataset.smokeMedia).matches) return () => {};
  wrap.dataset.smoke = "pending";

  const video = document.createElement("video");
  video.className = "ix-smoke__film";
  video.muted = true;
  video.loop = true;
  video.playsInline = true;
  video.preload = "auto";
  video.disablePictureInPicture = true;
  video.setAttribute("aria-hidden", "true");
  video.tabIndex = -1;
  video.src = film;

  let attached = false;
  let stopped = false;

  // The film is cropped as the image is (the phone band uses object-fit).
  const fit = () => {
    const style = getComputedStyle(img);
    video.style.objectFit = style.objectFit === "fill" ? "cover" : style.objectFit;
    video.style.objectPosition = style.objectPosition;
  };
  const onPlaying = () => {
    wrap.dataset.smoke = "on";
  };
  // No source could be played: stay with the image.
  const onError = () => stop();

  const seen = new IntersectionObserver(
    (entries) => {
      if (stopped) return;
      // Several changes can arrive at once: only the latest is true now.
      const entry = entries[entries.length - 1];
      if (!entry.isIntersecting) {
        video.pause();
        return;
      }
      if (!attached) {
        attached = true;
        fit();
        wrap.append(video);
      }
      // A refused play() (a data saver, a policy) leaves the image showing.
      video.play().catch(() => {});
    },
    { rootMargin: "200px" },
  );
  const resized = new ResizeObserver(fit);

  function stop() {
    if (stopped) return;
    stopped = true;
    seen.disconnect();
    resized.disconnect();
    video.removeEventListener("playing", onPlaying);
    video.removeEventListener("error", onError);
    video.pause();
    video.remove();
    delete wrap.dataset.smoke;
  }

  video.addEventListener("playing", onPlaying);
  video.addEventListener("error", onError);
  seen.observe(wrap);
  resized.observe(img);
  return stop;
}

/**
 * Starts every film under `root`, and stops them all again if the visitor
 * turns reduced motion on. Returns a function that stops everything.
 */
export function startSmoke(root = document) {
  // Without these the image simply stays as it is.
  if (
    typeof matchMedia !== "function" ||
    typeof IntersectionObserver !== "function" ||
    typeof ResizeObserver !== "function"
  ) {
    return () => {};
  }
  let stops = [];
  const query = matchMedia("(prefers-reduced-motion: reduce)");
  const apply = () => {
    stops.forEach((stop) => stop());
    stops = reduced() ? [] : [...root.querySelectorAll(".ix-smoke > img[data-smoke-video]")].map(smoke);
  };
  apply();
  query.addEventListener("change", apply);
  return () => {
    query.removeEventListener("change", apply);
    stops.forEach((stop) => stop());
    stops = [];
  };
}
