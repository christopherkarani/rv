import "server-only";
import { createHmac, randomBytes } from "node:crypto";
import { config } from "./config";
import { db, logConsoleAction } from "./db";
import { newId } from "./crypto";
import { open, seal } from "./secretbox";
import type { IngestOutcome, StoredReport } from "./store";
import { RULES, ruleDef, SEVERITY_RANK, type RuleId, type Severity } from "../alerts/catalog";
import { destinationProblem, slackPayload, urlHint, webhookPayload, type Alert } from "../alerts/format";

// --- destinations -------------------------------------------------------------

export interface Destination {
  id: string;
  name: string;
  kind: "slack" | "webhook";
  urlHint: string;
  minSeverity: Severity;
  enabled: boolean;
  hasSecret: boolean;
  createdAt: number;
  createdBy: string | null;
  lastStatus: string | null;
  lastDeliveryAt: number | null;
}

interface DestinationRow {
  id: string; name: string; kind: "slack" | "webhook"; url_enc: string; url_hint: string; secret_enc: string | null;
  min_severity: Severity; enabled: number; created_at: number; created_by: string | null;
  last_status: string | null; last_delivery_at: number | null;
}

const toDestination = (r: DestinationRow): Destination => ({
  id: r.id, name: r.name, kind: r.kind, urlHint: r.url_hint, minSeverity: r.min_severity, enabled: r.enabled === 1,
  hasSecret: !!r.secret_enc, createdAt: r.created_at, createdBy: r.created_by, lastStatus: r.last_status, lastDeliveryAt: r.last_delivery_at,
});

const allowHttp = () => process.env.RV_CONSOLE_ALLOW_HTTP_WEBHOOKS === "1";

export function listDestinations(): Destination[] {
  return (db().prepare("SELECT * FROM alert_destinations ORDER BY created_at").all() as unknown as DestinationRow[]).map(toDestination);
}

/** URLs are sealed at rest (a Slack webhook URL is itself a credential). Webhooks get a signing secret, returned once. */
export function createDestination(input: { name: string; kind: "slack" | "webhook"; url: string; minSeverity: Severity }, actor: string):
  { ok: true; destination: Destination; signingSecret: string | null } | { ok: false; error: string } {
  const url = input.url.trim();
  const problem = destinationProblem(input.kind, url, allowHttp());
  if (problem) return { ok: false, error: problem };
  const id = newId("dst");
  const signingSecret = input.kind === "webhook" ? `whsec_${randomBytes(24).toString("base64url")}` : null;
  db().prepare(`INSERT INTO alert_destinations (id, name, kind, url_enc, url_hint, secret_enc, min_severity, created_at, created_by)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
    id, input.name.trim().slice(0, 80), input.kind, seal(url, "alert-url"), urlHint(url),
    signingSecret ? seal(signingSecret, "alert-secret") : null, input.minSeverity, Date.now(), actor);
  logConsoleAction(actor, "alerts.destination.created", `${input.name} (${input.kind})`);
  const row = db().prepare("SELECT * FROM alert_destinations WHERE id = ?").get(id) as unknown as DestinationRow;
  return { ok: true, destination: toDestination(row), signingSecret };
}

export function setDestinationEnabled(id: string, enabled: boolean, actor: string) {
  db().prepare("UPDATE alert_destinations SET enabled = ? WHERE id = ?").run(enabled ? 1 : 0, id);
  logConsoleAction(actor, enabled ? "alerts.destination.enabled" : "alerts.destination.paused", id);
}

export function deleteDestination(id: string, actor: string) {
  const row = db().prepare("SELECT name FROM alert_destinations WHERE id = ?").get(id) as { name: string } | undefined;
  db().prepare("DELETE FROM alert_destinations WHERE id = ?").run(id);
  logConsoleAction(actor, "alerts.destination.removed", row?.name ?? id);
}

// --- rules --------------------------------------------------------------------

export interface RuleState {
  id: RuleId;
  enabled: boolean;
  threshold: number | null;
}

export function ruleStates(): RuleState[] {
  const rows = db().prepare("SELECT id, enabled, threshold FROM alert_rules").all() as { id: string; enabled: number; threshold: number | null }[];
  const byId = new Map(rows.map((r) => [r.id, r]));
  return RULES.map((def) => {
    const row = byId.get(def.id);
    return { id: def.id, enabled: row ? row.enabled === 1 : true, threshold: def.threshold ? row?.threshold ?? def.threshold.default : null };
  });
}

export function updateRule(id: RuleId, patch: { enabled?: boolean; threshold?: number }, actor: string) {
  const def = ruleDef(id);
  if (!def) throw new Error("unknown rule");
  const current = ruleStates().find((r) => r.id === id)!;
  const enabled = patch.enabled ?? current.enabled;
  let threshold = patch.threshold ?? current.threshold;
  if (def.threshold && threshold != null) threshold = Math.min(def.threshold.max, Math.max(def.threshold.min, Math.round(threshold)));
  db().prepare(`INSERT INTO alert_rules (id, enabled, threshold, updated_at, updated_by) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET enabled = excluded.enabled, threshold = excluded.threshold, updated_at = excluded.updated_at, updated_by = excluded.updated_by`)
    .run(id, enabled ? 1 : 0, def.threshold ? threshold : null, Date.now(), actor);
  logConsoleAction(actor, "alerts.rule.updated", `${id}: ${enabled ? "on" : "off"}${def.threshold ? `, ${threshold} ${def.threshold.unit}` : ""}`);
}

// --- raising alerts -----------------------------------------------------------

/** Each rule fires at most once per cooldown for the same subject (device, secret, setting). */
function claimCooldown(key: string, ms: number, now = Date.now()): boolean {
  const row = db().prepare("SELECT until FROM alert_cooldowns WHERE key = ?").get(key) as { until: number } | undefined;
  if (row && row.until > now) return false;
  db().prepare("INSERT OR REPLACE INTO alert_cooldowns (key, until) VALUES (?, ?)").run(key, now + ms);
  return true;
}

/** A flood guard on top of cooldowns: at most this many alerts per 10 minutes. */
const FLOOD_LIMIT = 60;
let suppressed = 0;

type Candidate = Omit<Alert, "id" | "severity" | "title"> & { rule: RuleId; title?: string; subject: string };

function raise(candidate: Candidate): Alert | null {
  const def = ruleDef(candidate.rule)!;
  const state = ruleStates().find((r) => r.id === candidate.rule);
  if (!state?.enabled) return null;
  if (!claimCooldown(`${candidate.rule}:${candidate.subject}`, def.cooldownMs)) return null;
  const recent = (db().prepare("SELECT COUNT(*) AS n FROM alerts WHERE created_at > ?").get(Date.now() - 600_000) as { n: number }).n;
  if (recent >= FLOOD_LIMIT) {
    suppressed++;
    if (suppressed === 1 || suppressed % 100 === 0) logConsoleAction(null, "alerts.suppressed", `${suppressed} alerts over the flood limit`);
    return null;
  }
  const alert: Alert = {
    id: newId("alr"), rule: candidate.rule, severity: def.severity, title: candidate.title ?? def.title, summary: candidate.summary,
    occurredAt: candidate.occurredAt, deviceId: candidate.deviceId, hostname: candidate.hostname, fields: candidate.fields, path: candidate.path,
  };
  db().prepare("INSERT INTO alerts (id, rule, severity, title, summary, device_id, payload, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
    .run(alert.id, alert.rule, alert.severity, alert.title, alert.summary, alert.deviceId, JSON.stringify(alert), Date.now());
  return alert;
}

/** Old events (a backfill, a long-offline machine) never page anyone; chain breaks always do. */
const FRESH_MS = 60 * 60 * 1000;
const enc = encodeURIComponent;

export function evaluateIngest(outcome: Pick<IngestOutcome, "stored" | "breaks">, now = Date.now()): Alert[] {
  const alerts: (Alert | null)[] = [];
  for (const b of outcome.breaks) {
    alerts.push(raise({
      rule: "chain.break", subject: b.deviceId, deviceId: b.deviceId, hostname: b.hostname, occurredAt: b.time,
      title: `Audit chain broken on ${b.hostname}`,
      summary: `An event from ${b.hostname} does not follow the chain head the console holds. A line in its audit.jsonl was edited, removed or reordered, or forwarding skipped events.`,
      fields: [{ label: "Device", value: b.hostname }, { label: "Expected prev", value: `${b.expected.slice(0, 16)}…` }, { label: "Got prev", value: b.got ? `${b.got.slice(0, 16)}…` : "none" }],
      path: `/fleet/${enc(b.deviceId)}`,
    }));
  }
  for (const s of outcome.stored) {
    const e = s.event;
    if (now - e.time > FRESH_MS) continue;
    const base = { deviceId: s.deviceId, hostname: s.hostname, occurredAt: e.time };
    if (e.kind === "secret.misuse") {
      alerts.push(raise({
        ...base, rule: "secret.misuse", subject: `${s.deviceId}:${e.subject}`,
        title: `Secret misuse: ${e.subject} on ${s.hostname}`,
        summary: e.reason ?? "The secret gateway refused a placeholder used against its policy.",
        fields: [{ label: "Secret", value: e.subject }, { label: "Device", value: s.hostname }, { label: "Refusal", value: e.detail.refusal ?? "unknown" }, { label: "Reason code", value: e.reasonCode ?? "—" }],
        path: `/secrets`,
      }));
    } else if (e.kind === "mcp.approval" && e.reason === "forged grant rejected") {
      alerts.push(raise({
        ...base, rule: "mcp.forged", subject: `${s.deviceId}:${e.subject}`,
        title: `Forged MCP approval on ${s.hostname}`,
        summary: `The MCP gateway rejected an approval for ${e.subject} that rv did not sign.`,
        fields: [{ label: "Tool", value: e.subject }, { label: "Device", value: s.hostname }, { label: "Agent", value: e.agent ?? "unknown" }],
        path: `/mcp`,
      }));
    } else if ((e.kind === "config.changed" || e.kind === "policy.changed") && e.detail.direction === "loosening"
      && (!e.detail.authorized_by || e.detail.authorized_by === "none")) {
      const setting = e.detail.setting ?? e.subject;
      alerts.push(raise({
        ...base, rule: "gate.loosened", subject: `${s.deviceId}:${setting}`,
        title: `${setting} loosened without owner authentication on ${s.hostname}`,
        summary: `rv's ${setting} changed from ${e.detail.prior ?? "?"} to ${e.detail.new ?? "?"} with no owner check recorded.`,
        fields: [{ label: "Setting", value: setting }, { label: "Device", value: s.hostname }, { label: "Before", value: e.detail.prior ?? "—" }, { label: "After", value: e.detail.new ?? "—" }],
        path: `/policy`,
      }));
    }
  }
  return alerts.filter((a): a is Alert => a !== null);
}

export function evaluateReport(report: StoredReport): Alert[] {
  if (report.compliant || report.previous === false) return [];
  const alert = raise({
    rule: "device.noncompliant", subject: report.deviceId, deviceId: report.deviceId, hostname: report.hostname, occurredAt: Date.now(),
    title: `${report.hostname} is not compliant`,
    summary: report.findings[0] ?? "The latest rv report fails rv's compliance rule.",
    fields: report.findings.slice(0, 5).map((f, i) => ({ label: `Finding ${i + 1}`, value: f })),
    path: `/fleet/${enc(report.deviceId)}`,
  });
  return alert ? [alert] : [];
}

/** Rules that need a window rather than one event: spikes and silence. */
export function evaluateSweep(now = Date.now()): Alert[] {
  const states = ruleStates();
  const alerts: (Alert | null)[] = [];
  const spike = states.find((r) => r.id === "blocks.spike");
  if (spike?.enabled && spike.threshold) {
    const rows = db().prepare(`SELECT e.device_id, d.hostname, COUNT(*) AS n,
        (SELECT subject FROM events x WHERE x.device_id = e.device_id AND x.time >= ? AND x.decision = 'denied'
          GROUP BY subject ORDER BY COUNT(*) DESC LIMIT 1) AS top
      FROM events e JOIN devices d ON d.id = e.device_id
      WHERE e.time >= ? AND e.decision = 'denied' GROUP BY e.device_id HAVING n >= ?`).all(now - 600_000, now - 600_000, spike.threshold) as
      { device_id: string; hostname: string; n: number; top: string | null }[];
    for (const r of rows) {
      alerts.push(raise({
        rule: "blocks.spike", subject: r.device_id, deviceId: r.device_id, hostname: r.hostname, occurredAt: now,
        title: `${r.n} blocks in 10 minutes on ${r.hostname}`,
        summary: `${r.hostname} hit ${r.n} blocks in the last 10 minutes${r.top ? `, most often ${r.top}` : ""}. An agent may be looping on a destructive command.`,
        fields: [{ label: "Device", value: r.hostname }, { label: "Blocks", value: String(r.n) }, { label: "Top rule", value: r.top ?? "—" }],
        path: `/activity?device=${enc(r.device_id)}&decision=denied`,
      }));
    }
  }
  const silent = states.find((r) => r.id === "device.silent");
  if (silent?.enabled && silent.threshold) {
    const cutoff = now - silent.threshold * 3_600_000;
    const rows = db().prepare(`SELECT id, hostname, last_seen FROM devices WHERE last_seen < ? AND last_seen > ? AND event_count > 0`)
      .all(cutoff, now - 30 * 86_400_000) as { id: string; hostname: string; last_seen: number }[];
    for (const r of rows) {
      alerts.push(raise({
        rule: "device.silent", subject: `${r.id}:${r.last_seen}`, deviceId: r.id, hostname: r.hostname, occurredAt: now,
        title: `${r.hostname} stopped forwarding`,
        summary: `Nothing from ${r.hostname} for over ${silent.threshold} hours. rv may be uninstalled, its forward job stopped, or the machine offline.`,
        fields: [{ label: "Device", value: r.hostname }, { label: "Last seen", value: new Date(r.last_seen).toISOString() }],
        path: `/fleet/${enc(r.id)}`,
      }));
    }
  }
  return alerts.filter((a): a is Alert => a !== null);
}

// --- delivery -----------------------------------------------------------------

export interface DeliveryResult {
  status: "sent" | "failed";
  httpStatus: number | null;
  error: string | null;
  attempts: number;
}

type Transport = (url: string, init: RequestInit) => Promise<Response>;
let transport: Transport = (url, init) => fetch(url, init);
/** Tests swap the network out. */
export function setAlertTransport(next: Transport | null) {
  transport = next ?? ((url, init) => fetch(url, init));
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export function signatureHeader(secret: string, body: string, timestamp = Math.floor(Date.now() / 1000)): string {
  return `t=${timestamp},v1=${createHmac("sha256", secret).update(`${timestamp}.${body}`).digest("hex")}`;
}

async function deliverTo(row: DestinationRow, alert: Alert, backoffMs = [1000, 4000]): Promise<DeliveryResult> {
  const url = open(row.url_enc, "alert-url");
  if (!url) return { status: "failed", httpStatus: null, error: "Stored URL cannot be read (RV_CONSOLE_SECRET changed). Re-add this destination.", attempts: 0 };
  const body = JSON.stringify(row.kind === "slack" ? slackPayload(alert, config.publicUrl) : webhookPayload(alert, config.publicUrl));
  const headers: Record<string, string> = { "content-type": "application/json", "user-agent": "rv-console" };
  if (row.kind === "webhook") {
    headers["x-rv-console-event"] = "alert";
    headers["x-rv-console-delivery"] = alert.id;
    const secret = row.secret_enc ? open(row.secret_enc, "alert-secret") : null;
    if (secret) headers["x-rv-console-signature"] = signatureHeader(secret, body);
  }
  let last: DeliveryResult = { status: "failed", httpStatus: null, error: "not sent", attempts: 0 };
  for (let attempt = 1; attempt <= backoffMs.length + 1; attempt++) {
    try {
      const res = await transport(url, { method: "POST", headers, body, redirect: "manual", signal: AbortSignal.timeout(10_000) });
      if (res.status >= 200 && res.status < 300) return { status: "sent", httpStatus: res.status, error: null, attempts: attempt };
      last = { status: "failed", httpStatus: res.status, error: `HTTP ${res.status}`, attempts: attempt };
      // A client error will not fix itself on retry; 429 and 5xx might.
      if (res.status < 500 && res.status !== 429) break;
    } catch (error) {
      last = { status: "failed", httpStatus: null, error: error instanceof Error ? error.message : String(error), attempts: attempt };
    }
    if (attempt <= backoffMs.length) await sleep(backoffMs[attempt - 1]);
  }
  return last;
}

function record(alertId: string, row: DestinationRow, result: DeliveryResult) {
  const now = Date.now();
  db().prepare("INSERT INTO alert_deliveries (alert_id, destination_id, status, http_status, error, attempts, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
    .run(alertId, row.id, result.status, result.httpStatus, result.error?.slice(0, 300) ?? null, result.attempts, now);
  db().prepare("UPDATE alert_destinations SET last_status = ?, last_delivery_at = ? WHERE id = ?")
    .run(result.status === "sent" ? "sent" : result.error?.slice(0, 120) ?? "failed", now, row.id);
}

/** Sends each alert to every enabled destination whose minimum severity it meets. */
export async function dispatch(alerts: Alert[], backoffMs?: number[]): Promise<void> {
  if (!alerts.length) return;
  const rows = db().prepare("SELECT * FROM alert_destinations WHERE enabled = 1").all() as unknown as DestinationRow[];
  await Promise.all(alerts.flatMap((alert) => rows
    .filter((row) => SEVERITY_RANK[alert.severity] >= SEVERITY_RANK[row.min_severity])
    .map(async (row) => record(alert.id, row, await deliverTo(row, alert, backoffMs)))));
}

/** A sample alert to one destination, whatever its minimum severity. */
export async function sendTest(destinationId: string, actor: string): Promise<DeliveryResult> {
  const row = db().prepare("SELECT * FROM alert_destinations WHERE id = ?").get(destinationId) as DestinationRow | undefined;
  if (!row) return { status: "failed", httpStatus: null, error: "Destination not found", attempts: 0 };
  const alert: Alert = {
    id: newId("tst"), rule: "test", severity: "critical", title: "Test alert from rv Console",
    summary: `${actor} sent this test. Real alerts look like this one.`, occurredAt: Date.now(),
    deviceId: null, hostname: null, fields: [{ label: "Destination", value: row.name }, { label: "Sent by", value: actor }], path: "/alerts",
  };
  const result = await deliverTo(row, alert, []);
  record(alert.id, row, result);
  logConsoleAction(actor, "alerts.destination.tested", `${row.name}: ${result.status}`);
  return result;
}

// --- entry points -------------------------------------------------------------

const fire = (alerts: () => Alert[]) => {
  try {
    const raised = alerts();
    if (raised.length) dispatch(raised).catch((error) => console.error("[rv-console] alert dispatch", error));
  } catch (error) {
    console.error("[rv-console] alert evaluation", error);
  }
};

/** Called after an ingest commit; never throws and never delays rv's answer. */
export const alertsOnIngest = (outcome: Pick<IngestOutcome, "stored" | "breaks">) => fire(() => evaluateIngest(outcome));
export const alertsOnReport = (report: StoredReport) => fire(() => evaluateReport(report));

const globalAlerts = globalThis as unknown as { __rvAlertSweep?: NodeJS.Timeout };

export function startAlertSweep(intervalMs = 60_000) {
  if (globalAlerts.__rvAlertSweep) return;
  globalAlerts.__rvAlertSweep = setInterval(() => fire(() => evaluateSweep()), intervalMs);
  globalAlerts.__rvAlertSweep.unref?.();
}

// --- reading ------------------------------------------------------------------

export function recentAlerts(limit = 50) {
  const alerts = db().prepare("SELECT id, rule, severity, title, summary, device_id, created_at FROM alerts ORDER BY created_at DESC LIMIT ?").all(limit) as
    { id: string; rule: string; severity: Severity; title: string; summary: string; device_id: string | null; created_at: number }[];
  const deliveries = alerts.length
    ? db().prepare(`SELECT d.alert_id, d.status, d.error, d.http_status, t.name FROM alert_deliveries d LEFT JOIN alert_destinations t ON t.id = d.destination_id
        WHERE d.alert_id IN (${alerts.map(() => "?").join(",")})`).all(...alerts.map((a) => a.id)) as
        { alert_id: string; status: "sent" | "failed"; error: string | null; http_status: number | null; name: string | null }[]
    : [];
  return alerts.map((a) => ({
    id: a.id, rule: a.rule, severity: a.severity, title: a.title, summary: a.summary, deviceId: a.device_id, createdAt: a.created_at,
    deliveries: deliveries.filter((d) => d.alert_id === a.id).map((d) => ({ destination: d.name ?? "removed", status: d.status, error: d.error })),
  }));
}

export function alertStats(sinceMs = 7 * 86_400_000) {
  const since = Date.now() - sinceMs;
  const a = db().prepare("SELECT COUNT(*) AS n, SUM(CASE WHEN severity = 'critical' THEN 1 ELSE 0 END) AS critical FROM alerts WHERE created_at >= ?").get(since) as { n: number; critical: number | null };
  const d = db().prepare("SELECT SUM(CASE WHEN status = 'sent' THEN 1 ELSE 0 END) AS sent, SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed FROM alert_deliveries WHERE created_at >= ?").get(since) as { sent: number | null; failed: number | null };
  return { alerts: a.n, critical: a.critical ?? 0, sent: d.sent ?? 0, failed: d.failed ?? 0 };
}

export function pruneAlerts(retentionDays: number) {
  const cutoff = Date.now() - retentionDays * 86_400_000;
  db().prepare("DELETE FROM alerts WHERE created_at < ?").run(cutoff);
  db().prepare("DELETE FROM alert_deliveries WHERE created_at < ?").run(cutoff);
  db().prepare("DELETE FROM alert_cooldowns WHERE until < ?").run(Date.now());
}
