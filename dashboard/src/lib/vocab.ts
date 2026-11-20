// Fixed vocabulary shared by server and client code. Values match rv's own
// identifiers (RVDomain/HookHost.swift, RVPolicy/ManagedPolicy.swift).

export const AGENT_HOSTS = [
  "claude",
  "codex",
  "cursor",
  "opencode",
  "grok",
  "pi",
  "hermes",
  "openclaw",
  "antigravity",
  "muse",
] as const
export type AgentHost = (typeof AGENT_HOSTS)[number]

const HOST_LABELS: Record<string, string> = {
  claude: "Claude Code",
  codex: "Codex",
  cursor: "Cursor",
  opencode: "OpenCode",
  grok: "Grok",
  pi: "Pi",
  hermes: "Hermes",
  openclaw: "OpenClaw",
  antigravity: "Antigravity",
  muse: "Muse",
  tty: "Terminal",
}
export const hostLabel = (host: string | null | undefined) => (host ? (HOST_LABELS[host] ?? host) : "Unknown")

export type HostMode = "block" | "observe" | "off"

export const SECRET_SOURCES = [
  "keychain",
  "hostEnvironment",
  "onePassword",
  "vault",
  "awsSecretsManager",
  "infisical",
  "bitwarden",
  "gcp",
  "azure",
  "awsProfile",
  "oauth",
] as const

export const ROLES = ["owner", "admin", "viewer"] as const
export type Role = (typeof ROLES)[number]
export const canAdmin = (role: Role | null | undefined) => role === "owner" || role === "admin"

export const PLATFORM_LABEL: Record<string, string> = {
  macos: "macOS",
  linux: "Linux",
}
export const platformLabel = (p: string | null | undefined) => (p ? (PLATFORM_LABEL[p] ?? p) : "Unknown")
