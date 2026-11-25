// Byte ranges for media files. Workers static assets answer a Range request
// with the whole file (200, no Content-Range), as GitHub Pages did not: Safari
// will not play a video that way, and audio cannot seek. wrangler.jsonc sends
// only the media paths here (assets.run_worker_first); everything else is
// served by static assets directly, without this script.
export default {
  async fetch(request, env) {
    const asset = await env.ASSETS.fetch(request);
    const headers = new Headers(asset.headers);
    headers.set('Accept-Ranges', 'bytes');
    const range = /^bytes=(\d*)-(\d*)$/.exec(request.headers.get('Range') ?? '');
    if (request.method !== 'GET' || asset.status !== 200 || !range || (range[1] === '' && range[2] === '')) {
      return new Response(asset.body, { status: asset.status, statusText: asset.statusText, headers });
    }
    let body = asset.body;
    let size = Number(asset.headers.get('Content-Length'));
    if (!asset.headers.has('Content-Length')) {
      const bytes = await asset.arrayBuffer();
      size = bytes.byteLength;
      body = new Blob([bytes]).stream();
    }
    // "bytes=a-b", "bytes=a-" or the last n bytes, "bytes=-n".
    const start = range[1] === '' ? Math.max(size - Number(range[2]), 0) : Number(range[1]);
    const end = range[1] === '' || range[2] === '' ? size - 1 : Math.min(Number(range[2]), size - 1);
    if (start > end) {
      await body.cancel();
      headers.set('Content-Range', `bytes */${size}`);
      headers.delete('Content-Length');
      return new Response(null, { status: 416, headers });
    }
    headers.set('Content-Range', `bytes ${start}-${end}/${size}`);
    headers.set('Content-Length', String(end - start + 1));
    return new Response(body.pipeThrough(slice(start, end + 1)).pipeThrough(new FixedLengthStream(end - start + 1)), {
      status: 206,
      headers,
    });
  },
};

// Passes on the bytes [start, stop) of a stream and stops reading after them.
function slice(start, stop) {
  let pos = 0;
  return new TransformStream({
    transform(chunk, controller) {
      const from = Math.max(start - pos, 0);
      const to = Math.min(stop - pos, chunk.byteLength);
      pos += chunk.byteLength;
      if (from < to) controller.enqueue(chunk.subarray(from, to));
      if (pos >= stop) controller.terminate();
    },
  });
}
