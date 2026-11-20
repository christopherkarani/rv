// Calls the real route handlers against the local stack (Supabase API +
// Postgres). Needs DATABASE_URL, NEXT_PUBLIC_SUPABASE_URL,
// NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY and APP_URL.
import { afterAll, beforeAll, describe, expect, it } from "vitest"
import type pg from "pg"
import { DATABASE_URL, createOrgAs, createUser, pool, sha256 } from "../db/helpers"
import { newSecret } from "@/lib/server/credentials"
import rvBatch from "../fixtures/forward-rv.json"
import ocsfBatch from "../fixtures/forward-ocsf.json"
import report from "../fixtures/report.json"

const ready = DATABASE_URL && process.env.SUPABASE_SECRET_KEY && process.env.NEXT_PUBLIC_SUPABASE_URL
const run = ready ? describe : describe.skip

type Handler = (r: Request) => Promise<Response>

run("ingest API", () => {
  let db: pg.Pool
  let enrollPOST: Handler
  let reportPOST: Handler
  let eventsPOST: Handler
  let orgId: string
  let token: string

  beforeAll(async () => {
    process.env.APP_URL ??= "http://localhost:3000"
    db = pool()
    enrollPOST = (await import("@/app/api/v1/enroll/route")).POST
    reportPOST = (await import("@/app/api/v1/report/route")).POST
    eventsPOST = (await import("@/app/api/v1/events/route")).POST
    const owner = await createUser(db)
    orgId = await createOrgAs(db, owner.id)
    token = newSecret("rvc_enr_")
    await db.query(
      "insert into public.enrollment_tokens (org_id, token_hash, prefix, expires_at) values ($1, $2, $3, now() + interval '1 day')",
      [orgId, sha256(token), token.slice(0, 14)],
    )
  })
  afterAll(async () => {
    await db.end()
  })

  const post = (handler: Handler, body: unknown, credential?: string, ip = `10.0.0.${Math.floor(Math.random() * 250)}`) =>
    handler(
      new Request("http://localhost/api", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-real-ip": ip,
          ...(credential ? { authorization: `Bearer ${credential}` } : {}),
        },
        body: JSON.stringify(body),
      }),
    )

  async function enroll(name = "mbp-ana") {
    const res = await post(enrollPOST, { token, name, platform: "macos", rvVersion: "0.2.2" })
    expect(res.status).toBe(201)
    return (await res.json()) as { machineId: string; credential: string; endpoints: { events: string } }
  }

  it("enrolls with a token and returns a one-time credential", async () => {
    const out = await enroll()
    expect(out.credential).toMatch(/^rvc_mch_/)
    expect(out.endpoints.events).toBe("http://localhost:3000/api/v1/events")
    const { rows } = await db.query("select org_id, credential_hash from public.machines where id = $1", [out.machineId])
    expect(rows[0].org_id).toBe(orgId)
    expect(rows[0].credential_hash).not.toContain(out.credential)
  })

  it("rejects bad enrollment tokens without saying which part was wrong", async () => {
    const res = await post(enrollPOST, { token: "rvc_enr_" + "B".repeat(43), name: "x" })
    expect(res.status).toBe(401)
    const malformed = await post(enrollPOST, { token: "nope", name: "x" })
    expect(malformed.status).toBe(401)
  })

  it("stores a report and computes compliance", async () => {
    const m = await enroll()
    const res = await post(reportPOST, report, m.credential)
    expect(res.status).toBe(202)
    expect(await res.json()).toEqual({ accepted: true, compliant: true })
    const { rows } = await db.query("select hostname, compliant, rv_version from public.machines where id = $1", [m.machineId])
    expect(rows[0]).toEqual({ hostname: "mbp-ana", compliant: true, rv_version: "0.2.2" })
  })

  it("rejects an invalid report with the failing field", async () => {
    const m = await enroll()
    const res = await post(reportPOST, { ...report, mcp: { ok: "yes" } }, m.credential)
    expect(res.status).toBe(400)
    expect(JSON.stringify(await res.json())).toContain("mcp")
  })

  it("ingests rv-format and OCSF batches, idempotently", async () => {
    const m = await enroll()
    const first = await post(eventsPOST, rvBatch, m.credential)
    expect(first.status).toBe(200)
    expect(await first.json()).toEqual({ inserted: 3, duplicates: 0, gaps: 0 })
    const again = await post(eventsPOST, rvBatch, m.credential)
    expect(await again.json()).toEqual({ inserted: 0, duplicates: 3, gaps: 0 })

    const m2 = await enroll("mbp-ocsf")
    const ocsf = await post(eventsPOST, ocsfBatch, m2.credential)
    expect(await ocsf.json()).toEqual({ inserted: 2, duplicates: 0, gaps: 0 })
    const { rows } = await db.query("select kind, decision, host from public.events where machine_id = $1 order by time", [m2.machineId])
    expect(rows).toEqual([
      { kind: "command.denied", decision: "denied", host: "claude" },
      { kind: "config.changed", decision: "info", host: null },
    ])
  })

  it("requires a live machine credential", async () => {
    expect((await post(eventsPOST, rvBatch)).status).toBe(401)
    expect((await post(eventsPOST, rvBatch, "rvc_mch_" + "C".repeat(43))).status).toBe(401)
    const m = await enroll()
    await db.query("update public.machines set revoked_at = now() where id = $1", [m.machineId])
    expect((await post(eventsPOST, rvBatch, m.credential)).status).toBe(401)
  })

  it("refuses non-JSON and oversized bodies", async () => {
    const m = await enroll()
    const res = await eventsPOST(
      new Request("http://localhost/api", {
        method: "POST",
        headers: { "content-type": "text/plain", authorization: `Bearer ${m.credential}` },
        body: "[]",
      }),
    )
    expect(res.status).toBe(415)
    const big = await eventsPOST(
      new Request("http://localhost/api", {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${m.credential}` },
        body: "[" + " ".repeat(9 * 1024 * 1024) + "]",
      }),
    )
    expect(big.status).toBe(413)
  })

  it("rate-limits enrollment per IP", async () => {
    let last = 0
    for (let i = 0; i < 31; i++) {
      last = (await post(enrollPOST, { token: "nope", name: "x" }, undefined, "203.0.113.9")).status
    }
    expect(last).toBe(429)
  })
})
