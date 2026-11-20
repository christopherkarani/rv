import "server-only"
import { serverClient } from "@/lib/supabase/server"
import type { MachineRow } from "@/lib/machine-status"

// Reads for the dashboard, always as the signed-in user (RLS applies).

export const MACHINE_COLUMNS =
  "id, name, hostname, os_user, platform, rv_version, team, enrolled_at, revoked_at, last_report_at, last_event_at, last_seen_at, latest_report, compliant, chain_head, chain_status"

export type EventRow = {
  uid: string
  machine_id: string
  time: string
  kind: string
  decision: string
  subject: string
  host: string | null
  tool: string | null
  reason: string | null
  body: Record<string, unknown> | null
}
export const EVENT_COLUMNS = "uid, machine_id, time, kind, decision, subject, host, tool, reason, body"

function must<T>(res: { data: T | null; error: { message: string } | null }, what: string): T {
  if (res.error) throw new Error(`${what}: ${res.error.message}`)
  return res.data as T
}

export async function listMachines(orgId: string): Promise<MachineRow[]> {
  const supabase = await serverClient()
  const res = await supabase.from("machines").select(MACHINE_COLUMNS).eq("org_id", orgId).order("name")
  return must(res, "machines") as unknown as MachineRow[]
}

export async function getMachine(orgId: string, id: string): Promise<MachineRow | null> {
  if (!/^[0-9a-f-]{36}$/.test(id)) return null
  const supabase = await serverClient()
  const res = await supabase.from("machines").select(MACHINE_COLUMNS).eq("org_id", orgId).eq("id", id).maybeSingle()
  return must(res, "machine") as unknown as MachineRow | null
}

export async function currentPolicySerial(orgId: string): Promise<number | null> {
  const supabase = await serverClient()
  const res = await supabase
    .from("policy_revisions")
    .select("serial")
    .eq("org_id", orgId)
    .order("serial", { ascending: false })
    .limit(1)
    .maybeSingle()
  const row = must(res, "policy serial") as { serial: number } | null
  return row ? Number(row.serial) : null
}

export type DailyRow = { day: string; denied: number; observed: number; overrides: number }
export async function dailyActivity(orgId: string, days = 14): Promise<DailyRow[]> {
  const supabase = await serverClient()
  const res = await supabase.rpc("org_daily_activity", { p_org: orgId, p_days: days })
  return (must(res, "daily activity") as DailyRow[]).map((r) => ({
    day: r.day,
    denied: Number(r.denied),
    observed: Number(r.observed),
    overrides: Number(r.overrides),
  }))
}

export type TopRule = { subject: string; hits: number; machines: number; hosts: string[]; would_deny: number; would_ask: number }
export async function topRules(orgId: string, kind: string, sinceMs: number, limit = 10, host?: string): Promise<TopRule[]> {
  const supabase = await serverClient()
  const res = await supabase.rpc("org_top_rules", {
    p_org: orgId,
    p_kind: kind,
    p_since: new Date(sinceMs).toISOString(),
    p_limit: limit,
    p_host: host ?? null,
  })
  return (must(res, "top rules") as TopRule[]).map((r) => ({
    ...r,
    hits: Number(r.hits),
    machines: Number(r.machines),
    would_deny: Number(r.would_deny),
    would_ask: Number(r.would_ask),
    hosts: r.hosts ?? [],
  }))
}

export async function overrideCounts(orgId: string, sinceMs: number) {
  const supabase = await serverClient()
  const res = await supabase.rpc("org_override_counts", { p_org: orgId, p_since: new Date(sinceMs).toISOString() })
  return new Map((must(res, "overrides") as { subject: string; overrides: number }[]).map((r) => [r.subject, Number(r.overrides)]))
}

export type ObservedByHost = { host: string; would_deny: number; would_ask: number; machines: number }
export async function observedByHost(orgId: string, sinceMs: number): Promise<ObservedByHost[]> {
  const supabase = await serverClient()
  const res = await supabase.rpc("org_observed_by_host", { p_org: orgId, p_since: new Date(sinceMs).toISOString() })
  return (must(res, "observed by host") as ObservedByHost[]).map((r) => ({
    host: r.host,
    would_deny: Number(r.would_deny),
    would_ask: Number(r.would_ask),
    machines: Number(r.machines),
  }))
}

export type EventFilter = {
  kinds?: string[]
  host?: string
  machineId?: string
  subject?: string
  before?: string
  limit?: number
}
export async function listEvents(orgId: string, f: EventFilter = {}): Promise<EventRow[]> {
  const supabase = await serverClient()
  let q = supabase.from("events").select(EVENT_COLUMNS).eq("org_id", orgId)
  if (f.kinds?.length) q = q.in("kind", f.kinds)
  if (f.host) q = q.eq("host", f.host)
  if (f.machineId) q = q.eq("machine_id", f.machineId)
  if (f.subject) q = q.ilike("subject", `%${f.subject.replace(/[%_\\]/g, (c) => `\\${c}`)}%`)
  if (f.before) q = q.lt("time", f.before)
  const res = await q.order("time", { ascending: false }).limit(Math.min(f.limit ?? 100, 500))
  return must(res, "events") as EventRow[]
}

export type Finding = {
  id: number
  machine_id: string
  kind: "gap" | "broken"
  expected: string | null
  got: string | null
  detail: string | null
  detected_at: string
  resolved_at: string | null
}
export async function chainFindings(orgId: string, machineId?: string): Promise<Finding[]> {
  const supabase = await serverClient()
  let q = supabase.from("chain_findings").select("id, machine_id, kind, expected, got, detail, detected_at, resolved_at").eq("org_id", orgId)
  if (machineId) q = q.eq("machine_id", machineId)
  const res = await q.order("detected_at", { ascending: false }).limit(200)
  return must(res, "findings") as Finding[]
}

export type PolicyRevision = {
  id: string
  serial: number
  summary: string | null
  policy_sha256: string
  signing_key_id: string | null
  uploaded_by: string | null
  uploaded_at: string
}
export async function policyRevisions(orgId: string): Promise<PolicyRevision[]> {
  const supabase = await serverClient()
  const res = await supabase
    .from("policy_revisions")
    .select("id, serial, summary, policy_sha256, signing_key_id, uploaded_by, uploaded_at")
    .eq("org_id", orgId)
    .order("serial", { ascending: false })
    .limit(50)
  return (must(res, "policy revisions") as PolicyRevision[]).map((r) => ({ ...r, serial: Number(r.serial) }))
}

export async function policyRevisionText(orgId: string, serial: number) {
  const supabase = await serverClient()
  const res = await supabase
    .from("policy_revisions")
    .select("policy_text, signature, serial")
    .eq("org_id", orgId)
    .eq("serial", serial)
    .maybeSingle()
  return must(res, "policy") as { policy_text: string; signature: string; serial: number } | null
}

export type SigningKey = { id: string; public_key: string; label: string | null; added_at: string }
export async function signingKeys(orgId: string): Promise<SigningKey[]> {
  const supabase = await serverClient()
  const res = await supabase.from("org_signing_keys").select("id, public_key, label, added_at").eq("org_id", orgId).order("added_at")
  return must(res, "signing keys") as SigningKey[]
}

export async function orgSettings(orgId: string) {
  const supabase = await serverClient()
  const res = await supabase.from("orgs").select("id, name, slug, plan, retention_days, created_at").eq("id", orgId).single()
  return must(res, "org") as { id: string; name: string; slug: string; plan: string; retention_days: number; created_at: string }
}

export type Member = { user_id: string; email: string; role: "owner" | "admin" | "viewer"; created_at: string }
export async function members(orgId: string): Promise<Member[]> {
  const supabase = await serverClient()
  const res = await supabase.rpc("org_member_list", { p_org: orgId })
  return must(res, "members") as Member[]
}

export type Invite = { id: string; email: string; role: string; created_at: string; expires_at: string; accepted_at: string | null }
export async function invites(orgId: string): Promise<Invite[]> {
  const supabase = await serverClient()
  const res = await supabase
    .from("org_invites")
    .select("id, email, role, created_at, expires_at, accepted_at")
    .eq("org_id", orgId)
    .is("accepted_at", null)
    .order("created_at", { ascending: false })
  return must(res, "invites") as Invite[]
}

export type EnrollmentToken = {
  id: string
  prefix: string
  label: string | null
  created_at: string
  expires_at: string
  max_uses: number
  uses: number
  revoked_at: string | null
}
export async function enrollmentTokens(orgId: string): Promise<EnrollmentToken[]> {
  const supabase = await serverClient()
  const res = await supabase
    .from("enrollment_tokens")
    .select("id, prefix, label, created_at, expires_at, max_uses, uses, revoked_at")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
    .limit(50)
  return must(res, "enrollment tokens") as EnrollmentToken[]
}

export type AdminAuditRow = { id: number; actor_email: string | null; action: string; target: string | null; detail: Record<string, unknown>; at: string }
export async function adminAudit(orgId: string, limit = 50): Promise<AdminAuditRow[]> {
  const supabase = await serverClient()
  const res = await supabase.rpc("org_admin_audit", { p_org: orgId, p_limit: limit })
  return must(res, "admin audit") as AdminAuditRow[]
}
