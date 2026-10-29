// floo.run — the short entry point.
//
//   curl -s https://floo.run/sh | bash
//
// This Worker serves the bytes of ONE pinned release tag straight from GitHub; it never
// serves `main`. The tag is a constant below and moves only with a deploy, so "what you
// read on GitHub under that tag is what you run" holds for the short URL too.
//
//   /            -> floo            (the client, pinned tag)
//   /sh          -> bin/floo-sh     (no-flags wrapper: fetches the tag's floo, runs --public)
//   /go          -> the same file (the name used by v0.8.1 texts)
//   /powder      -> bin/floo-powder (the operator script, pinned tag)
//   /vX.Y.Z      -> floo at that tag
//   /vX.Y.Z/powder
//   /version     -> the pinned tag
//
// A browser (Accept: text/html) asking for / gets a one-screen landing page instead.

const TAG = "v0.8.1";
const REPO = "interkelstar/floo";
const FILES = {
  "": "floo",
  "floo": "floo",
  "powder": "bin/floo-powder",
  "floo-powder": "bin/floo-powder",
  "sh": "bin/floo-sh", // `curl -s https://floo.run/sh | bash` — no flags; exists from v0.8.1
  "go": "bin/floo-sh", // v0.8.1 spelled it /go; kept so that text keeps working
};
const TAG_RE = /^v\d+\.\d+\.\d+$/;

function text(body, status = 200, extra = {}) {
  return new Response(body, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", ...extra },
  });
}

// What a browser sees at floo.run. Everything a terminal gets from the same URL is the tag's bytes.
function landing(tag) {
  const raw = `https://raw.githubusercontent.com/${REPO}/${tag}`;
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>floo — help a friend in their terminal</title>
<meta name="description" content="Temporary, recorded, Ctrl-C-revocable shell access to a Linux box you don't own. One bash file, nothing installed, nothing listening.">
<style>
:root{--bg:#fff;--fg:#1a1a1a;--mut:#666;--code:#f4f4f4;--acc:#b5451b}
@media(prefers-color-scheme:dark){:root{--bg:#121212;--fg:#e8e8e8;--mut:#9a9a9a;--code:#1e1e1e;--acc:#ff8c5a}}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 system-ui,sans-serif}
main{max-width:720px;margin:0 auto;padding:48px 16px 64px}
h1{font-size:2rem;margin:0 0 .25em}h1 span{color:var(--acc)}
h2{font-size:1.1rem;margin:2em 0 .5em}
p{margin:.6em 0}.mut{color:var(--mut)}
pre{background:var(--code);padding:12px 14px;border-radius:8px;overflow-x:auto;font-size:.92rem;line-height:1.45}
code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
a{color:var(--acc)}
</style></head><body><main>
<h1><span>floo</span> — help a friend in their terminal</h1>
<p>Temporary, recorded shell access to a Linux box you don't own. The box dials <em>out</em>, nothing is installed,
nothing listens, nothing runs as root, and <strong>Ctrl-C</strong> ends it. Two bash files; read them before you run them.</p>

<h2>They need help — they run this and read you the code it prints</h2>
<pre><code>curl -s https://floo.run/sh | bash</code></pre>

<h2>You're helping — paste this with their code</h2>
<pre><code>bash &lt;(curl -s https://floo.run/powder) connect THE-CODE</code></pre>

<h2>Don't trust us — read us</h2>
<p>This domain serves the bytes of release <a href="https://github.com/${REPO}/tree/${tag}"><code>${tag}</code></a>, never <code>main</code>;
tags in the repository are immutable. <code>floo.run</code> is <a href="${raw}/floo">floo</a>, <code>floo.run/sh</code> is a
<a href="${raw}/bin/floo-sh">20-line wrapper</a> that fetches that <code>floo</code> and starts it in quick mode (the public relay
<code>relay.floo.run</code> and its host-key pin are constants inside <code>floo</code> itself), <code>floo.run/powder</code> is
<a href="${raw}/bin/floo-powder">floo-powder</a>, <code>floo.run/version</code> says which tag. Download, read, then run:</p>
<pre><code>curl -fsSL https://floo.run -o floo &amp;&amp; less floo &amp;&amp; bash floo --public</code></pre>
<p class="mut">The public relay is a courtesy with no guarantees (quick sessions up to 30 minutes). For anything ongoing or sensitive,
run your own relay in CA mode — see the <a href="https://github.com/${REPO}#readme">README</a>, <a href="https://github.com/${REPO}/blob/${tag}/docs/THREAT-MODEL.md">threat model</a>
and <a href="https://github.com/${REPO}/blob/${tag}/docs/READING.md">reading map</a>. MIT.</p>
</main></body></html>`;
}

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return text("method not allowed\n", 405, { allow: "GET, HEAD" });
    }
    const url = new URL(request.url);
    // scripts only over TLS: a plain-http `curl | bash` is an invitation to anyone on the path
    if (url.protocol === "http:") {
      url.protocol = "https:";
      return Response.redirect(url.toString(), 301);
    }
    const parts = url.pathname.split("/").filter(Boolean);

    let tag = TAG;
    if (parts.length && TAG_RE.test(parts[0])) tag = parts.shift();
    const key = parts.join("/");

    if (key === "version") return text(tag + "\n");
    if (!(key in FILES)) return text("not found\n", 404);

    const accept = request.headers.get("accept") || "";
    if (key === "" && accept.includes("text/html")) {
      return new Response(landing(tag), {
        status: 200,
        // never let a shared cache hand this HTML to a `curl | bash` under the same URL
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "no-store",
          "vary": "Accept",
          "strict-transport-security": "max-age=31536000; includeSubDomains",
        },
      });
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
          "vary": "Accept",
          "strict-transport-security": "max-age=31536000; includeSubDomains",
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
