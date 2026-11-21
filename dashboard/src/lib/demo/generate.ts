/**
 * Synthetic fleet for demos and screenshots. Emits exactly what rv sends:
 * OCSF batches (`rv audit forward` default), a few `--format rv` batches, and
 * `rv.report.v1` documents. No imports beyond node builtins, so
 * `node scripts/seed.ts` can load it without a bundler.
 */
import { createHash } from "node:crypto";

type Detail = Record<string, string>;

export interface DemoEvent {
  time: number;
  kind: string;
  decision: "allowed" | "denied" | "pending" | "failed" | "info";
  subject: string;
  reason?: string;
  agent?: string;
  workspace?: string;
  source: string;
  detail: Detail;
  prev?: string;
  chainHead?: string;
}

export interface DemoDevice {
  hostname: string;
  user: string;
  platform: "macos" | "linux";
  version: string;
  hosts: string[];
  activity: number;
  format: "ocsf" | "rv";
  managed: "active" | "none" | "invalid";
  serial: number;
  mcpOk: boolean;
  secretViolation: boolean;
  tamper: boolean;
  behind: boolean;
}

// Deterministic PRNG so every seed of the demo looks the same.
function mulberry32(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const RULES: [string, number, string, string][] = [
  // rule, weight, tool, category
  ["core.git:reset-hard", 18, "Bash", ""],
  ["core.git:push-force-long", 12, "Bash", ""],
  ["core.git:clean-force", 9, "Bash", ""],
  ["core.git:checkout-discard", 7, "Bash", ""],
  ["core.git:stash-clear", 3, "Bash", ""],
  ["core.filesystem:rm-rf-root-home", 5, "Bash", ""],
  ["core.filesystem:rm-rf-general", 14, "Bash", ""],
  ["core.secrets:env", 16, "Read", "environment"],
  ["core.secrets:id-ed25519", 4, "Read", "ssh"],
  ["core.secrets:home-aws", 5, "Bash", "cloud"],
  ["core.secrets:home-rv-config", 2, "Edit", "host"],
  ["system.disk:dd-device", 1, "Bash", ""],
  ["database.postgresql:drop-database", 3, "Bash", ""],
  ["kubernetes.kubectl:delete-namespace", 3, "Bash", ""],
  ["infrastructure.terraform:destroy", 4, "Bash", ""],
  ["cloud.aws:s3-rm-recursive", 3, "Bash", ""],
  ["core.judge:laya-block", 4, "Bash", ""],
  ["core.judge:laya-review", 3, "Bash", ""],
  ["core.mcp:mcp-host-config", 2, "Edit", ""],
];

const MCP_TOOLS: [string, string, number, "allow" | "ask" | "deny", number][] = [
  // server, tool, weight, policy, typical ms
  ["github", "search_code", 22, "allow", 420],
  ["github", "create_pull_request", 8, "ask", 900],
  ["github", "merge_pull_request", 2, "deny", 0],
  ["linear", "create_issue", 9, "allow", 350],
  ["linear", "list_issues", 14, "allow", 210],
  ["postgres", "query", 12, "allow", 160],
  ["postgres", "execute", 3, "ask", 240],
  ["slack", "post_message", 5, "ask", 300],
  ["sentry", "get_issue", 7, "allow", 520],
  ["filesystem", "write_file", 6, "allow", 30],
  ["stripe", "create_refund", 1, "deny", 0],
];

const SECRETS = ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GITHUB_TOKEN", "STRIPE_SECRET_KEY", "AWS_PROD_DEPLOY", "SENTRY_AUTH_TOKEN"];
const MISUSE = ["foreignPlaceholder", "surfaceNotAllowed", "outsideAllowRules", "encodedPlaceholder"];
const HOSTS = ["claude", "codex", "cursor", "opencode", "grok", "antigravity"];
const PATHS = ["~/src/payments-api", "~/src/web-app", "~/src/infra", "~/src/ml-pipeline", "~/src/mobile", "~/src/platform"];

export function demoDevices(): DemoDevice[] {
  const rand = mulberry32(7);
  const pick = <T,>(xs: T[]) => xs[Math.floor(rand() * xs.length)];
  const names = [
    "eng-mbp-0142", "eng-mbp-0157", "eng-mbp-0163", "eng-mbp-0171", "eng-mbp-0188", "eng-mbp-0193",
    "eng-mbp-0204", "eng-mbp-0219", "eng-mbp-0226", "eng-mbp-0231", "eng-mbp-0247", "eng-mbp-0252",
    "ds-ws-03", "ds-ws-07", "ml-gpu-11", "platform-dev-02", "sre-mbp-0019", "sre-mbp-0023",
    "ci-runner-01", "ci-runner-02", "ci-runner-03", "contractor-mbp-881",
  ];
  return names.map((hostname, i) => {
    const linux = hostname.startsWith("ci-") || hostname.startsWith("ml-") || hostname.startsWith("ds-");
    const hosts = hostname.startsWith("ci-") ? ["codex"] : [pick(HOSTS.slice(0, 3)), pick(HOSTS)].filter((h, j, a) => a.indexOf(h) === j);
    return {
      hostname,
      user: linux ? "build" : `dev${100 + i}`,
      platform: linux ? "linux" : "macos",
      version: i % 7 === 3 ? "0.11.2" : i % 5 === 1 ? "0.12.0" : "0.12.1",
      hosts,
      activity: hostname.startsWith("ci-") ? 1.6 : 0.4 + rand() * 1.4,
      format: i % 6 === 5 ? "rv" : "ocsf",
      managed: hostname === "contractor-mbp-881" ? "none" : i === 9 ? "invalid" : "active",
      serial: i % 8 === 2 ? 41 : 42,
      mcpOk: !(i === 4 || i === 15),
      secretViolation: i === 11,
      tamper: hostname === "eng-mbp-0226",
      behind: hostname === "sre-mbp-0023",
    };
  });
}

function weighted<T>(rand: () => number, items: T[], weight: (t: T) => number): T {
  const total = items.reduce((s, t) => s + weight(t), 0);
  let r = rand() * total;
  for (const item of items) {
    r -= weight(item);
    if (r <= 0) return item;
  }
  return items[items.length - 1];
}

/** Activity curve: working hours weigh most, weekends little. */
function diurnal(t: number) {
  const d = new Date(t);
  const hour = d.getUTCHours();
  const weekend = d.getUTCDay() === 0 || d.getUTCDay() === 6;
  const day = hour >= 13 && hour <= 23 ? 1 : hour >= 9 && hour < 13 ? 0.45 : 0.12;
  return day * (weekend ? 0.25 : 1);
}

export function randomEvent(rand: () => number, device: DemoDevice, time: number): DemoEvent {
  const pick = <T,>(xs: T[]) => xs[Math.floor(rand() * xs.length)];
  const host = pick(device.hosts);
  const session = `${host}-${Math.floor(rand() * 1e8).toString(16)}`;
  const path = pick(PATHS);
  const roll = rand();
  if (roll < 0.32) {
    const [rule, , tool, category] = weighted(rand, RULES, (r) => r[1]);
    const observed = device.hostname.startsWith("eng-mbp-02") && rand() < 0.5;
    const detail: Detail = { host, tool, path, session };
    if (category) detail.category = category;
    if (observed) detail.would_be = rand() < 0.8 ? "deny" : "ask";
    return {
      time, kind: observed ? "command.observed" : "command.denied", decision: observed ? "info" : "denied",
      subject: rule, agent: host, source: "audit.jsonl", detail,
    };
  }
  if (roll < 0.36) {
    const [rule] = weighted(rand, RULES.slice(0, 7), (r) => r[1]);
    const override = pick(["allow-once", "allow-once", "allowlist", "rebase recovery", "contained delete"]);
    return { time, kind: "command.override", decision: "allowed", subject: rule, reason: override, agent: host, source: "audit.jsonl", detail: { host, override } };
  }
  if (roll < 0.375) {
    const r = rand();
    if (r < 0.35) return { time, kind: "mcp.tool.changed", decision: "info", subject: pick(["github/create_pull_request", "linear/create_issue", "postgres/execute"]), reason: "definition changed since rv mcp trust; calls ask", agent: host, source: "mcp-gateway", detail: { server: "github", fields: "description,inputSchema" } };
    if (r < 0.45) return { time, kind: "mcp.approval", decision: "denied", subject: "github/merge_pull_request", reason: "forged grant rejected", agent: host, source: "mcp-gateway", detail: { server: "github" } };
    if (r < 0.55) return { time, kind: "mcp.hosts.ungoverned", decision: "info", subject: "cursor", reason: "host configs run servers around the gateway", source: "mcp-gateway", detail: { bypassing: "1", unreviewed: "2" } };
    return { time, kind: "mcp.approval", decision: "allowed", subject: pick(["slack/post_message", "postgres/execute", "github/create_pull_request"]), reason: "approved", agent: host, source: "mcp-gateway", detail: { approvedVia: "RVApprovals" } };
  }
  if (roll < 0.78) {
    const [server, tool, , policy, ms] = weighted(rand, MCP_TOOLS, (t) => t[2]);
    const keys = pick(["query", "repo,query", "title,body,team", "sql", "path,content", "issue_id", "channel,text"]);
    if (policy === "deny") {
      return { time, kind: "mcp.call", decision: "denied", subject: `${server}/${tool}`, reason: `rv policy denies ${server}/${tool}`, agent: host, source: "mcp-gateway", detail: { server, tool, policy, argumentKeys: keys, isError: "true" } };
    }
    if (policy === "ask" && rand() < 0.22) {
      return { time, kind: "mcp.call", decision: "denied", subject: `${server}/${tool}`, reason: "declined by the user", agent: host, source: "mcp-gateway", detail: { server, tool, policy, argumentKeys: keys, isError: "true" } };
    }
    const duration = Math.max(8, Math.round(ms * (0.4 + rand() * 1.6) * (rand() < 0.04 ? 8 : 1)));
    const detail: Detail = { server, tool, policy, argumentKeys: keys, isError: rand() < 0.03 ? "true" : "false", durationMs: String(duration) };
    if (policy === "ask") { detail.approval = `apr_${Math.floor(rand() * 1e9).toString(36)}`; detail.approvedVia = "RVApprovals"; }
    return { time, kind: "mcp.call", decision: "allowed", subject: `${server}/${tool}`, agent: host, source: "mcp-gateway", detail };
  }
  if (roll < 0.93) {
    const name = pick(SECRETS);
    const fingerprint = createHash("sha256").update(name).digest("hex").slice(0, 16);
    if (rand() < 0.035) {
      return { time, kind: "secret.misuse", decision: "denied", subject: name, reason: "placeholder used against its policy", source: "secret-gateway", detail: { refusal: pick(MISUSE), fingerprint, host } };
    }
    return { time, kind: "secret.use", decision: "info", subject: name, reason: pick(["staged for launch", "request forwarded"]), source: "secret-gateway", detail: { fingerprint, delivery: pick(["gateway", "environment"]) } };
  }
  if (roll < 0.965) {
    const target = pick(["registry.npmjs.org:443", "api.openai.com:443", "pastebin.com:443", "169.254.169.254:80", "github.com:443", "transfer.sh:443"]);
    const bad = /pastebin|169\.254|transfer/.test(target);
    return bad
      ? { time, kind: "egress.denied", decision: "denied", subject: target, reason: target.startsWith("169") ? "address-filtered" : "denied-policy", source: "egress.jsonl", workspace: path, detail: { host } }
      : { time, kind: "runtime.started", decision: "info", subject: `rt_${Math.floor(rand() * 1e6)}`, workspace: path, source: "runtime.jsonl", detail: { backend: device.platform === "macos" ? "seatbelt" : "landlock" } };
  }
  if (roll < 0.985) {
    const passed = rand() < 0.9;
    return { time, kind: "owner.action", decision: passed ? "allowed" : "denied", subject: pick(["allow-once", "packs enable", "allowlist add", "safety normal"]), reason: passed ? "Touch ID" : "authentication failed", source: "audit.jsonl", detail: { method: device.platform === "macos" ? "touchid" : "password" } };
  }
  const setting = pick(["packs", "allowlist", "safety", "host mode", "guard.mode", "secrets"]);
  const loosening = rand() < 0.45;
  return {
    time, kind: "config.changed", decision: "info", subject: setting, source: "audit.jsonl",
    detail: {
      setting, direction: loosening ? "loosening" : "tightening",
      authorized_by: loosening && rand() < 0.25 ? "none" : device.platform === "macos" ? "touchid" : "password",
      ...({
        safety: loosening ? { prior: "strict", new: "normal" } : { prior: "normal", new: "strict" },
        packs: loosening ? { prior: "5 enabled", new: "4 enabled" } : { prior: "3 enabled", new: "5 enabled" },
        allowlist: loosening ? { prior: "12 entries", new: "13 entries" } : { prior: "13 entries", new: "12 entries" },
        "host mode": loosening ? { prior: `${host}: block`, new: `${host}: observe` } : { prior: `${host}: observe`, new: `${host}: block` },
        "guard.mode": loosening ? { prior: "enforce", new: "observe" } : { prior: "observe", new: "enforce" },
        secrets: loosening ? { prior: "4 definitions", new: "5 definitions" } : { prior: "5 definitions", new: "4 definitions" },
      } as Record<string, { prior: string; new: string }>)[setting],
    },
  };
}

const sha = (s: string) => createHash("sha256").update(s).digest("hex");

/** Adds rv's hash chain to `audit.jsonl` events, in order. */
export function chain(events: DemoEvent[], startHead: string | null, tamperAt?: number): { events: DemoEvent[]; head: string | null } {
  let head = startHead;
  let index = 0;
  for (const event of events) {
    if (event.source !== "audit.jsonl") continue;
    const prev = head ?? "0".repeat(64);
    // A tampered line: someone edited the line before this one, so its
    // recorded prev no longer matches what was forwarded.
    event.prev = tamperAt !== undefined && index === tamperAt ? sha(`edited-${prev}`) : prev;
    event.chainHead = sha(`${event.prev}|${event.time}|${event.kind}|${event.subject}`);
    head = event.chainHead;
    index++;
  }
  return { events, head };
}

export function toOCSF(event: DemoEvent, hostName: string): Record<string, unknown> {
  const disposition = { allowed: [1, "Allowed"], denied: [2, "Blocked"], pending: [14, "Delayed"], failed: [27, "Error"], info: [17, "Logged"] }[event.decision];
  const unmapped: Record<string, unknown> = { rv_kind: event.kind, rv_subject: event.subject };
  if (event.reason) unmapped.rv_reason = event.reason;
  if (event.workspace) unmapped.rv_workspace = event.workspace;
  if (Object.keys(event.detail).length) unmapped.rv_detail = event.detail;
  if (event.prev) unmapped.rv_prev = event.prev;
  if (event.chainHead) unmapped.rv_chain_head = event.chainHead;
  const object: Record<string, unknown> = {
    class_uid: event.kind.startsWith("command") ? 1007 : event.kind.startsWith("mcp") || event.kind === "secret.use" ? 6003 : 6002,
    time: event.time,
    severity_id: event.kind === "secret.misuse" ? 4 : event.decision === "denied" ? 3 : 1,
    disposition_id: disposition[0],
    disposition: disposition[1],
    metadata: { version: "1.3.0", uid: sha(`${hostName}|${event.time}|${event.kind}|${event.subject}|${JSON.stringify(event.detail)}`).slice(0, 32), log_name: event.source, product: { name: "rv", vendor_name: "rv" } },
    device: { hostname: hostName, type_id: 0 },
    unmapped,
  };
  if (event.agent) object.actor = { app_name: event.agent };
  return object;
}

export function toRV(event: DemoEvent): Record<string, unknown> {
  const out: Record<string, unknown> = {
    schema: "rv.audit.v1", time: new Date(event.time).toISOString(), kind: event.kind, decision: event.decision,
    subject: event.subject, source: event.source, detail: event.detail,
  };
  if (event.reason) out.reason = event.reason;
  if (event.agent) out.agent = event.agent;
  if (event.workspace) out.workspace = event.workspace;
  if (event.prev) out.prev = event.prev;
  if (event.chainHead) out.chainHead = event.chainHead;
  return out;
}

export function demoReport(device: DemoDevice, now: number, chainHead: string | null) {
  const iso = (t: number) => new Date(t).toISOString().replace(/\.\d{3}Z$/, "Z");
  return {
    schema: "rv.report.v1",
    generatedAt: iso(now),
    rv: { version: device.version, platform: device.platform },
    host: { name: device.hostname, user: device.user, uid: 501 },
    managed: device.managed === "active"
      ? { state: "active", directory: "/Library/Managed Preferences/rv", organization: "Northwind Labs", serial: device.serial, sha256: sha(`policy-${device.serial}`), signed: true, signingKey: 1, highestSerial: device.serial, restrictions: ["gate.requirePacks", "mcp.blocked", "audit.forward"] }
      : device.managed === "invalid"
        ? { state: "invalid", directory: "/Library/Managed Preferences/rv", reason: "signature does not verify against the pinned organization key" }
        : { state: "none", directory: "/Library/Managed Preferences/rv" },
    config: [
      { file: "mcp.json", present: true, sha256: sha(`mcp-${device.hostname}`) },
      { file: "secrets.json", present: true, sha256: sha(`secrets-${device.hostname}`) },
      { file: "policy.toml", present: true, sha256: sha("policy") },
    ],
    mcp: device.mcpOk
      ? { ok: true, servers: 6, counts: { gateway: 6 }, failing: [], plaintextCredentials: 0 }
      : { ok: false, error: null, servers: 5, counts: { gateway: 5, direct: 1 }, failing: [{ host: "cursor", name: "postgres-prod", status: "direct", config: "~/.cursor/mcp.json" }], plaintextCredentials: 1 },
    secrets: {
      error: null,
      items: SECRETS.slice(0, 4).map((name, i) => ({
        name, source: i === 0 ? "keychain" : i === 2 ? "onePassword" : "vault", delivery: "gateway",
        policyViolation: device.secretViolation && i === 1 ? "source hostEnvironment is not in secrets.allowedSources" : null,
      })),
    },
    audit: {
      since: iso(now - 86_400_000), total: 0, byKind: {}, lastEventAt: iso(now),
      chainIntact: true,
      chainHead: device.behind ? sha(`unforwarded-${device.hostname}`) : chainHead,
    },
    sandbox: { platform: device.platform, mcpSandbox: true, peerTrustInstalled: device.platform === "macos" },
  };
}

export interface DemoFleet {
  batches: { device: DemoDevice; format: "ocsf" | "rv"; body: Record<string, unknown>[] }[];
  reports: ReturnType<typeof demoReport>[];
  heads: Map<string, string | null>;
}

/** History for every demo device over `days`, ending at `now`. */
export function demoFleet(now: number, days = 30): DemoFleet {
  const rand = mulberry32(42);
  const batches: DemoFleet["batches"] = [];
  const reports: DemoFleet["reports"] = [];
  const heads = new Map<string, string | null>();
  const start = now - days * 86_400_000;
  for (const device of demoDevices()) {
    const events: DemoEvent[] = [];
    // Poisson-ish arrivals: step through the window in 10-minute slots.
    for (let t = start; t < now; t += 600_000) {
      const expected = 0.9 * device.activity * diurnal(t);
      let n = 0;
      while (rand() < expected / (n + 1) && n < 6) n++;
      for (let i = 0; i < n; i++) events.push(randomEvent(rand, device, t + Math.floor(rand() * 600_000)));
    }
    // A config loosening the morning a contractor's machine came online.
    events.sort((a, b) => a.time - b.time);
    const auditCount = events.filter((e) => e.source === "audit.jsonl").length;
    const { head } = chain(events, null, device.tamper ? Math.floor(auditCount * 0.7) : undefined);
    heads.set(device.hostname, head);
    for (let i = 0; i < events.length; i += 500) {
      const slice = events.slice(i, i + 500);
      batches.push({
        device, format: device.format,
        body: device.format === "rv" ? slice.map(toRV) : slice.map((e) => toOCSF(e, device.hostname)),
      });
    }
    // CI runners do not run the MDM report script.
    if (!device.hostname.startsWith("ci-")) reports.push(demoReport(device, now - Math.floor(rand() * 3_600_000), head));
  }
  return { batches, reports, heads };
}

export { mulberry32 };
