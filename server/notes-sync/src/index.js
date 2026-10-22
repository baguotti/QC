// QCpie notes sync: stores one end-to-end encrypted blob per (room, clip).
// The app derives room and clip ids from the shared password, so the server never sees names or note text.
// GET  /v1/<room>/<clip>[?since=<version>] -> 200 {version, data} | 204 when version == since
// PUT  /v1/<room>/<clip> {base, data}      -> 200 {version} | 409 when someone else wrote first

//
// Missed-line reports (the Player's MISSED LINE button):
// POST /v1/frames  (PNG body)              -> 200 {id} ; kept 90 days in KV (binding FRAMES)
// GET  /v1/frames/<id>                     -> the PNG ; ids are random 32-hex, so links can't be guessed

const PATH = /^\/v1\/([0-9a-f]{32})\/([0-9a-f]{64})$/;
const FRAME_PATH = /^\/v1\/frames\/([0-9a-f]{32})$/;
const MAX_BLOB = 2_000_000;
const MAX_FRAME = 24_000_000;              // KV values may be up to 25 MB; an 8K PNG fits
const FRAME_TTL = 90 * 24 * 3600;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/v1/frames" || FRAME_PATH.test(url.pathname)) return frames(request, env, url);
    const match = url.pathname.match(PATH);
    if (!match) return new Response("Not found", { status: 404 });
    const [, room, clip] = match;

    if (request.method === "GET") {
      const row = await env.DB.prepare("SELECT version, data FROM clips WHERE room = ?1 AND clip = ?2")
        .bind(room, clip).first();
      if (!row) return Response.json({ version: 0, data: null });
      if (url.searchParams.get("since") === String(row.version)) return new Response(null, { status: 204 });
      return Response.json({ version: row.version, data: row.data });
    }

    if (request.method === "PUT") {
      let body;
      try { body = await request.json(); } catch { return new Response("Bad JSON", { status: 400 }); }
      const base = Number(body.base);
      if (!Number.isInteger(base) || base < 0 || typeof body.data !== "string") return new Response("Bad request", { status: 400 });
      if (body.data.length > MAX_BLOB) return new Response("Too large", { status: 413 });

      const now = Date.now();
      const result = base === 0
        ? await env.DB.prepare("INSERT INTO clips (room, clip, version, data, updated_at) VALUES (?1, ?2, 1, ?3, ?4) ON CONFLICT DO NOTHING")
            .bind(room, clip, body.data, now).run()
        : await env.DB.prepare("UPDATE clips SET version = version + 1, data = ?3, updated_at = ?4 WHERE room = ?1 AND clip = ?2 AND version = ?5")
            .bind(room, clip, body.data, now, base).run();
      if (result.meta.changes === 0) return new Response("Conflict", { status: 409 });
      return Response.json({ version: base + 1 });
    }

    return new Response("Method not allowed", { status: 405 });
  },
};

async function frames(request, env, url) {
  if (!env.FRAMES) return new Response("Frame storage not configured", { status: 503 });
  if (request.method === "POST" && url.pathname === "/v1/frames") {
    if (request.headers.get("content-type") !== "image/png") return new Response("PNG only", { status: 415 });
    const body = await request.arrayBuffer();
    if (body.byteLength < 8 || body.byteLength > MAX_FRAME) return new Response("Bad size", { status: 413 });
    const signature = new Uint8Array(body, 0, 8);
    if (signature[0] !== 0x89 || signature[1] !== 0x50 || signature[2] !== 0x4e || signature[3] !== 0x47) return new Response("PNG only", { status: 415 });
    const id = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
    await env.FRAMES.put(id, body, { expirationTtl: FRAME_TTL });
    return Response.json({ id });
  }
  const match = url.pathname.match(FRAME_PATH);
  if (request.method === "GET" && match) {
    const png = await env.FRAMES.get(match[1], "arrayBuffer");
    if (!png) return new Response("Not found (frames are kept 90 days)", { status: 404 });
    return new Response(png, { headers: { "content-type": "image/png", "cache-control": "private, max-age=86400" } });
  }
  return new Response("Method not allowed", { status: 405 });
}
