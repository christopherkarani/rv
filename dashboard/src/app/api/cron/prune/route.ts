import crypto from "node:crypto"
import { connection } from "next/server"
import { getServerEnv } from "@/lib/env"
import { adminClient } from "@/lib/supabase/admin"

// Daily retention job (vercel.json cron). Vercel sends
// `Authorization: Bearer $CRON_SECRET`; anything else is refused.
export async function GET(request: Request) {
  await connection()
  const secret = getServerEnv().CRON_SECRET
  const got = request.headers.get("authorization") ?? ""
  const want = `Bearer ${secret ?? ""}`
  if (!secret || got.length !== want.length || !crypto.timingSafeEqual(Buffer.from(got), Buffer.from(want))) {
    return new Response("unauthorized", { status: 401 })
  }
  const { data, error } = await adminClient().rpc("prune_expired")
  if (error) {
    console.error("prune_expired failed", error.message)
    return Response.json({ ok: false }, { status: 500 })
  }
  const row = (Array.isArray(data) ? data[0] : data) as { events_deleted?: number; reports_deleted?: number } | null
  return Response.json({ ok: true, eventsDeleted: row?.events_deleted ?? 0, reportsDeleted: row?.reports_deleted ?? 0 })
}
