import { adminClient } from "@/lib/supabase/admin"
import { parseEventBatch } from "@/lib/ingest/events"
import { authenticateMachine, jsonError, rateLimited, readJson } from "@/lib/server/http"

// POST /api/v1/events
// Body: what `rv audit forward --to <this URL>` sends, a JSON array of
// rv.audit.v1 events or OCSF 1.3.0 objects. rv advances its cursor only on
// a 2xx, so a non-2xx here means "send this batch again".

export async function POST(request: Request) {
  const auth = await authenticateMachine(request)
  if (!auth.ok) return auth.response
  const limited = await rateLimited(`events:${auth.machine.id}`, 240, 60)
  if (limited) return limited

  const body = await readJson(request, 8 * 1024 * 1024)
  if (!body.ok) return body.response
  const parsed = parseEventBatch(body.value)
  if (!parsed.ok) return jsonError(400, "invalid_events", parsed.error)
  if (parsed.events.length === 0) return Response.json({ inserted: 0, duplicates: 0, gaps: 0 })

  const { data, error } = await adminClient().rpc("ingest_events", {
    p_machine: auth.machine.id,
    p_events: parsed.events,
  })
  if (error) {
    console.error("ingest_events failed", error.message)
    return jsonError(503, "unavailable", "could not store events; retry")
  }
  const row = Array.isArray(data) ? data[0] : data
  return Response.json({ inserted: row?.inserted ?? 0, duplicates: row?.duplicates ?? 0, gaps: row?.gaps ?? 0 })
}
