import { assess, newestVersion } from "@/lib/machine-status"
import { currentPolicySerial, listMachines } from "@/lib/queries"
import { getSession } from "@/lib/session"

// GET /api/export/machines — one CSV row per machine.
const csv = (v: unknown) => {
  const s = v == null ? "" : String(v)
  // Quote everything; neutralize spreadsheet formulas.
  const safe = /^[=+\-@\t\r]/.test(s) ? `'${s}` : s
  return `"${safe.replace(/"/g, '""')}"`
}

export async function GET() {
  const { org } = await getSession()
  const now = Date.now()
  const [machines, serial] = await Promise.all([listMachines(org.orgId), currentPolicySerial(org.orgId)])
  const latest = newestVersion(machines.map((m) => m.rv_version))
  const header = ["name", "team", "status", "issues", "platform", "rv_version", "policy_serial", "compliant", "chain_status", "last_seen_at", "enrolled_at", "revoked_at"]
  const rows = machines.map((m) => {
    const a = assess(m, { now, currentSerial: serial, latestVersion: latest })
    return [
      m.name,
      m.team,
      a.label,
      a.issues.join("; "),
      m.platform,
      m.rv_version,
      m.latest_report?.managed?.serial,
      m.compliant,
      m.chain_status,
      m.last_seen_at,
      m.enrolled_at,
      m.revoked_at,
    ]
  })
  const body = [header, ...rows].map((r) => r.map(csv).join(",")).join("\r\n") + "\r\n"
  return new Response(body, {
    headers: {
      "content-type": "text/csv; charset=utf-8",
      "content-disposition": `attachment; filename="rv-machines-${org.slug}-${new Date().toISOString().slice(0, 10)}.csv"`,
      "cache-control": "no-store",
    },
  })
}
