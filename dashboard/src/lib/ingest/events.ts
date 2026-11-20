import crypto from "node:crypto"
import { z } from "zod"

// Parses what `rv audit forward` POSTs: a JSON array of either
//   - rv.audit.v1 events (`--format rv`), see Sources/RVHistory/AuditEvent.swift
//   - OCSF 1.3.0 objects (the default), see Sources/RVHistory/AuditOCSF.swift
// and normalizes both to one row shape for public.ingest_events().

export const MAX_EVENTS_PER_BATCH = 2000
const MAX_EVENT_BYTES = 32 * 1024

const kindSchema = z.string().regex(/^[a-z][a-z0-9_.-]{0,63}$/)
const decisionSchema = z.enum(["allowed", "denied", "pending", "failed", "info"])
const text = (max: number) => z.string().max(max)
const detailSchema = z.record(z.string().max(128), z.string().max(4096))

const rvEventSchema = z.object({
  schema: z.literal("rv.audit.v1"),
  time: z.iso.datetime({ offset: true }),
  kind: kindSchema,
  decision: decisionSchema,
  subject: text(1024),
  reason: text(4096).nullish(),
  workspace: text(1024).nullish(),
  runtime: text(1024).nullish(),
  agent: text(256).nullish(),
  source: text(128),
  detail: detailSchema.default({}),
  prev: text(128).nullish(),
  chainHead: text(128).nullish(),
})

const ocsfEventSchema = z.object({
  class_uid: z.number().int(),
  time: z.number().int().nonnegative(),
  disposition_id: z.number().int().optional(),
  status_id: z.number().int().optional(),
  metadata: z.object({
    uid: text(128),
    log_name: text(128).optional(),
    version: text(32).optional(),
  }),
  device: z.object({ hostname: text(255).optional() }).optional(),
  unmapped: z.object({
    rv_kind: kindSchema,
    rv_subject: text(1024),
    rv_reason: text(4096).optional(),
    rv_detail: detailSchema.optional(),
    rv_prev: text(128).optional(),
    rv_chain_head: text(128).optional(),
  }),
})

export type NormalizedEvent = {
  uid: string
  time: string
  kind: string
  decision: z.infer<typeof decisionSchema>
  subject: string
  host: string | null
  tool: string | null
  reason: string | null
  source: string | null
  prev: string | null
  chainHead: string | null
  body: unknown
}

export type ParseResult =
  | { ok: true; events: NormalizedEvent[]; format: "rv" | "ocsf" | "empty"; hostname: string | null }
  | { ok: false; error: string }

// OCSF disposition_id values rv writes (AuditOCSF.disposition), back to rv decisions.
const DISPOSITION: Record<number, NormalizedEvent["decision"]> = {
  1: "allowed",
  2: "denied",
  14: "pending",
  27: "failed",
  17: "info",
}

function stableStringify(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`
  if (value && typeof value === "object") {
    const entries = Object.keys(value as Record<string, unknown>)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${stableStringify((value as Record<string, unknown>)[k])}`)
    return `{${entries.join(",")}}`
  }
  return JSON.stringify(value)
}

function bodyOf(raw: unknown) {
  const json = JSON.stringify(raw)
  return json.length > MAX_EVENT_BYTES ? { truncated: true, bytes: json.length } : raw
}

function fromRv(raw: unknown, index: number): NormalizedEvent | string {
  const parsed = rvEventSchema.safeParse(raw)
  if (!parsed.success) return `event ${index}: ${parsed.error.issues[0]?.message ?? "invalid"}`
  const e = parsed.data
  // A chained line's own hash is unique; other ledgers' rows get a content hash.
  const uid = e.chainHead ?? crypto.createHash("sha256").update(stableStringify(raw)).digest("hex").slice(0, 32)
  return {
    uid,
    time: new Date(e.time).toISOString(),
    kind: e.kind,
    decision: e.decision,
    subject: e.subject,
    host: e.detail.host ?? e.agent ?? null,
    tool: e.detail.tool ?? null,
    reason: e.reason ?? null,
    source: e.source,
    prev: e.prev ?? null,
    chainHead: e.chainHead ?? null,
    body: bodyOf(raw),
  }
}

function fromOcsf(raw: unknown, index: number): NormalizedEvent | string {
  const parsed = ocsfEventSchema.safeParse(raw)
  if (!parsed.success) return `event ${index}: ${parsed.error.issues[0]?.message ?? "invalid"}`
  const e = parsed.data
  const detail = e.unmapped.rv_detail ?? {}
  const decision = DISPOSITION[e.disposition_id ?? -1]
  if (!decision) return `event ${index}: unknown disposition_id ${e.disposition_id}`
  return {
    uid: e.metadata.uid,
    time: new Date(e.time).toISOString(),
    kind: e.unmapped.rv_kind,
    decision,
    subject: e.unmapped.rv_subject,
    host: detail.host ?? null,
    tool: detail.tool ?? null,
    reason: e.unmapped.rv_reason ?? null,
    source: e.metadata.log_name ?? null,
    prev: e.unmapped.rv_prev ?? null,
    chainHead: e.unmapped.rv_chain_head ?? null,
    body: bodyOf(raw),
  }
}

export function parseEventBatch(input: unknown): ParseResult {
  if (!Array.isArray(input)) return { ok: false, error: "body must be a JSON array of events" }
  if (input.length === 0) return { ok: true, events: [], format: "empty", hostname: null }
  if (input.length > MAX_EVENTS_PER_BATCH) {
    return { ok: false, error: `at most ${MAX_EVENTS_PER_BATCH} events per request` }
  }
  const first = input[0] as Record<string, unknown> | null
  const format = first && typeof first === "object" && "class_uid" in first ? "ocsf" : "rv"
  const events: NormalizedEvent[] = []
  let hostname: string | null = null
  for (let i = 0; i < input.length; i++) {
    const out = format === "ocsf" ? fromOcsf(input[i], i) : fromRv(input[i], i)
    if (typeof out === "string") return { ok: false, error: out }
    events.push(out)
    if (format === "ocsf" && !hostname) {
      hostname = (input[i] as { device?: { hostname?: string } }).device?.hostname ?? null
    }
  }
  return { ok: true, events, format, hostname }
}
