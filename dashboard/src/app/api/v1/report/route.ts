import { adminClient } from "@/lib/supabase/admin"
import { isCompliant, reportSchema } from "@/lib/ingest/report"
import { authenticateMachine, jsonError, rateLimited, readJson } from "@/lib/server/http"

// POST /api/v1/report
// Body: one `rv report --json` document (rv.report.v1).

export async function POST(request: Request) {
  const auth = await authenticateMachine(request)
  if (!auth.ok) return auth.response
  const limited = await rateLimited(`report:${auth.machine.id}`, 120, 3600)
  if (limited) return limited

  const body = await readJson(request, 1024 * 1024)
  if (!body.ok) return body.response
  const parsed = reportSchema.safeParse(body.value)
  if (!parsed.success) {
    const issue = parsed.error.issues[0]
    return jsonError(400, "invalid_report", `${issue?.path.join(".") || "body"}: ${issue?.message ?? "invalid"}`)
  }
  const compliant = isCompliant(parsed.data)
  const { error } = await adminClient().rpc("ingest_report", {
    p_machine: auth.machine.id,
    p_report: parsed.data,
    p_compliant: compliant,
  })
  if (error) {
    console.error("ingest_report failed", error.message)
    return jsonError(503, "unavailable", "could not store the report; retry")
  }
  return Response.json({ accepted: true, compliant }, { status: 202 })
}
