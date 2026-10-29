// floo.run — the short entry point.
//
//   curl -fsSL floo.run | bash -s -- --public --relay floo.kelstar.me --pin <RELAY16>
//
// This Worker serves the bytes of ONE pinned release tag straight from GitHub; it never
// serves `main`. The tag is a constant below and moves only with a deploy, so "what you
// read on GitHub under that tag is what you run" holds for the short URL too.
//
//   /            -> floo            (the client, pinned tag)
//   /powder      -> bin/floo-powder (the operator script, pinned tag)
//   /vX.Y.Z      -> floo at that tag
//   /vX.Y.Z/powder
//   /version     -> the pinned tag
//
// A browser (Accept: text/html) asking for / is sent to the tagged tree on GitHub instead.

const TAG = "v0.7.4";
const REPO = "interkelstar/floo";
const FILES = {
  "": "floo",
  "floo": "floo",
  "powder": "bin/floo-powder",
  "floo-powder": "bin/floo-powder",
};
const TAG_RE = /^v\d+\.\d+\.\d+$/;

function text(body, status = 200, extra = {}) {
  return new Response(body, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", ...extra },
  });
}

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return text("method not allowed\n", 405, { allow: "GET, HEAD" });
    }
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);

    let tag = TAG;
    if (parts.length && TAG_RE.test(parts[0])) tag = parts.shift();
    const key = parts.join("/");

    if (key === "version") return text(tag + "\n");
    if (!(key in FILES)) return text("not found\n", 404);

    const accept = request.headers.get("accept") || "";
    if (key === "" && accept.includes("text/html")) {
      return Response.redirect(`https://github.com/${REPO}/tree/${tag}`, 302);
    }

    const upstream = `https://raw.githubusercontent.com/${REPO}/${tag}/${FILES[key]}`;
    const cache = caches.default;
    const cacheKey = new Request(upstream, { method: "GET" });

    let response = await cache.match(cacheKey);
    if (!response) {
      const up = await fetch(upstream, { cf: { cacheTtl: 3600 } });
      if (!up.ok) return text(`upstream ${up.status} for ${upstream}\n`, 502);
      response = new Response(up.body, {
        status: 200,
        headers: {
          "content-type": "text/plain; charset=utf-8",
          "cache-control": "public, max-age=3600",
          "x-floo-tag": tag,
          "x-floo-source": upstream,
        },
      });
      ctx.waitUntil(cache.put(cacheKey, response.clone()));
    }
    if (request.method === "HEAD") return new Response(null, { status: 200, headers: response.headers });
    return response;
  },
};
