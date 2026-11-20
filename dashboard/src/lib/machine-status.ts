import type { HostMode } from "@/lib/vocab"
import { hostLabel } from "@/lib/vocab"

// Pure helpers that turn a machine row (with its latest rv.report.v1) into
// what the UI shows. No I/O, so they are unit-tested directly.

export type MachineRow = {
  id: string
  name: string
  hostname: string | null
  os_user: string | null
  platform: string | null
  rv_version: string | null
  team: string | null
  enrolled_at: string
  revoked_at: string | null
  last_report_at: string | null
  last_event_at: string | null
  last_seen_at: string | null
  latest_report: LatestReport | null
  compliant: boolean | null
  chain_head: string | null
  chain_status: "unknown" | "ok" | "gap" | "broken"
}

export type LatestReport = {
  managed?: { state?: "none" | "invalid" | "active"; serial?: number; reason?: string; organization?: string }
  mcp?: { ok?: boolean; servers?: number; failing?: { name: string; host: string; status: string }[]; plaintextCredentials?: number }
  secrets?: { error?: string | null; items?: { name: string; source: string; policyViolation?: string | null }[] }
  audit?: { chainIntact?: boolean | null; total?: number }
  sandbox?: { mcpSandbox?: boolean }
  hosts?: Partial<Record<string, HostMode>>
  packs?: string[]
}

export const SILENT_AFTER_MS = 24 * 60 * 60 * 1000

export type MachineState = "revoked" | "pending" | "silent" | "noncompliant" | "drift" | "healthy"

export type Assessment = {
  state: MachineState
  label: string
  tone: "success" | "warning" | "error" | "neutral"
  /** Most important first: reasons that break compliance lead. */
  issues: string[]
}

export function assess(m: MachineRow, opts: { now: number; currentSerial: number | null; latestVersion: string | null }): Assessment {
  const r = m.latest_report
  const issues: string[] = []

  if (r) {
    if (r.managed?.state === "invalid") issues.push(`Org policy does not verify${r.managed.reason ? `: ${r.managed.reason}` : ""}`)
    if (r.audit?.chainIntact === false) issues.push("Audit chain broken (rv audit verify fails)")
    if (r.mcp?.ok === false) issues.push(`MCP check failing${r.mcp.failing?.length ? `: ${r.mcp.failing.map((f) => f.name).join(", ")}` : ""}`)
    if (r.secrets?.error) issues.push(`Secrets config error: ${r.secrets.error}`)
    for (const s of r.secrets?.items ?? []) if (s.policyViolation) issues.push(`Secret ${s.name}: ${s.policyViolation}`)
  }
  if (m.chain_status === "gap") issues.push("Forwarded audit chain has a gap")
  if (r) {
    for (const [host, mode] of Object.entries(r.hosts ?? {})) if (mode === "off") issues.push(`${hostLabel(host)} guard is off`)
    if (r.managed?.state === "none") issues.push("No org policy installed")
    if (r.managed?.state === "active" && opts.currentSerial != null && (r.managed.serial ?? -1) < opts.currentSerial) {
      issues.push(`Policy serial ${r.managed.serial ?? "unset"}, current is ${opts.currentSerial}`)
    }
    if ((r.mcp?.plaintextCredentials ?? 0) > 0) issues.push("Plaintext credential in an MCP config")
  }
  if (opts.latestVersion && m.rv_version && compareVersions(m.rv_version, opts.latestVersion) < 0) {
    issues.push(`rv ${m.rv_version}; ${opts.latestVersion} is the newest in this org`)
  }

  const lastSeen = m.last_seen_at ? Date.parse(m.last_seen_at) : null
  if (m.revoked_at) return { state: "revoked", label: "Revoked", tone: "neutral", issues: ["Credential revoked"] }
  if (!r) return { state: "pending", label: "Awaiting report", tone: "neutral", issues }
  if (lastSeen == null || opts.now - lastSeen > SILENT_AFTER_MS) {
    return { state: "silent", label: "Silent", tone: "neutral", issues: ["Nothing received in over 24 hours", ...issues] }
  }
  if (m.compliant === false) return { state: "noncompliant", label: "Non-compliant", tone: "error", issues }
  if (issues.length > 0) return { state: "drift", label: "Drift", tone: "warning", issues }
  return { state: "healthy", label: "Healthy", tone: "success", issues }
}

/** Compares dotted numeric versions (0.2.10 > 0.2.9). Non-numeric parts compare as 0. */
export function compareVersions(a: string, b: string) {
  const pa = a.split(/[.+-]/).map((x) => Number.parseInt(x, 10) || 0)
  const pb = b.split(/[.+-]/).map((x) => Number.parseInt(x, 10) || 0)
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0)
    if (d !== 0) return d < 0 ? -1 : 1
  }
  return 0
}

export function newestVersion(versions: (string | null)[]) {
  return versions.filter((v): v is string => Boolean(v)).sort(compareVersions).at(-1) ?? null
}

export function timeAgo(iso: string | null | undefined, now: number) {
  if (!iso) return "never"
  const s = Math.max(0, Math.round((now - Date.parse(iso)) / 1000))
  if (s < 60) return "just now"
  const m = Math.round(s / 60)
  if (m < 60) return `${m}m ago`
  const h = Math.round(m / 60)
  if (h < 48) return `${h}h ago`
  return `${Math.round(h / 24)}d ago`
}
