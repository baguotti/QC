// QCpie notes sync: stores one end-to-end encrypted blob per (room, clip).
// The app derives room and clip ids from the shared password, so the server never sees names or note text.
// GET  /v1/<room>/<clip>[?since=<version>] -> 200 {version, data} | 204 when version == since
// PUT  /v1/<room>/<clip> {base, data}      -> 200 {version} | 409 when someone else wrote first

const PATH = /^\/v1\/([0-9a-f]{32})\/([0-9a-f]{64})$/;
const MAX_BLOB = 2_000_000;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
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
