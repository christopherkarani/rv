import { z } from "zod"
import { getServerEnv } from "@/lib/env"
import { adminClient } from "@/lib/supabase/admin"
import { MACHINE_PREFIX, displayPrefix, hashSecret, isWellFormed, newSecret } from "@/lib/server/credentials"
import { clientIp, jsonError, rateLimited, readJson } from "@/lib/server/http"

// POST /api/v1/enroll
// Exchanges an org enrollment token for a per-machine credential. The
// credential is returned once and stored only as a hash.

const bodySchema = z.object({
  token: z.string().max(128),
  name: z.string().trim().min(1).max(255),
  platform: z.string().max(64).optional(),
  rvVersion: z.string().max(64).optional(),
})

export async function POST(request: Request) {
  const limited = await rateLimited(`enroll:${clientIp(request)}`, 30, 3600)
  if (limited) return limited

  const body = await readJson(request, 16 * 1024)
  if (!body.ok) return body.response
  const parsed = bodySchema.safeParse(body.value)
  if (!parsed.success) return jsonError(400, "invalid", parsed.error.issues[0]?.message ?? "invalid body")
  const { token, name, platform, rvVersion } = parsed.data
  if (!isWellFormed(token, "enr")) return jsonError(401, "invalid_token", "enrollment token is invalid, expired or used up")

  const credential = newSecret(MACHINE_PREFIX)
  const { data, error } = await adminClient().rpc("enroll_machine", {
    p_token_hash: hashSecret(token),
    p_credential_hash: hashSecret(credential),
    p_credential_prefix: displayPrefix(credential),
    p_name: name,
    p_platform: platform ?? null,
    p_rv_version: rvVersion ?? null,
  })
  if (error) {
    console.error("enroll failed", error.message)
    return jsonError(503, "unavailable", "enrollment failed; try again")
  }
  const row = Array.isArray(data) ? data[0] : null
  if (!row) return jsonError(401, "invalid_token", "enrollment token is invalid, expired or used up")

  const base = getServerEnv().APP_URL.replace(/\/$/, "")
  return Response.json(
    {
      machineId: row.machine_id,
      orgId: row.org_id,
      credential,
      endpoints: { events: `${base}/api/v1/events`, report: `${base}/api/v1/report` },
    },
    { status: 201, headers: { "cache-control": "no-store" } },
  )
}
