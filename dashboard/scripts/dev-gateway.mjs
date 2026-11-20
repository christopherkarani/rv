// Minimal stand-in for Supabase's API gateway during local development:
//   /auth/v1/*  -> GoTrue
//   /rest/v1/*  -> PostgREST
// Hosted Supabase does this with Kong; nothing here runs in production.
import http from "node:http"

const PORT = Number(process.env.GATEWAY_PORT ?? 54321)
const ROUTES = [
  { prefix: "/auth/v1", target: process.env.AUTH_URL ?? "http://127.0.0.1:54329" },
  { prefix: "/rest/v1", target: process.env.REST_URL ?? "http://127.0.0.1:54330" },
]

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info, prefer, accept-profile, content-profile, range",
  "access-control-allow-methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
  "access-control-expose-headers": "content-range, content-location",
}

http
  .createServer((req, res) => {
    if (req.method === "OPTIONS") {
      res.writeHead(204, CORS).end()
      return
    }
    const route = ROUTES.find((r) => req.url.startsWith(r.prefix + "/") || req.url === r.prefix)
    if (!route) {
      res.writeHead(404, { "content-type": "application/json", ...CORS }).end('{"message":"no route"}')
      return
    }
    const url = new URL(req.url.slice(route.prefix.length) || "/", route.target)
    const headers = { ...req.headers, host: url.host }
    const upstream = http.request(url, { method: req.method, headers }, (up) => {
      res.writeHead(up.statusCode ?? 502, { ...up.headers, ...CORS })
      up.pipe(res)
    })
    upstream.on("error", (err) => {
      res.writeHead(502, { "content-type": "application/json", ...CORS }).end(JSON.stringify({ message: String(err) }))
    })
    req.pipe(upstream)
  })
  .listen(PORT, "127.0.0.1", () => console.log(`dev gateway on http://127.0.0.1:${PORT}`))
