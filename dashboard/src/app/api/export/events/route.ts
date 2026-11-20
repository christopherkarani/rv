import { getSession } from "@/lib/session"
import { serverClient } from "@/lib/supabase/server"

// GET /api/export/events
// JSON Lines, oldest first: each event exactly as the machine forwarded it
// (OCSF 1.3.0 for rv's default forwarder, rv.audit.v1 otherwise), with the
// machine and receive time. Paged so memory stays flat; RLS applies.
const PAGE = 1000

export async function GET() {
  const { org } = await getSession()
  const supabase = await serverClient()
  const { data: machines } = await supabase.from("machines").select("id, name").eq("org_id", org.orgId)
  const names = new Map((machines ?? []).map((m) => [m.id as string, m.name as string]))
  const encoder = new TextEncoder()

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      let cursor: { time: string; uid: string } | null = null
      try {
        for (;;) {
          let q = supabase.from("events").select("uid, machine_id, time, received_at, body").eq("org_id", org.orgId)
          if (cursor) q = q.or(`time.gt."${cursor.time}",and(time.eq."${cursor.time}",uid.gt."${cursor.uid}")`)
          const { data, error } = await q.order("time").order("uid").limit(PAGE)
          if (error) throw new Error(error.message)
          for (const e of data ?? []) {
            const line = { machine: names.get(e.machine_id) ?? e.machine_id, received_at: e.received_at, event: e.body }
            controller.enqueue(encoder.encode(JSON.stringify(line) + "\n"))
          }
          if (!data || data.length < PAGE) break
          const last = data[data.length - 1]
          cursor = { time: last.time, uid: last.uid }
        }
        controller.close()
      } catch (err) {
        controller.error(err)
      }
    },
  })

  const date = new Date().toISOString().slice(0, 10)
  return new Response(stream, {
    headers: {
      "content-type": "application/x-ndjson; charset=utf-8",
      "content-disposition": `attachment; filename="rv-events-${org.slug}-${date}.jsonl"`,
      "cache-control": "no-store",
    },
  })
}
