import { describe, expect, it } from "vitest"
import { MAX_EVENTS_PER_BATCH, parseEventBatch } from "@/lib/ingest/events"
import { isCompliant, reportSchema } from "@/lib/ingest/report"
import { displayPrefix, hashSecret, isWellFormed, newSecret } from "@/lib/server/credentials"
import rvBatch from "../fixtures/forward-rv.json"
import ocsfBatch from "../fixtures/forward-ocsf.json"
import report from "../fixtures/report.json"

describe("parseEventBatch: rv.audit.v1", () => {
  const parsed = parseEventBatch(rvBatch)
  if (!parsed.ok) throw new Error(parsed.error)

  it("detects the format and keeps every event", () => {
    expect(parsed.format).toBe("rv")
    expect(parsed.events).toHaveLength(3)
  })

  it("uses the chain head as uid for chained events", () => {
    expect(parsed.events[0]).toMatchObject({
      uid: rvBatch[0].chainHead,
      kind: "command.denied",
      decision: "denied",
      subject: "core.git:reset-hard",
      host: "claude",
      tool: "Bash",
      source: "audit.jsonl",
      prev: rvBatch[0].prev,
      chainHead: rvBatch[0].chainHead,
      time: "2026-11-20T10:00:00.000Z",
    })
  })

  it("gives unchained events a stable content uid", () => {
    const again = parseEventBatch(structuredClone(rvBatch))
    if (!again.ok) throw new Error(again.error)
    expect(parsed.events[2].uid).toMatch(/^[0-9a-f]{32}$/)
    expect(again.events[2].uid).toBe(parsed.events[2].uid)
    expect(parsed.events[2].chainHead).toBeNull()
  })

  it("keeps would_be in the body for the rollout report", () => {
    expect((parsed.events[1].body as { detail: { would_be: string } }).detail.would_be).toBe("deny")
  })
})

describe("parseEventBatch: OCSF", () => {
  const parsed = parseEventBatch(ocsfBatch)
  if (!parsed.ok) throw new Error(parsed.error)

  it("maps OCSF back to rv fields", () => {
    expect(parsed.format).toBe("ocsf")
    expect(parsed.hostname).toBe("mbp-ana")
    expect(parsed.events[0]).toMatchObject({
      uid: "5c1f3a9e0b2d4c6e8a0f1b3d5e7a9c1e",
      kind: "command.denied",
      decision: "denied",
      subject: "core.git:reset-hard",
      host: "claude",
      tool: "Bash",
      source: "audit.jsonl",
      chainHead: ocsfBatch[0].unmapped.rv_chain_head,
      prev: ocsfBatch[0].unmapped.rv_prev,
      time: new Date(1795183200000).toISOString(),
    })
  })

  it("maps disposition 17 to info", () => {
    expect(parsed.events[1]).toMatchObject({ kind: "config.changed", decision: "info", chainHead: null })
  })
})

describe("parseEventBatch: rejects", () => {
  it("non-arrays", () => {
    expect(parseEventBatch({})).toMatchObject({ ok: false })
  })
  it("oversized batches", () => {
    expect(parseEventBatch(new Array(MAX_EVENTS_PER_BATCH + 1).fill(rvBatch[0]))).toMatchObject({ ok: false })
  })
  it("bad kinds and decisions", () => {
    expect(parseEventBatch([{ ...rvBatch[0], kind: "DROP TABLE" }])).toMatchObject({ ok: false })
    expect(parseEventBatch([{ ...rvBatch[0], decision: "maybe" }])).toMatchObject({ ok: false })
    expect(parseEventBatch([{ ...ocsfBatch[0], disposition_id: 3 }])).toMatchObject({ ok: false })
  })
  it("accepts an empty batch", () => {
    expect(parseEventBatch([])).toMatchObject({ ok: true, events: [] })
  })
  it("truncates huge bodies instead of storing them", () => {
    const big = { ...rvBatch[2], detail: { note: "x".repeat(4000), a: "x".repeat(4000), b: "x".repeat(4000), c: "x".repeat(4000), d: "x".repeat(4000), e: "x".repeat(4000), f: "x".repeat(4000), g: "x".repeat(4000), h: "x".repeat(4000) } }
    const parsed = parseEventBatch([big])
    if (!parsed.ok) throw new Error(parsed.error)
    expect(parsed.events[0].body).toMatchObject({ truncated: true })
  })
})

describe("reports", () => {
  it("accepts a real rv.report.v1 and computes compliance like rv", () => {
    const parsed = reportSchema.safeParse(report)
    expect(parsed.success).toBe(true)
    if (!parsed.success) return
    expect(isCompliant(parsed.data)).toBe(true)
    expect(isCompliant({ ...parsed.data, audit: { ...parsed.data.audit, chainIntact: false } })).toBe(false)
    expect(isCompliant({ ...parsed.data, managed: { state: "invalid", reason: "bad signature" } })).toBe(false)
    expect(isCompliant({ ...parsed.data, mcp: { ...parsed.data.mcp, ok: false } })).toBe(false)
    expect(
      isCompliant({ ...parsed.data, secrets: { items: [{ name: "X", source: "hostEnvironment", delivery: "environment", policyViolation: "source not allowed" }] } }),
    ).toBe(false)
    // A missing chain state (unreadable log) is not a failure, as in rv.
    expect(isCompliant({ ...parsed.data, audit: { ...parsed.data.audit, chainIntact: undefined } })).toBe(true)
  })

  it("accepts the optional host modes and packs from newer clients", () => {
    const parsed = reportSchema.safeParse({ ...report, hosts: { claude: "block", cursor: "observe" }, packs: ["core.git"] })
    expect(parsed.success).toBe(true)
    expect(reportSchema.safeParse({ ...report, hosts: { claude: "maybe" } }).success).toBe(false)
  })

  it("rejects other schemas", () => {
    expect(reportSchema.safeParse({ ...report, schema: "rv.report.v2" }).success).toBe(false)
  })
})

describe("credentials", () => {
  it("generates well-formed secrets and hashes them", () => {
    const s = newSecret("rvc_mch_")
    expect(isWellFormed(s, "mch")).toBe(true)
    expect(isWellFormed(s, "enr")).toBe(false)
    expect(hashSecret(s)).toMatch(/^[0-9a-f]{64}$/)
    expect(displayPrefix(s)).toHaveLength(14)
    expect(isWellFormed("rvc_mch_short", "mch")).toBe(false)
  })
})
