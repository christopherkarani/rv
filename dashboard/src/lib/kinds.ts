/** Display vocabulary for rv.audit.v1 kinds, decisions and hosts. Client-safe. */
export type Tone = "blocked" | "observed" | "override" | "mcp" | "good" | "warning" | "critical" | "neutral";

export const KIND_LABELS: Record<string, { label: string; tone: Tone; group: string }> = {
  "command.denied": { label: "Blocked command", tone: "blocked", group: "Gate" },
  "command.observed": { label: "Would-be block", tone: "observed", group: "Gate" },
  "command.override": { label: "Override", tone: "override", group: "Gate" },
  "egress.denied": { label: "Egress denied", tone: "blocked", group: "Network" },
  "egress.observed": { label: "Egress observed", tone: "observed", group: "Network" },
  "mcp.call": { label: "MCP call", tone: "mcp", group: "MCP" },
  "mcp.approval": { label: "MCP approval", tone: "mcp", group: "MCP" },
  "mcp.tool.changed": { label: "MCP tool changed", tone: "warning", group: "MCP" },
  "mcp.hosts.ungoverned": { label: "Ungoverned MCP hosts", tone: "warning", group: "MCP" },
  "secret.use": { label: "Secret use", tone: "neutral", group: "Secrets" },
  "secret.misuse": { label: "Secret misuse", tone: "critical", group: "Secrets" },
  "config.changed": { label: "Config changed", tone: "neutral", group: "Policy" },
  "policy.changed": { label: "Policy changed", tone: "neutral", group: "Policy" },
  "policy.managed": { label: "Org policy", tone: "neutral", group: "Policy" },
  "owner.action": { label: "Owner auth", tone: "neutral", group: "Policy" },
  admission: { label: "Admission", tone: "neutral", group: "Runtime" },
  "runtime.session": { label: "Runtime session", tone: "neutral", group: "Runtime" },
  "runtime.started": { label: "Runtime started", tone: "neutral", group: "Runtime" },
  "runtime.ended": { label: "Runtime ended", tone: "neutral", group: "Runtime" },
};

export function kindMeta(kind: string) {
  if (KIND_LABELS[kind]) return KIND_LABELS[kind];
  if (kind.startsWith("workspace.")) return { label: `Workspace ${kind.slice(10)}`, tone: "neutral" as Tone, group: "Runtime" };
  if (kind.startsWith("agent.")) return { label: `Agent ${kind.slice(6)}`, tone: "neutral" as Tone, group: "Runtime" };
  return { label: kind, tone: "neutral" as Tone, group: "Other" };
}

/** Effective tone of one event: a denied MCP call reads as blocked. */
export function eventTone(kind: string, decision: string): Tone {
  if (decision === "denied") return kind === "secret.misuse" ? "critical" : "blocked";
  if (decision === "pending") return "warning";
  if (decision === "failed") return "critical";
  return kindMeta(kind).tone;
}

/** Color tokens per tone; text always stays in ink colors, color goes on marks. */
export const TONE_VAR: Record<Tone, string> = {
  blocked: "var(--series-blocked)",
  observed: "var(--series-observed)",
  override: "var(--series-override)",
  mcp: "var(--series-mcp)",
  good: "var(--status-good)",
  warning: "var(--status-warning)",
  critical: "var(--status-critical)",
  neutral: "color-mix(in oklab, var(--foreground) 35%, transparent)",
};

export const DECISION_LABEL: Record<string, string> = {
  allowed: "allowed", denied: "denied", pending: "pending", failed: "failed", info: "info",
};

const HOST_LABELS: Record<string, string> = {
  claude: "Claude Code", codex: "Codex", cursor: "Cursor", grok: "Grok", opencode: "OpenCode", pi: "Pi",
  hermes: "Hermes", openclaw: "OpenClaw", antigravity: "Antigravity", muse: "Muse", terminal: "Terminal", tty: "Terminal",
};

export const hostLabel = (host: string | null | undefined) => (host ? HOST_LABELS[host] ?? host : "—");

export const SEVERITY_ORDER: Record<string, number> = { critical: 4, high: 3, medium: 2, low: 1 };
