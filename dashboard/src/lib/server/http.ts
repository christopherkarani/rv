import "server-only"
import { adminClient } from "@/lib/supabase/admin"
import { bearer, hashSecret, isWellFormed } from "@/lib/server/credentials"

export function jsonError(status: number, code: string, message: string, headers?: HeadersInit) {
  return Response.json({ error: { code, message } }, { status, headers })
}

/** Reads a JSON body without buffering more than `maxBytes`. */
export async function readJson(request: Request, maxBytes: number): Promise<{ ok: true; value: unknown } | { ok: false; response: Response }> {
  const declared = Number(request.headers.get("content-length") ?? "0")
  if (declared > maxBytes) {
    return { ok: false, response: jsonError(413, "too_large", `body over ${maxBytes} bytes`) }
  }
  const type = request.headers.get("content-type") ?? ""
  if (!type.toLowerCase().startsWith("application/json")) {
    return { ok: false, response: jsonError(415, "unsupported_media_type", "send Content-Type: application/json") }
  }
  if (!request.body) return { ok: false, response: jsonError(400, "empty", "empty body") }
  const reader = request.body.getReader()
  const chunks: Uint8Array[] = []
  let size = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    size += value.byteLength
    if (size > maxBytes) {
      await reader.cancel()
      return { ok: false, response: jsonError(413, "too_large", `body over ${maxBytes} bytes`) }
    }
    chunks.push(value)
  }
  try {
    return { ok: true, value: JSON.parse(Buffer.concat(chunks).toString("utf8")) }
  } catch {
    return { ok: false, response: jsonError(400, "invalid_json", "body is not valid JSON") }
  }
}

export function clientIp(request: Request) {
  return (
    request.headers.get("x-real-ip") ??
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    "unknown"
  )
}

/** Fixed-window limit shared across instances via Postgres. Fails open only on DB error. */
export async function rateLimited(key: string, limit: number, windowSeconds: number): Promise<Response | null> {
  const { data, error } = await adminClient().rpc("take_rate_limit", {
    p_key: key,
    p_limit: limit,
    p_window_seconds: windowSeconds,
  })
  if (error) {
    console.error("rate limit check failed", error.message)
    return null
  }
  if (data === false) {
    return jsonError(429, "rate_limited", "too many requests; retry later", { "retry-after": String(windowSeconds) })
  }
  return null
}

export type AuthedMachine = { id: string; org_id: string; name: string }

/** Resolves `Authorization: Bearer rvc_mch_…` to a live machine. */
export async function authenticateMachine(request: Request): Promise<{ ok: true; machine: AuthedMachine } | { ok: false; response: Response }> {
  const token = bearer(request)
  if (!token || !isWellFormed(token, "mch")) {
    return { ok: false, response: jsonError(401, "unauthorized", "send Authorization: Bearer <machine credential>") }
  }
  const { data, error } = await adminClient()
    .from("machines")
    .select("id, org_id, name")
    .eq("credential_hash", hashSecret(token))
    .is("revoked_at", null)
    .maybeSingle()
  if (error) {
    console.error("machine lookup failed", error.message)
    return { ok: false, response: jsonError(503, "unavailable", "try again") }
  }
  if (!data) return { ok: false, response: jsonError(401, "unauthorized", "unknown or revoked machine credential") }
  return { ok: true, machine: data as AuthedMachine }
}
