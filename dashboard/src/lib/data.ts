// Mock fleet data for the rv Cloud dashboard prototype.
//
// Shapes follow what the rv client already emits:
//   - Machine  ~ one `rv.report.v1` document (Sources/RVCLI/Commands/ReportCommand.swift)
//   - AuditEvent ~ one `rv.audit.v1` record forwarded by `rv audit forward`
//   - pack and rule ids are real ids from Sources/RVPacks/Resources/packs
//
// Everything is generated from a fixed seed and a fixed "now" so server and
// client renders agree (no hydration mismatch).

export const NOW = Date.parse("2026-11-20T12:00:00Z")
const HOUR = 3_600_000
const DAY = 24 * HOUR

function mulberry32(seed: number) {
  return () => {
    seed |= 0
    seed = (seed + 0x6d2b79f5) | 0
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}
const rand = mulberry32(20261120)
const pick = <T,>(xs: readonly T[]): T => xs[Math.floor(rand() * xs.length)]
const hex = (n: number) =>
  Array.from({ length: n }, () => Math.floor(rand() * 16).toString(16)).join("")

// ---------------------------------------------------------------------------
// Vocabulary

export const AGENT_HOSTS = ["claude", "codex", "cursor", "opencode", "grok"] as const
export type AgentHost = (typeof AGENT_HOSTS)[number]
export const HOST_LABEL: Record<AgentHost, string> = {
  claude: "Claude Code",
  codex: "Codex",
  cursor: "Cursor",
  opencode: "OpenCode",
  grok: "Grok",
}

export type HostMode = "block" | "observe" | "off"
export type Platform = "macos-arm64" | "linux-x86_64" | "linux-aarch64"
export const PLATFORM_LABEL: Record<Platform, string> = {
  "macos-arm64": "macOS · Apple Silicon",
  "linux-x86_64": "Linux · x86_64",
  "linux-aarch64": "Linux · aarch64",
}

export const LATEST_VERSION = "0.2.2"
const VERSIONS = ["0.2.2", "0.2.2", "0.2.2", "0.2.1", "0.2.1", "0.2.0"] as const

export const TEAMS = ["Platform", "Payments", "Web", "Mobile", "Data"] as const
export type Team = (typeof TEAMS)[number]

export type Pack = { id: string; name: string; category: string; defaultOn?: boolean }
export const PACKS: Pack[] = [
  { id: "core.filesystem", name: "Core Filesystem", category: "core", defaultOn: true },
  { id: "core.git", name: "Core Git", category: "core", defaultOn: true },
  { id: "system.disk", name: "Disk Operations", category: "system", defaultOn: true },
  { id: "strict_git", name: "Strict Git", category: "core" },
  { id: "system.permissions", name: "Permissions", category: "system" },
  { id: "system.services", name: "Services", category: "system" },
  { id: "package_managers", name: "Package Managers", category: "system" },
  { id: "cloud.aws", name: "AWS CLI", category: "cloud" },
  { id: "cloud.gcp", name: "Google Cloud SDK", category: "cloud" },
  { id: "cloud.azure", name: "Azure CLI", category: "cloud" },
  { id: "storage.s3", name: "AWS S3", category: "cloud" },
  { id: "infrastructure.terraform", name: "Terraform", category: "infrastructure" },
  { id: "infrastructure.pulumi", name: "Pulumi", category: "infrastructure" },
  { id: "kubernetes.kubectl", name: "kubectl", category: "infrastructure" },
  { id: "kubernetes.helm", name: "Helm", category: "infrastructure" },
  { id: "containers.docker", name: "Docker", category: "infrastructure" },
  { id: "database.postgresql", name: "PostgreSQL", category: "database" },
  { id: "database.mysql", name: "MySQL/MariaDB", category: "database" },
  { id: "database.redis", name: "Redis", category: "database" },
  { id: "database.supabase", name: "Supabase", category: "database" },
  { id: "payment.stripe", name: "Stripe", category: "payments" },
  { id: "platform.github", name: "GitHub Platform", category: "platform" },
  { id: "cicd.github_actions", name: "GitHub Actions", category: "platform" },
  { id: "remote.ssh", name: "ssh", category: "platform" },
]

export type Rule = { id: string; severity: "critical" | "high"; description: string }
export const RULES: Rule[] = [
  { id: "core.git:reset-hard", severity: "critical", description: "git reset --hard destroys uncommitted changes" },
  { id: "core.git:push-force-long", severity: "critical", description: "git push --force rewrites remote history" },
  { id: "core.git:clean-force", severity: "high", description: "git clean -f deletes untracked files" },
  { id: "core.git:checkout-discard", severity: "high", description: "git checkout -- discards uncommitted changes" },
  { id: "core.git:stash-clear", severity: "high", description: "git stash clear drops every stash" },
  { id: "core.git:branch-force-delete", severity: "high", description: "git branch -D deletes unmerged work" },
  { id: "core.filesystem:rm-rf-general", severity: "high", description: "rm -rf needs human approval" },
  { id: "core.filesystem:rm-rf-root-home", severity: "critical", description: "rm -rf on root or home paths" },
  { id: "core.secrets:home-rv-config", severity: "critical", description: "access to rv's own config directory" },
  { id: "system.disk:dd-device", severity: "critical", description: "dd writing to a block device" },
  { id: "infrastructure.terraform:destroy", severity: "critical", description: "terraform destroy removes managed infrastructure" },
  { id: "infrastructure.terraform:apply-auto-approve", severity: "high", description: "terraform apply -auto-approve skips review" },
  { id: "cloud.aws:s3-rm-recursive", severity: "critical", description: "aws s3 rm --recursive deletes every object" },
  { id: "database.postgresql:drop-table", severity: "high", description: "DROP TABLE permanently deletes the table" },
  { id: "database.postgresql:delete-without-where", severity: "high", description: "DELETE without WHERE deletes all rows" },
]
// Relative frequency of each rule in generated events.
const RULE_WEIGHTS = [16, 7, 9, 8, 3, 5, 14, 1, 4, 0.5, 2, 4, 1, 3, 2]

export const SECRET_SOURCES = [
  "keychain", "hostEnvironment", "onePassword", "vault", "awsSecretsManager",
  "infisical", "bitwarden", "gcp", "azure", "awsProfile", "oauth",
] as const

// ---------------------------------------------------------------------------
// Machines (one rv.report.v1 each)

export type ManagedStatus = "verified" | "absent" | "invalid"

export type Machine = {
  id: string
  name: string
  user: string
  team: Team
  platform: Platform
  rvVersion: string
  managed: { status: ManagedStatus; serial: number | null }
  hosts: Partial<Record<AgentHost, HostMode>>
  packs: string[]
  audit: { chainIntact: boolean | null; chainHead: string; total7d: number; lastEventAt: string }
  mcp: { servers: number; failing: number; plaintextCredentials: number }
  sandbox: { mcpSandbox: boolean; peerTrustInstalled: boolean }
  lastSeen: number
  enrolledAt: number
  compliant: boolean
  drift: string[]
}

const FIRST = ["ana", "ben", "chen", "dara", "eli", "fatima", "gus", "hana", "ivan", "jo", "kai", "lena",
  "mo", "nia", "omar", "pia", "quinn", "ravi", "sam", "tara", "uma", "vik", "wes", "xia", "yusuf", "zoe"]

export const CURRENT_SERIAL = 14

function makeMachine(i: number): Machine {
  const first = FIRST[i % FIRST.length] + (i >= FIRST.length ? String(Math.floor(i / FIRST.length) + 1) : "")
  const platform: Platform = rand() < 0.72 ? "macos-arm64" : rand() < 0.7 ? "linux-x86_64" : "linux-aarch64"
  const team = TEAMS[i % TEAMS.length]
  const kind = platform === "macos-arm64" ? "mbp" : "dev"
  const hostCount = 1 + Math.floor(rand() * 3)
  const hosts: Partial<Record<AgentHost, HostMode>> = {}
  const pool = [...AGENT_HOSTS]
  for (let h = 0; h < hostCount; h++) {
    const host = pool.splice(Math.floor(rand() * pool.length), 1)[0]
    const r = rand()
    hosts[host] = team === "Data" || team === "Mobile"
      ? r < 0.75 ? "observe" : "block"
      : r < 0.84 ? "block" : r < 0.95 ? "observe" : "off"
  }
  const managedRoll = rand()
  const managed: Machine["managed"] = managedRoll < 0.86
    ? { status: "verified", serial: rand() < 0.85 ? CURRENT_SERIAL : CURRENT_SERIAL - 1 }
    : managedRoll < 0.96 ? { status: "absent", serial: null } : { status: "invalid", serial: null }
  const packs = ["core.filesystem", "core.git", "system.disk"]
  if (managed.status === "verified") packs.push("infrastructure.terraform", "cloud.aws")
  if (team === "Payments") packs.push("payment.stripe", "database.postgresql")
  if (team === "Platform") packs.push("kubernetes.kubectl", "containers.docker")
  if (team === "Data") packs.push("database.postgresql", "storage.s3")
  const chainIntact = rand() < 0.04 ? false : rand() < 0.02 ? null : true
  const offline = rand() < 0.07
  const lastSeen = offline ? NOW - (26 + Math.floor(rand() * 90)) * HOUR : NOW - Math.floor(rand() * 55) * 60_000
  const rvVersion = pick(VERSIONS)
  const servers = Math.floor(rand() * 6)
  const mcp = {
    servers,
    failing: servers > 0 && rand() < 0.1 ? 1 : 0,
    plaintextCredentials: servers > 0 && rand() < 0.08 ? 1 : 0,
  }

  // Reasons that break the report's `compliant` flag come first.
  const drift: string[] = []
  if (managed.status === "invalid") drift.push("Org policy signature does not verify")
  if (chainIntact === false) drift.push("Audit chain broken")
  if (mcp.failing) drift.push("An MCP server is failing")
  for (const [host, mode] of Object.entries(hosts)) {
    if (mode === "off") drift.push(`${HOST_LABEL[host as AgentHost]} guard is off`)
  }
  if (managed.status === "absent") drift.push("No org policy installed")
  if (managed.serial !== null && managed.serial < CURRENT_SERIAL) drift.push(`Policy serial ${managed.serial}, current is ${CURRENT_SERIAL}`)
  if (rvVersion !== LATEST_VERSION && rvVersion === "0.2.0") drift.push(`rv ${rvVersion} is two releases behind`)
  if (offline) drift.push("No report in over 24 hours")
  if (mcp.plaintextCredentials) drift.push("Plaintext credential in an MCP config")

  // Mirrors ReportRun.Report.compliant: managed not invalid, MCP ok, no
  // secret policy violation, audit chain not broken.
  const compliant = managed.status !== "invalid" && mcp.failing === 0 && chainIntact !== false

  return {
    id: `m_${hex(10)}`,
    name: `${kind}-${first}`,
    user: first,
    team,
    platform,
    rvVersion,
    managed,
    hosts,
    packs,
    audit: {
      chainIntact,
      chainHead: hex(64),
      total7d: 0,
      lastEventAt: new Date(lastSeen - Math.floor(rand() * 40) * 60_000).toISOString(),
    },
    mcp,
    sandbox: { mcpSandbox: platform === "macos-arm64" || rand() < 0.5, peerTrustInstalled: rand() < 0.3 },
    lastSeen,
    enrolledAt: NOW - (5 + Math.floor(rand() * 40)) * DAY,
    compliant,
    drift,
  }
}

export const MACHINES: Machine[] = Array.from({ length: 48 }, (_, i) => makeMachine(i))

// ---------------------------------------------------------------------------
// Audit events (rv.audit.v1, as forwarded)

export type EventKind =
  | "command.denied"
  | "command.observed"
  | "command.override"
  | "secret.misuse"
  | "config.changed"
  | "policy.managed"

export type AuditEvent = {
  id: string
  machineId: string
  kind: EventKind
  decision: "denied" | "info" | "allowed"
  subject: string
  host: AgentHost
  tool: "Bash" | "Read" | "Edit" | "Write" | "shell"
  recordedAt: number
  wouldBe?: "deny" | "ask"
  override?: "allow-once" | "allowlist" | "rebase recovery" | "contained delete"
  detail?: string
}

function weightedRule(): Rule {
  const total = RULE_WEIGHTS.reduce((a, b) => a + b, 0)
  let r = rand() * total
  for (let i = 0; i < RULES.length; i++) {
    r -= RULE_WEIGHTS[i]
    if (r <= 0) return RULES[i]
  }
  return RULES[0]
}

function makeEvents(): AuditEvent[] {
  const out: AuditEvent[] = []
  for (const m of MACHINES) {
    const entries = Object.entries(m.hosts) as [AgentHost, HostMode][]
    const active = entries.filter(([, mode]) => mode !== "off")
    if (active.length === 0) continue
    const perDay = 0.6 + rand() * 3.2
    for (let d = 0; d < 14; d++) {
      const weekday = new Date(NOW - d * DAY).getUTCDay()
      const scale = weekday === 0 || weekday === 6 ? 0.25 : 1
      const n = Math.round(perDay * scale * (0.5 + rand()))
      for (let k = 0; k < n; k++) {
        const [host, mode] = pick(active)
        const rule = weightedRule()
        const t = NOW - d * DAY - Math.floor(rand() * DAY)
        if (t > m.lastSeen) continue
        const tool = rule.id.startsWith("core.secrets") ? pick(["Read", "Edit"] as const) : host === "codex" ? "shell" : "Bash"
        if (mode === "observe") {
          out.push({ id: `ev_${hex(12)}`, machineId: m.id, kind: "command.observed", decision: "info", subject: rule.id, host, tool, recordedAt: t, wouldBe: rand() < 0.82 ? "deny" : "ask" })
        } else {
          out.push({ id: `ev_${hex(12)}`, machineId: m.id, kind: "command.denied", decision: "denied", subject: rule.id, host, tool, recordedAt: t })
          if (rand() < 0.07) {
            out.push({ id: `ev_${hex(12)}`, machineId: m.id, kind: "command.override", decision: "allowed", subject: rule.id, host, tool, recordedAt: t + 90_000, override: rand() < 0.7 ? "allow-once" : pick(["allowlist", "rebase recovery", "contained delete"] as const) })
          }
        }
      }
    }
    if (rand() < 0.08) {
      out.push({ id: `ev_${hex(12)}`, machineId: m.id, kind: "secret.misuse", decision: "denied", subject: "STRIPE_SECRET_KEY", host: active[0][0], tool: "shell", recordedAt: NOW - Math.floor(rand() * 6 * DAY), detail: "request came from a process outside the lease" })
    }
    if (rand() < 0.15) {
      out.push({ id: `ev_${hex(12)}`, machineId: m.id, kind: "config.changed", decision: "info", subject: "guard.hosts", host: active[0][0], tool: "shell", recordedAt: NOW - Math.floor(rand() * 10 * DAY), detail: "host mode changed (loosening, authorized_by: owner)" })
    }
  }
  return out.sort((a, b) => b.recordedAt - a.recordedAt)
}

export const EVENTS: AuditEvent[] = makeEvents()
for (const m of MACHINES) {
  m.audit.total7d = EVENTS.filter((e) => e.machineId === m.id && e.recordedAt > NOW - 7 * DAY).length
}

export const machineById = (id: string) => MACHINES.find((m) => m.id === id)

// ---------------------------------------------------------------------------
// Derived views

export function dailySeries(days = 14) {
  const rows: { date: string; denied: number; observed: number }[] = []
  for (let d = days - 1; d >= 0; d--) {
    const start = NOW - (d + 1) * DAY
    const end = NOW - d * DAY
    const inDay = EVENTS.filter((e) => e.recordedAt > start && e.recordedAt <= end)
    rows.push({
      date: new Date(end).toISOString().slice(0, 10),
      denied: inDay.filter((e) => e.kind === "command.denied").length,
      observed: inDay.filter((e) => e.kind === "command.observed").length,
    })
  }
  return rows
}

export function topRules(kind: EventKind = "command.denied", since = 7 * DAY) {
  const counts = new Map<string, { count: number; machines: Set<string>; hosts: Set<AgentHost> }>()
  for (const e of EVENTS) {
    if (e.kind !== kind || e.recordedAt < NOW - since) continue
    const c = counts.get(e.subject) ?? { count: 0, machines: new Set(), hosts: new Set() }
    c.count++
    c.machines.add(e.machineId)
    c.hosts.add(e.host)
    counts.set(e.subject, c)
  }
  return [...counts.entries()]
    .map(([id, c]) => ({ rule: RULES.find((r) => r.id === id)!, count: c.count, machines: c.machines.size, hosts: [...c.hosts] }))
    .filter((r) => r.rule)
    .sort((a, b) => b.count - a.count)
}

export function overrideCounts(since = 7 * DAY) {
  const m = new Map<string, number>()
  for (const e of EVENTS) {
    if (e.kind === "command.override" && e.recordedAt >= NOW - since) m.set(e.subject, (m.get(e.subject) ?? 0) + 1)
  }
  return m
}

export function rolloutByHost() {
  return AGENT_HOSTS.map((host) => {
    const observing = MACHINES.filter((m) => m.hosts[host] === "observe")
    const enforcing = MACHINES.filter((m) => m.hosts[host] === "block")
    const off = MACHINES.filter((m) => m.hosts[host] === "off")
    const obs = EVENTS.filter((e) => e.kind === "command.observed" && e.host === host)
    const wouldDeny = obs.filter((e) => e.wouldBe === "deny").length
    const wouldAsk = obs.filter((e) => e.wouldBe === "ask").length
    // would-be blocks per observing machine per day over 14 days
    const rate = observing.length ? Math.round(((wouldDeny + wouldAsk) / observing.length / 14) * 10) / 10 : 0
    const ruleCounts = new Map<string, number>()
    for (const e of obs) ruleCounts.set(e.subject, (ruleCounts.get(e.subject) ?? 0) + 1)
    const top = [...ruleCounts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3)
    const readiness: "ready" | "review" | "not-ready" | "n/a" =
      observing.length === 0 ? "n/a" : rate <= 0.7 ? "ready" : rate <= 1.0 ? "review" : "not-ready"
    return { host, observing, enforcing, off, wouldDeny, wouldAsk, rate, top, readiness }
  })
}

export type PolicyRevision = {
  serial: number
  author: string
  uploadedAt: number
  summary: string
  signer: string
  machines: number
}

export const POLICY_REVISIONS: PolicyRevision[] = [
  { serial: 14, author: "ravi", uploadedAt: NOW - 3 * DAY, summary: "Require cloud.aws and infrastructure.terraform", signer: "ed25519:7f3a…c21e", machines: MACHINES.filter((m) => m.managed.serial === 14).length },
  { serial: 13, author: "ravi", uploadedAt: NOW - 12 * DAY, summary: "Block MCP server globs filesystem-*", signer: "ed25519:7f3a…c21e", machines: MACHINES.filter((m) => m.managed.serial === 13).length },
  { serial: 12, author: "tara", uploadedAt: NOW - 26 * DAY, summary: "Allowed secret sources: keychain, onePassword, vault", signer: "ed25519:7f3a…c21e", machines: 0 },
  { serial: 11, author: "tara", uploadedAt: NOW - 41 * DAY, summary: "Forward audit to rv Cloud", signer: "ed25519:7f3a…c21e", machines: 0 },
]

export const SIEM_TARGETS = [
  { name: "Splunk HEC", url: "https://splunk.internal.example:8088/services/collector", format: "OCSF 1.3.0", status: "healthy" as const, lastDelivery: NOW - 4 * 60_000 },
  { name: "Archive bucket", url: "s3://rv-audit-archive/", format: "JSONL", status: "degraded" as const, lastDelivery: NOW - 3 * HOUR },
]

// ---------------------------------------------------------------------------
// Formatting

export function timeAgo(t: number) {
  const s = Math.max(0, Math.round((NOW - t) / 1000))
  if (s < 60) return `${s}s ago`
  const m = Math.round(s / 60)
  if (m < 60) return `${m}m ago`
  const h = Math.round(m / 60)
  if (h < 48) return `${h}h ago`
  return `${Math.round(h / 24)}d ago`
}

export function fmtTime(t: number) {
  const d = new Date(t)
  const mon = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.getUTCMonth()]
  return `${mon} ${d.getUTCDate()}, ${String(d.getUTCHours()).padStart(2, "0")}:${String(d.getUTCMinutes()).padStart(2, "0")} UTC`
}

export const isOnline = (m: Machine) => NOW - m.lastSeen < 24 * HOUR
export { DAY, HOUR }
