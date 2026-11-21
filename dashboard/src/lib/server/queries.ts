import "server-only";
import { db } from "./db";
import { chainVerdict } from "../ingest/chain";
import { RANGES, type RangeKey } from "../range";
import catalog from "../catalog.generated.json";
import type { DeviceRow, EventRow, Kpi, RuleStat, TimelinePoint } from "../types";

type Row = Record<string, unknown>;
const all = (sql: string, ...params: (string | number | null)[]) => db().prepare(sql).all(...params) as Row[];
const get = (sql: string, ...params: (string | number | null)[]) => db().prepare(sql).get(...params) as Row | undefined;
const num = (v: unknown) => (typeof v === "number" ? v : typeof v === "bigint" ? Number(v) : 0);

const ruleCatalog = catalog.rules as Record<string, { s: string; d: string }>;
const packNames = new Map(catalog.packs.map((p) => [p.id, p.name]));

/** Category predicates shared by KPIs, timeline and tables. */
const IS_BLOCKED = "decision = 'denied'";
const IS_OBSERVED = "kind IN ('command.observed','egress.observed')";
const IS_OVERRIDE = "kind = 'command.override'";
const IS_MCP_CALL = "kind = 'mcp.call' AND COALESCE(json_extract(detail,'$.stage'),'') <> 'forward'";

function window(range: RangeKey, now = Date.now()) {
  const { ms } = RANGES[range];
  return { from: now - ms, to: now, prevFrom: now - 2 * ms };
}

export function toEventRow(r: Row): EventRow {
  let detail: Record<string, string> = {};
  try { detail = JSON.parse(String(r.detail ?? "{}")); } catch { /* stored by us; never malformed */ }
  return {
    seq: num(r.seq), uid: String(r.uid), deviceId: String(r.device_id), hostname: String(r.hostname ?? r.device_id),
    time: num(r.time), receivedAt: num(r.received_at), kind: String(r.kind), decision: r.decision as EventRow["decision"],
    subject: String(r.subject), reason: (r.reason as string) ?? null, reasonCode: (r.reason_code as string) ?? null,
    agent: (r.agent as string) ?? null, host: (r.host as string) ?? null, workspace: (r.workspace as string) ?? null,
    runtime: (r.runtime as string) ?? null, source: (r.source as string) ?? null, severity: num(r.severity),
    detail, prev: (r.prev as string) ?? null, chainHead: (r.chain_head as string) ?? null, format: r.format as EventRow["format"],
  };
}

const EVENT_SELECT = "SELECT e.*, d.hostname FROM events e JOIN devices d ON d.id = e.device_id";

// --- overview -----------------------------------------------------------------

export interface OverviewKpis {
  blocked: Kpi;
  observed: Kpi;
  overrides: Kpi;
  mcpCalls: Kpi;
  secretMisuse: Kpi;
  activeDevices: Kpi;
  totalDevices: number;
  compliantDevices: number;
  reportingDevices: number;
  brokenChains: number;
  totalEvents: number;
}

export function overviewKpis(range: RangeKey): OverviewKpis {
  const { from, to, prevFrom } = window(range);
  const count = (predicate: string) => {
    const r = get(`SELECT
        SUM(CASE WHEN time >= ? AND time <= ? THEN 1 ELSE 0 END) AS cur,
        SUM(CASE WHEN time >= ? AND time < ? THEN 1 ELSE 0 END) AS prev
      FROM events WHERE time >= ? AND (${predicate})`, from, to, prevFrom, from, prevFrom);
    return { value: num(r?.cur), previous: num(r?.prev) };
  };
  const active = get(`SELECT
      COUNT(DISTINCT CASE WHEN time >= ? THEN device_id END) AS cur,
      COUNT(DISTINCT CASE WHEN time < ? THEN device_id END) AS prev
    FROM events WHERE time >= ?`, from, from, prevFrom);
  const devices = get(`SELECT COUNT(*) AS total,
      SUM(CASE WHEN compliant = 1 THEN 1 ELSE 0 END) AS compliant,
      SUM(CASE WHEN report_at IS NOT NULL THEN 1 ELSE 0 END) AS reporting,
      SUM(CASE WHEN chain_breaks > 0 OR report_chain_intact = 0 THEN 1 ELSE 0 END) AS broken
    FROM devices`);
  return {
    blocked: count(IS_BLOCKED),
    observed: count(IS_OBSERVED),
    overrides: count(IS_OVERRIDE),
    mcpCalls: count(IS_MCP_CALL),
    secretMisuse: count("kind = 'secret.misuse'"),
    activeDevices: { value: num(active?.cur), previous: num(active?.prev) },
    totalDevices: num(devices?.total),
    compliantDevices: num(devices?.compliant),
    reportingDevices: num(devices?.reporting),
    brokenChains: num(devices?.broken),
    totalEvents: num(get("SELECT COUNT(*) AS n FROM events WHERE time >= ?", from)?.n),
  };
}

export function timeline(range: RangeKey, filter?: { deviceId?: string }): TimelinePoint[] {
  const { from, to } = window(range);
  const { bucketMs } = RANGES[range];
  const start = Math.floor(from / bucketMs) * bucketMs;
  const rows = all(`SELECT (time / CAST(? AS INTEGER)) * CAST(? AS INTEGER) AS b,
      SUM(CASE WHEN ${IS_BLOCKED} THEN 1 ELSE 0 END) AS blocked,
      SUM(CASE WHEN ${IS_OVERRIDE} THEN 1 ELSE 0 END) AS overrides,
      SUM(CASE WHEN ${IS_OBSERVED} THEN 1 ELSE 0 END) AS observed,
      SUM(CASE WHEN ${IS_MCP_CALL} THEN 1 ELSE 0 END) AS mcp
    FROM events WHERE time >= ? AND time <= ? ${filter?.deviceId ? "AND device_id = ?" : ""}
    GROUP BY b`, bucketMs, bucketMs, from, to, ...(filter?.deviceId ? [filter.deviceId] : []));
  const byBucket = new Map(rows.map((r) => [num(r.b), r]));
  const points: TimelinePoint[] = [];
  for (let t = start; t <= to; t += bucketMs) {
    const r = byBucket.get(t);
    points.push({ t, blocked: num(r?.blocked), overrides: num(r?.overrides), observed: num(r?.observed), mcp: num(r?.mcp) });
  }
  return points;
}

export function ruleMeta(rule: string) {
  const pack = rule.includes(":") ? rule.slice(0, rule.indexOf(":")) : rule;
  const meta = ruleCatalog[rule];
  return { pack, packName: packNames.get(pack) ?? null, severity: meta?.s ?? null, description: meta?.d ?? null };
}

export function topRules(range: RangeKey, limit = 50): RuleStat[] {
  const { from, to } = window(range);
  const { bucketMs } = RANGES[range];
  const rows = all(`SELECT subject AS rule,
      SUM(CASE WHEN kind = 'command.denied' THEN 1 ELSE 0 END) AS blocked,
      SUM(CASE WHEN kind = 'command.observed' THEN 1 ELSE 0 END) AS observed,
      SUM(CASE WHEN kind = 'command.override' THEN 1 ELSE 0 END) AS overrides,
      COUNT(DISTINCT device_id) AS devices,
      GROUP_CONCAT(DISTINCT host) AS hosts,
      MAX(time) AS last
    FROM events WHERE time >= ? AND kind IN ('command.denied','command.observed','command.override')
    GROUP BY subject ORDER BY (blocked + observed) DESC, last DESC LIMIT ?`, from, limit);
  const buckets = Math.min(24, Math.ceil((to - from) / bucketMs));
  const trendStep = (to - from) / buckets;
  const trendRows = rows.length
    ? all(`SELECT subject, CAST((time - ?) / ? AS INTEGER) AS b, COUNT(*) AS n FROM events
        WHERE time >= ? AND kind IN ('command.denied','command.observed') AND subject IN (${rows.map(() => "?").join(",")})
        GROUP BY subject, b`, from, trendStep, from, ...rows.map((r) => String(r.rule)))
    : [];
  const trends = new Map<string, number[]>();
  for (const t of trendRows) {
    const arr = trends.get(String(t.subject)) ?? new Array(buckets).fill(0);
    const i = Math.min(buckets - 1, Math.max(0, num(t.b)));
    arr[i] += num(t.n);
    trends.set(String(t.subject), arr);
  }
  return rows.map((r) => ({
    rule: String(r.rule),
    ...ruleMeta(String(r.rule)),
    blocked: num(r.blocked), observed: num(r.observed), overrides: num(r.overrides), devices: num(r.devices),
    hosts: String(r.hosts ?? "").split(",").filter(Boolean),
    lastSeen: num(r.last),
    trend: trends.get(String(r.rule)) ?? new Array(buckets).fill(0),
  }));
}

export function byAgentHost(range: RangeKey) {
  const { from } = window(range);
  return all(`SELECT COALESCE(host, 'terminal') AS host,
      SUM(CASE WHEN kind = 'command.denied' THEN 1 ELSE 0 END) AS blocked,
      SUM(CASE WHEN kind = 'command.observed' THEN 1 ELSE 0 END) AS observed,
      SUM(CASE WHEN kind = 'command.override' THEN 1 ELSE 0 END) AS overrides,
      COUNT(DISTINCT device_id) AS devices
    FROM events WHERE time >= ? AND kind IN ('command.denied','command.observed','command.override')
    GROUP BY 1 ORDER BY blocked + observed DESC`, from)
    .map((r) => ({ host: String(r.host), blocked: num(r.blocked), observed: num(r.observed), overrides: num(r.overrides), devices: num(r.devices) }));
}

export function byReasonCode(range: RangeKey, limit = 12) {
  const { from } = window(range);
  return all(`SELECT reason_code AS code, COUNT(*) AS n FROM events
    WHERE time >= ? AND reason_code IS NOT NULL GROUP BY 1 ORDER BY n DESC LIMIT ?`, from, limit)
    .map((r) => ({ code: String(r.code), count: num(r.n) }));
}

export function byPackCategory(range: RangeKey) {
  const { from } = window(range);
  const rows = all(`SELECT subject, COUNT(*) AS n FROM events
    WHERE time >= ? AND kind IN ('command.denied','command.observed') GROUP BY subject`, from);
  const byPack = new Map<string, number>();
  for (const r of rows) {
    const { pack } = ruleMeta(String(r.subject));
    byPack.set(pack, (byPack.get(pack) ?? 0) + num(r.n));
  }
  return [...byPack.entries()]
    .map(([pack, count]) => ({ pack, name: packNames.get(pack) ?? pack, count }))
    .sort((a, b) => b.count - a.count);
}

// --- events -----------------------------------------------------------------

export interface EventQuery {
  q?: string;
  kind?: string;
  decision?: string;
  device?: string;
  host?: string;
  range?: RangeKey;
  /** Page cursor `time:seq` from the last row; rows sort newest event time first. */
  before?: string;
  /** Live tail: only events received after this seq. */
  after?: number;
  limit?: number;
}

export const cursorOf = (row: EventRow) => `${row.time}:${row.seq}`;

export function searchEvents(query: EventQuery): { rows: EventRow[]; total: number } {
  const where: string[] = [];
  const params: (string | number)[] = [];
  if (query.range) { where.push("e.time >= ?"); params.push(Date.now() - RANGES[query.range].ms); }
  if (query.kind) { where.push("(e.kind = ? OR e.kind LIKE ?)"); params.push(query.kind, `${query.kind}.%`); }
  if (query.decision) { where.push("e.decision = ?"); params.push(query.decision); }
  if (query.device) { where.push("e.device_id = ?"); params.push(query.device); }
  if (query.host) { where.push("e.host = ?"); params.push(query.host); }
  if (query.q) {
    const like = `%${query.q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
    where.push("(e.subject LIKE ? ESCAPE '\\' OR e.reason LIKE ? ESCAPE '\\' OR d.hostname LIKE ? ESCAPE '\\' OR e.kind LIKE ? ESCAPE '\\' OR e.detail LIKE ? ESCAPE '\\' OR e.reason_code LIKE ? ESCAPE '\\')");
    params.push(like, like, like, like, like, like);
  }
  const base = where.length ? `WHERE ${where.join(" AND ")}` : "";
  const total = num(get(`SELECT COUNT(*) AS n FROM events e JOIN devices d ON d.id = e.device_id ${base}`, ...params)?.n);
  const page: string[] = [...where];
  const pageParams = [...params];
  const cursor = query.before?.match(/^(\d+):(\d+)$/);
  if (cursor) {
    page.push("(e.time < ? OR (e.time = ? AND e.seq < ?))");
    pageParams.push(Number(cursor[1]), Number(cursor[1]), Number(cursor[2]));
  }
  if (query.after) { page.push("e.seq > ?"); pageParams.push(query.after); }
  const limit = Math.min(500, Math.max(1, query.limit ?? 100));
  // The live tail returns arrivals in arrival order; pages sort by event time.
  const order = query.after ? "e.seq DESC" : "e.time DESC, e.seq DESC";
  const rows = all(`${EVENT_SELECT} ${page.length ? `WHERE ${page.join(" AND ")}` : ""} ORDER BY ${order} LIMIT ?`, ...pageParams, limit);
  return { rows: rows.map(toEventRow), total };
}

export function recentEvents(limit = 30, filter?: string): EventRow[] {
  const where = filter === "alerts" ? "WHERE e.decision = 'denied' OR e.kind IN ('command.observed','secret.misuse')" : "";
  return all(`${EVENT_SELECT} ${where} ORDER BY e.time DESC, e.seq DESC LIMIT ?`, limit).map(toEventRow);
}

export function eventFacets() {
  return {
    kinds: all("SELECT kind, COUNT(*) AS n FROM events GROUP BY kind ORDER BY n DESC").map((r) => ({ value: String(r.kind), count: num(r.n) })),
    hosts: all("SELECT host, COUNT(*) AS n FROM events WHERE host IS NOT NULL GROUP BY host ORDER BY n DESC").map((r) => ({ value: String(r.host), count: num(r.n) })),
    devices: all("SELECT id, hostname FROM devices ORDER BY hostname").map((r) => ({ value: String(r.id), label: String(r.hostname) })),
  };
}

// --- devices ------------------------------------------------------------------

function deviceRows(where = "", ...params: (string | number)[]): DeviceRow[] {
  const now = Date.now();
  const since = now - 86_400_000;
  const rows = all(`SELECT d.*,
      (SELECT COUNT(*) FROM events e WHERE e.device_id = d.id AND e.time >= ? AND e.decision = 'denied') AS blocked24,
      (SELECT COUNT(*) FROM events e WHERE e.device_id = d.id AND e.time >= ? AND e.kind = 'command.observed') AS observed24,
      (SELECT COUNT(*) FROM events e WHERE e.device_id = d.id AND e.time >= ?) AS events24,
      (SELECT GROUP_CONCAT(DISTINCT e.host) FROM events e WHERE e.device_id = d.id AND e.time >= ? AND e.host IS NOT NULL) AS hosts,
      CASE WHEN d.report_chain_head IS NULL THEN NULL
           WHEN EXISTS (SELECT 1 FROM events e WHERE e.device_id = d.id AND e.chain_head = d.report_chain_head) THEN 1
           ELSE 0 END AS report_head_known
    FROM devices d ${where} ORDER BY d.last_seen DESC`, since, since, since, since - 6 * 86_400_000, ...params);
  return rows.map((r) => {
    const reportIntact = r.report_chain_intact === null || r.report_chain_intact === undefined ? null : num(r.report_chain_intact) === 1;
    return {
      id: String(r.id), hostname: String(r.hostname), firstSeen: num(r.first_seen), lastSeen: num(r.last_seen),
      lastEventAt: r.last_event_at == null ? null : num(r.last_event_at),
      rvVersion: (r.rv_version as string) ?? null, platform: (r.platform as string) ?? null, osUser: (r.os_user as string) ?? null,
      managedState: (r.managed_state as string) ?? null, organization: (r.organization as string) ?? null,
      policySerial: r.policy_serial == null ? null : num(r.policy_serial),
      compliant: r.compliant == null ? null : num(r.compliant) === 1,
      reportAt: r.report_at == null ? null : num(r.report_at),
      chainVerdict: chainVerdict({
        chainEvents: num(r.chain_events), chainBreaks: num(r.chain_breaks),
        reportHeadKnown: r.report_head_known == null ? null : num(r.report_head_known) === 1,
        reportChainIntact: reportIntact,
      }),
      chainBreaks: num(r.chain_breaks), chainEvents: num(r.chain_events), chainHead: (r.chain_head as string) ?? null,
      blocked: num(r.blocked24), observed: num(r.observed24), events: num(r.events24),
      hosts: String(r.hosts ?? "").split(",").filter(Boolean),
      stale: now - num(r.last_seen) > 86_400_000,
    };
  });
}

export function listDevices(): DeviceRow[] {
  return deviceRows();
}

export function getDevice(id: string) {
  const [device] = deviceRows("WHERE d.id = ?", id);
  if (!device) return null;
  const raw = get("SELECT report_json FROM devices WHERE id = ?", id);
  const breaks = all("SELECT * FROM chain_breaks WHERE device_id = ? ORDER BY id DESC LIMIT 50", id)
    .map((r) => ({ seq: num(r.seq), time: num(r.time), detectedAt: num(r.detected_at), expected: String(r.expected ?? ""), got: (r.got as string) ?? null }));
  return { device, report: raw?.report_json ? JSON.parse(String(raw.report_json)) : null, breaks };
}

export function versionDistribution() {
  return all("SELECT COALESCE(rv_version,'unknown') AS v, COUNT(*) AS n FROM devices GROUP BY 1 ORDER BY n DESC")
    .map((r) => ({ version: String(r.v), count: num(r.n) }));
}

// --- MCP ------------------------------------------------------------------

export function mcpTools(range: RangeKey) {
  const { from } = window(range);
  return all(`SELECT subject,
      COALESCE(json_extract(detail,'$.server'), substr(subject, 1, instr(subject,'/') - 1)) AS server,
      COALESCE(json_extract(detail,'$.tool'), substr(subject, instr(subject,'/') + 1)) AS tool,
      SUM(CASE WHEN decision = 'allowed' THEN 1 ELSE 0 END) AS allowed,
      SUM(CASE WHEN decision = 'denied' THEN 1 ELSE 0 END) AS denied,
      SUM(CASE WHEN decision = 'pending' THEN 1 ELSE 0 END) AS pending,
      SUM(CASE WHEN json_extract(detail,'$.isError') = 'true' THEN 1 ELSE 0 END) AS errors,
      SUM(CASE WHEN json_extract(detail,'$.policy') = 'ask' THEN 1 ELSE 0 END) AS asks,
      AVG(CAST(json_extract(detail,'$.durationMs') AS REAL)) AS avg_ms,
      MAX(CAST(json_extract(detail,'$.durationMs') AS REAL)) AS max_ms,
      COUNT(DISTINCT device_id) AS devices,
      MAX(time) AS last
    FROM events WHERE time >= ? AND ${IS_MCP_CALL}
    GROUP BY subject ORDER BY allowed + denied + pending DESC`, from)
    .map((r) => ({
      subject: String(r.subject), server: String(r.server ?? ""), tool: String(r.tool ?? ""),
      allowed: num(r.allowed), denied: num(r.denied), pending: num(r.pending), errors: num(r.errors), asks: num(r.asks),
      avgMs: r.avg_ms == null ? null : Math.round(num(r.avg_ms)), maxMs: r.max_ms == null ? null : Math.round(num(r.max_ms)),
      devices: num(r.devices), lastSeen: num(r.last),
    }));
}

export function mcpSignals(range: RangeKey) {
  const { from } = window(range);
  return all(`${EVENT_SELECT} WHERE e.time >= ? AND e.kind IN ('mcp.approval','mcp.tool.changed','mcp.hosts.ungoverned')
    ORDER BY e.time DESC, e.seq DESC LIMIT 100`, from).map(toEventRow);
}

// --- secrets ------------------------------------------------------------------

export function secretStats(range: RangeKey) {
  const { from } = window(range);
  return all(`SELECT subject AS name,
      SUM(CASE WHEN kind = 'secret.use' AND decision <> 'denied' THEN 1 ELSE 0 END) AS uses,
      SUM(CASE WHEN kind = 'secret.use' AND decision = 'denied' THEN 1 ELSE 0 END) AS refused,
      SUM(CASE WHEN kind = 'secret.misuse' THEN 1 ELSE 0 END) AS misuse,
      COUNT(DISTINCT device_id) AS devices,
      MAX(json_extract(detail,'$.fingerprint')) AS fingerprint,
      MAX(time) AS last
    FROM events WHERE time >= ? AND kind IN ('secret.use','secret.misuse')
    GROUP BY subject ORDER BY misuse DESC, uses DESC`, from)
    .map((r) => ({
      name: String(r.name), uses: num(r.uses), refused: num(r.refused), misuse: num(r.misuse), devices: num(r.devices),
      fingerprint: (r.fingerprint as string) ?? null, lastSeen: num(r.last),
    }));
}

export function secretAlerts(range: RangeKey) {
  const { from } = window(range);
  return all(`${EVENT_SELECT} WHERE e.time >= ? AND (e.kind = 'secret.misuse' OR (e.kind = 'secret.use' AND e.decision = 'denied'))
    ORDER BY e.time DESC, e.seq DESC LIMIT 100`, from).map(toEventRow);
}

// --- policy -------------------------------------------------------------------

export function policyChanges(range: RangeKey) {
  const { from } = window(range);
  return all(`${EVENT_SELECT} WHERE e.time >= ? AND e.kind IN ('config.changed','policy.changed','policy.managed')
    ORDER BY e.time DESC, e.seq DESC LIMIT 200`, from).map(toEventRow);
}

export function ownerActions(range: RangeKey) {
  const { from } = window(range);
  const r = get(`SELECT COUNT(*) AS total, SUM(CASE WHEN decision = 'denied' THEN 1 ELSE 0 END) AS refused
    FROM events WHERE time >= ? AND kind = 'owner.action'`, from);
  return { total: num(r?.total), refused: num(r?.refused) };
}

export function policyRollout() {
  return all(`SELECT COALESCE(organization, '') AS org, policy_serial AS serial, managed_state AS state, COUNT(*) AS n
    FROM devices WHERE report_at IS NOT NULL GROUP BY 1, 2, 3 ORDER BY serial DESC`)
    .map((r) => ({ organization: String(r.org) || null, serial: r.serial == null ? null : num(r.serial), state: String(r.state ?? "none"), count: num(r.n) }));
}

// --- integrity ----------------------------------------------------------------

export function recentChainBreaks(limit = 50) {
  return all(`SELECT b.*, d.hostname FROM chain_breaks b JOIN devices d ON d.id = b.device_id ORDER BY b.id DESC LIMIT ?`, limit)
    .map((r) => ({
      deviceId: String(r.device_id), hostname: String(r.hostname), seq: num(r.seq), time: num(r.time),
      detectedAt: num(r.detected_at), expected: String(r.expected ?? ""), got: (r.got as string) ?? null,
    }));
}

// --- chrome -------------------------------------------------------------------

export function statusSnapshot() {
  const r = get(`SELECT
      (SELECT COUNT(*) FROM devices) AS devices,
      (SELECT MAX(received_at) FROM events) AS last_received,
      (SELECT MAX(seq) FROM events) AS head_seq,
      (SELECT COUNT(*) FROM events WHERE time >= ?) AS last_hour,
      (SELECT COUNT(*) FROM devices WHERE chain_breaks > 0 OR report_chain_intact = 0) AS broken`, Date.now() - 3_600_000);
  return {
    devices: num(r?.devices), lastReceived: r?.last_received == null ? null : num(r.last_received),
    headSeq: num(r?.head_seq), lastHour: num(r?.last_hour), brokenChains: num(r?.broken),
  };
}

export function consoleLog(limit = 50) {
  return all("SELECT * FROM console_log ORDER BY id DESC LIMIT ?", limit)
    .map((r) => ({ time: num(r.time), actor: (r.actor as string) ?? null, action: String(r.action), target: (r.target as string) ?? null }));
}
