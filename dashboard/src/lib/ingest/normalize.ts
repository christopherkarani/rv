import { createHash } from "node:crypto";
import { z } from "zod";
import { reasonCode } from "./reason-code";

/** One audit event as the console stores it, from either forward format. */
export interface NormalizedEvent {
  uid: string;
  /** Host name the event names (OCSF `device.hostname`); rv format carries none. */
  hostname: string | null;
  time: number;
  kind: string;
  decision: Decision;
  subject: string;
  reason: string | null;
  reasonCode: string | null;
  agent: string | null;
  host: string | null;
  workspace: string | null;
  runtime: string | null;
  source: string;
  severity: number;
  detail: Record<string, string>;
  prev: string | null;
  chainHead: string | null;
  format: "ocsf" | "rv";
}

export const DECISIONS = ["allowed", "denied", "pending", "failed", "info"] as const;
export type Decision = (typeof DECISIONS)[number];

export class IngestError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
  }
}

export const MAX_BATCH = 5000;
const MAX_TEXT = 2048;
const MAX_DETAIL_KEYS = 64;
const HEX64 = /^[0-9a-f]{64}$/;

const clip = (value: string, max = MAX_TEXT) => (value.length > max ? value.slice(0, max) : value);
const optText = (value: unknown, max = MAX_TEXT): string | null =>
  typeof value === "string" && value.length > 0 ? clip(value, max) : null;
const hex = (value: unknown) => (typeof value === "string" && HEX64.test(value) ? value : null);

/** rv's `detail` is string to string; coerce anything else and bound it. */
function detailMap(value: unknown): Record<string, string> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const out: Record<string, string> = {};
  for (const [key, raw] of Object.entries(value as Record<string, unknown>).slice(0, MAX_DETAIL_KEYS)) {
    if (raw === null || raw === undefined) continue;
    out[clip(key, 128)] = clip(typeof raw === "string" ? raw : JSON.stringify(raw));
  }
  return out;
}

function severityFor(kind: string, decision: Decision): number {
  if (kind === "secret.misuse") return 4;
  if (decision === "denied" || decision === "failed") return 3;
  if (decision === "pending") return 2;
  return 1;
}

const OCSF_DISPOSITION: Record<number, Decision> = { 1: "allowed", 2: "denied", 14: "pending", 27: "failed", 17: "info" };

const ocsfSchema = z.object({
  time: z.number().int().nonnegative(),
  metadata: z.object({ uid: z.string().min(8).max(128), log_name: z.string().optional() }).loose(),
  device: z.object({ hostname: z.string().optional() }).loose().optional(),
  actor: z.object({ app_name: z.string().optional() }).loose().optional(),
  disposition_id: z.number().int().optional(),
  severity_id: z.number().int().optional(),
  status_code: z.string().optional(),
  unmapped: z.object({
    rv_kind: z.string().min(1).max(128),
    rv_subject: z.string().max(4096),
  }).loose(),
}).loose();

function fromOCSF(raw: unknown): NormalizedEvent {
  const parsed = ocsfSchema.safeParse(raw);
  if (!parsed.success) throw new IngestError(`not an rv OCSF event: ${parsed.error.issues[0]?.path.join(".") || "shape"}`);
  const o = parsed.data;
  const u = o.unmapped as Record<string, unknown>;
  const decision = OCSF_DISPOSITION[o.disposition_id ?? 17] ?? "info";
  const kind = clip(o.unmapped.rv_kind, 128);
  const detail = detailMap(u.rv_detail);
  const appName = o.actor?.app_name;
  const agent = appName && appName !== "unknown" ? clip(appName, 128) : null;
  return {
    uid: o.metadata.uid,
    hostname: optText(o.device?.hostname, 253),
    time: o.time,
    kind,
    decision,
    subject: clip(o.unmapped.rv_subject),
    reason: optText(u.rv_reason),
    reasonCode: optText(o.status_code, 128),
    agent,
    host: detail.host ?? agent,
    workspace: optText(u.rv_workspace, 256),
    runtime: optText(u.rv_runtime, 256),
    source: optText(o.metadata.log_name, 128) ?? "unknown",
    severity: Math.max(1, Math.min(6, o.severity_id ?? severityFor(kind, decision))),
    detail,
    prev: hex(u.rv_prev),
    chainHead: hex(u.rv_chain_head),
    format: "ocsf",
  };
}

const rvSchema = z.object({
  schema: z.literal("rv.audit.v1"),
  time: z.string().min(10).max(64),
  kind: z.string().min(1).max(128),
  decision: z.enum(DECISIONS),
  subject: z.string().max(4096),
  reason: z.string().nullish(),
  workspace: z.string().nullish(),
  runtime: z.string().nullish(),
  agent: z.string().nullish(),
  source: z.string().max(128),
  detail: z.record(z.string(), z.unknown()).optional(),
  prev: z.string().nullish(),
  chainHead: z.string().nullish(),
}).loose();

function stableJSON(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(",")}]`;
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, v]) => v !== undefined)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${stableJSON(v)}`).join(",")}}`;
}

function fromRV(raw: unknown, deviceKey: string): NormalizedEvent {
  const parsed = rvSchema.safeParse(raw);
  if (!parsed.success) throw new IngestError(`not an rv.audit.v1 event: ${parsed.error.issues[0]?.path.join(".") || "shape"}`);
  const e = parsed.data;
  const time = Date.parse(e.time);
  if (!Number.isFinite(time)) throw new IngestError("not an rv.audit.v1 event: time");
  const detail = detailMap(e.detail);
  const reason = optText(e.reason);
  const agent = optText(e.agent, 128);
  // rv's own uid hashes its Swift encoding; this one is as stable for
  // at-least-once resends from the same device, which is what dedupe needs.
  const uid = createHash("sha256").update(deviceKey).update("\n").update(stableJSON(raw)).digest("hex").slice(0, 32);
  return {
    uid,
    hostname: null,
    time,
    kind: e.kind,
    decision: e.decision,
    subject: clip(e.subject),
    reason,
    reasonCode: reasonCode({ kind: e.kind, decision: e.decision, subject: e.subject, reason, source: e.source, detail }),
    agent,
    host: detail.host ?? agent,
    workspace: optText(e.workspace, 256),
    runtime: optText(e.runtime, 256),
    source: e.source,
    severity: severityFor(e.kind, e.decision),
    detail,
    prev: hex(e.prev),
    chainHead: hex(e.chainHead),
    format: "rv",
  };
}

/**
 * Parses one `rv audit forward` POST body: a JSON array of OCSF objects (the
 * default) or of `rv.audit.v1` events (`--format rv`). The format is detected
 * per batch from the first element.
 */
export function parseBatch(body: unknown, deviceKey: string): NormalizedEvent[] {
  const items = Array.isArray(body) ? body : body && typeof body === "object" ? [body] : null;
  if (!items) throw new IngestError("body must be a JSON array of events");
  if (items.length > MAX_BATCH) throw new IngestError(`batch too large (max ${MAX_BATCH} events)`, 413);
  if (items.length === 0) return [];
  const first = items[0] as Record<string, unknown>;
  const isRV = first && typeof first === "object" && first.schema === "rv.audit.v1";
  return items.map((item, index) => {
    try {
      return isRV ? fromRV(item, deviceKey) : fromOCSF(item);
    } catch (error) {
      if (error instanceof IngestError) throw new IngestError(`event ${index}: ${error.message}`, error.status);
      throw error;
    }
  });
}

/** Device ids are lower-cased host names, bounded to DNS length. */
export function deviceIdFor(hostname: string): string {
  return hostname.trim().toLowerCase().slice(0, 253);
}
