// Database tests against a real Postgres with the migrations applied
// (scripts/dev-stack.sh up, or CI's service container). They exercise
// row-level security the way PostgREST does: role + JWT claims.
import { afterAll, beforeAll, describe, expect, it } from "vitest"
import type pg from "pg"
import {
  DATABASE_URL,
  addMember,
  asService,
  asUser,
  createOrgAs,
  createToken,
  createUser,
  enroll,
  ev,
  pool,
} from "./helpers"

const run = DATABASE_URL ? describe : describe.skip

run("schema and row-level security", () => {
  let db: pg.Pool
  beforeAll(() => {
    db = pool()
  })
  afterAll(async () => {
    await db.end()
  })

  it("create_org makes the caller owner and hides the org from others", async () => {
    const alice = await createUser(db)
    const bob = await createUser(db)
    const org = await createOrgAs(db, alice.id, "Alice Co")

    const mine = await asUser(db, alice.id, (c) => c.query("select id, name from public.orgs"))
    expect(mine.rows.map((r) => r.id)).toContain(org)
    const role = await asUser(db, alice.id, (c) =>
      c.query("select role from public.org_members where org_id = $1 and user_id = $2", [org, alice.id]),
    )
    expect(role.rows[0].role).toBe("owner")

    const theirs = await asUser(db, bob.id, (c) => c.query("select id from public.orgs where id = $1", [org]))
    expect(theirs.rowCount).toBe(0)
  })

  it("keeps machines, events and reports inside their org", async () => {
    const alice = await createUser(db)
    const bob = await createUser(db)
    const orgA = await createOrgAs(db, alice.id)
    await createOrgAs(db, bob.id)
    const { machineId } = await enroll(db, await createToken(db, orgA))
    await asService(db, (c) => c.query("select * from public.ingest_events($1, $2)", [machineId, JSON.stringify([ev("e1")])]))

    for (const table of ["machines", "events", "reports", "chain_findings"]) {
      const { rows } = await asUser(db, bob.id, (c) => c.query(`select org_id from public.${table} where org_id = $1`, [orgA]))
      expect(rows, table).toHaveLength(0)
    }
    const visible = await asUser(db, alice.id, (c) => c.query("select uid from public.events where org_id = $1", [orgA]))
    expect(visible.rows.map((r) => r.uid)).toEqual(["e1"])
  })

  it("never lets a signed-in user read a machine credential hash", async () => {
    const alice = await createUser(db)
    const org = await createOrgAs(db, alice.id)
    await enroll(db, await createToken(db, org))
    await expect(
      asUser(db, alice.id, (c) => c.query("select credential_hash from public.machines where org_id = $1", [org])),
    ).rejects.toThrow(/permission denied/)
  })

  it("lets admins set a team but not viewers, and nobody rewrites ingest fields", async () => {
    const owner = await createUser(db)
    const admin = await createUser(db)
    const viewer = await createUser(db)
    const org = await createOrgAs(db, owner.id)
    await addMember(db, org, admin.id, "admin")
    await addMember(db, org, viewer.id, "viewer")
    const { machineId } = await enroll(db, await createToken(db, org))

    const asViewer = await asUser(db, viewer.id, (c) =>
      c.query("update public.machines set team = 'Web' where id = $1", [machineId]),
    )
    expect(asViewer.rowCount).toBe(0)
    const asAdmin = await asUser(db, admin.id, (c) =>
      c.query("update public.machines set team = 'Web' where id = $1", [machineId]),
    )
    expect(asAdmin.rowCount).toBe(1)
    await expect(
      asUser(db, owner.id, (c) => c.query("update public.machines set compliant = true where id = $1", [machineId])),
    ).rejects.toThrow(/permission denied/)
  })

  it("hides enrollment tokens and the admin log from viewers", async () => {
    const owner = await createUser(db)
    const viewer = await createUser(db)
    const org = await createOrgAs(db, owner.id)
    await addMember(db, org, viewer.id, "viewer")
    await createToken(db, org)
    const tokens = await asUser(db, viewer.id, (c) => c.query("select id from public.enrollment_tokens where org_id = $1", [org]))
    expect(tokens.rowCount).toBe(0)
    const log = await asUser(db, viewer.id, (c) => c.query("select id from public.admin_audit where org_id = $1", [org]))
    expect(log.rowCount).toBe(0)
    const ownerLog = await asUser(db, owner.id, (c) => c.query("select action from public.admin_audit where org_id = $1", [org]))
    expect(ownerLog.rows.map((r) => r.action)).toContain("org.created")
  })

  it("refuses to remove or demote the last owner", async () => {
    const owner = await createUser(db)
    const org = await createOrgAs(db, owner.id)
    await expect(
      asUser(db, owner.id, (c) => c.query("delete from public.org_members where org_id = $1 and user_id = $2", [org, owner.id])),
    ).rejects.toThrow(/at least one owner/)
    await expect(
      asUser(db, owner.id, (c) =>
        c.query("update public.org_members set role = 'admin' where org_id = $1 and user_id = $2", [org, owner.id]),
      ),
    ).rejects.toThrow(/at least one owner/)
  })

  it("does not let signed-in users call machine-facing functions", async () => {
    const alice = await createUser(db)
    const org = await createOrgAs(db, alice.id)
    const { machineId } = await enroll(db, await createToken(db, org))
    for (const sql of [
      ["select public.ingest_events($1, '[]'::jsonb)", [machineId]],
      ["select public.ingest_report($1, '{}'::jsonb, true)", [machineId]],
      ["select public.enroll_machine('a', 'b', 'c', 'd', 'e', 'f')", []],
      ["select public.prune_expired()", []],
    ] as const) {
      await expect(asUser(db, alice.id, (c) => c.query(sql[0], [...sql[1]]))).rejects.toThrow(/permission denied/)
    }
  })

  it("enrolls only with a live token and counts uses", async () => {
    const alice = await createUser(db)
    const org = await createOrgAs(db, alice.id)
    const token = await createToken(db, org, { maxUses: 1 })
    const first = await enroll(db, token)
    expect(first.orgId).toBe(org)
    const second = await enroll(db, token)
    expect(second.machineId).toBeUndefined()

    const expired = await createToken(db, org, { expiresIn: "-1 minute" })
    expect((await enroll(db, expired)).machineId).toBeUndefined()

    const revoked = await createToken(db, org)
    await db.query("update public.enrollment_tokens set revoked_at = now() where org_id = $1 and uses = 0 and revoked_at is null", [org])
    expect((await enroll(db, revoked)).machineId).toBeUndefined()
  })

  it("ingests events idempotently and flags chain gaps", async () => {
    const alice = await createUser(db)
    const org = await createOrgAs(db, alice.id)
    const { machineId } = await enroll(db, await createToken(db, org))
    const call = (events: unknown[]) =>
      asService(db, (c) => c.query("select * from public.ingest_events($1, $2)", [machineId, JSON.stringify(events)]))

    const a = await call([
      ev("a", { prev: null, chainHead: "h1" }),
      ev("b", { prev: "h1", chainHead: "h2" }),
      ev("blk", { prev: null, chainHead: null }),
    ])
    expect(a.rows[0]).toMatchObject({ inserted: 3, duplicates: 0, gaps: 0 })

    // At-least-once resend plus one new event continuing the chain.
    const b = await call([ev("b", { prev: "h1", chainHead: "h2" }), ev("c", { prev: "h2", chainHead: "h3" })])
    expect(b.rows[0]).toMatchObject({ inserted: 1, duplicates: 1, gaps: 0 })

    let m = await db.query("select chain_head, chain_status from public.machines where id = $1", [machineId])
    expect(m.rows[0]).toEqual({ chain_head: "h3", chain_status: "ok" })

    // A rewritten log: the next event does not continue h3.
    const c = await call([ev("d", { prev: "hX", chainHead: "h4" })])
    expect(c.rows[0]).toMatchObject({ inserted: 1, gaps: 1 })
    m = await db.query("select chain_head, chain_status from public.machines where id = $1", [machineId])
    expect(m.rows[0]).toEqual({ chain_head: "h4", chain_status: "gap" })
    const f = await db.query("select kind, expected, got from public.chain_findings where machine_id = $1", [machineId])
    expect(f.rows).toEqual([{ kind: "gap", expected: "h3", got: "hX" }])
  })

  it("drops the blocks.jsonl copy of a deny once the chained copy arrives in a later batch", async () => {
    const alice = await createUser(db)
    const org = await createOrgAs(db, alice.id)
    const { machineId } = await enroll(db, await createToken(db, org))
    const t = "2026-11-20T10:00:00.250Z"
    const call = (events: unknown[]) =>
      asService(db, (c) => c.query("select * from public.ingest_events($1, $2)", [machineId, JSON.stringify(events)]))
    await call([ev("blk-1", { time: t, source: "blocks.jsonl" })])
    await call([ev("aud-1", { time: "2026-11-20T10:00:00.900Z", source: "audit.jsonl", chainHead: "h1" })])
    const left = await db.query("select uid from public.events where machine_id = $1", [machineId])
    expect(left.rows.map((r) => r.uid)).toEqual(["aud-1"])
  })

  it("de-duplicates a uid repeated inside one batch", async () => {
    const alice = await createUser(db)
    const org = await createOrgAs(db, alice.id)
    const { machineId } = await enroll(db, await createToken(db, org))
    const r = await asService(db, (c) =>
      c.query("select * from public.ingest_events($1, $2)", [machineId, JSON.stringify([ev("x"), ev("x")])]),
    )
    expect(r.rows[0]).toMatchObject({ inserted: 1, duplicates: 1 })
  })

  it("stores reports and records a broken chain once", async () => {
    const alice = await createUser(db)
    const org = await createOrgAs(db, alice.id)
    const { machineId } = await enroll(db, await createToken(db, org))
    const report = (intact: boolean) => ({
      schema: "rv.report.v1",
      generatedAt: new Date().toISOString(),
      rv: { version: "0.2.2", platform: "macos" },
      host: { name: "mbp-test", user: "test", uid: 501 },
      audit: { chainIntact: intact },
    })
    for (const intact of [false, false]) {
      await asService(db, (c) => c.query("select public.ingest_report($1, $2, $3)", [machineId, report(intact), false]))
    }
    const m = await db.query("select hostname, rv_version, chain_status, compliant from public.machines where id = $1", [machineId])
    expect(m.rows[0]).toEqual({ hostname: "mbp-test", rv_version: "0.2.2", chain_status: "broken", compliant: false })
    const f = await db.query("select count(*)::int as n from public.chain_findings where machine_id = $1 and kind = 'broken'", [machineId])
    expect(f.rows[0].n).toBe(1)
  })

  it("refuses ingest for a revoked machine", async () => {
    const alice = await createUser(db)
    const org = await createOrgAs(db, alice.id)
    const { machineId } = await enroll(db, await createToken(db, org))
    await db.query("update public.machines set revoked_at = now() where id = $1", [machineId])
    await expect(
      asService(db, (c) => c.query("select * from public.ingest_events($1, '[]'::jsonb)", [machineId])),
    ).rejects.toThrow(/unknown machine/)
  })

  it("joins pending invites addressed to the signed-in email", async () => {
    const owner = await createUser(db)
    const org = await createOrgAs(db, owner.id)
    const invitee = await createUser(db)
    await asUser(db, owner.id, (c) =>
      c.query("insert into public.org_invites (org_id, email, role, invited_by) values ($1, $2, 'admin', $3)", [
        org,
        invitee.email,
        owner.id,
      ]),
    )
    const joined = await asUser(db, invitee.id, (c) => c.query("select public.accept_invites() as n"))
    expect(joined.rows[0].n).toBe(1)
    const role = await db.query("select role from public.org_members where org_id = $1 and user_id = $2", [org, invitee.id])
    expect(role.rows[0].role).toBe("admin")
  })

  it("shows member emails only to fellow members", async () => {
    const owner = await createUser(db)
    const outsider = await createUser(db)
    const org = await createOrgAs(db, owner.id)
    const mine = await asUser(db, owner.id, (c) => c.query("select email, role from public.org_member_list($1)", [org]))
    expect(mine.rows).toEqual([{ email: owner.email, role: "owner" }])
    const theirs = await asUser(db, outsider.id, (c) => c.query("select email from public.org_member_list($1)", [org]))
    expect(theirs.rowCount).toBe(0)
    const log = await asUser(db, outsider.id, (c) => c.query("select id from public.org_admin_audit($1, 10)", [org]))
    expect(log.rowCount).toBe(0)
  })

  it("only lets admins invite viewers, not admins", async () => {
    const owner = await createUser(db)
    const admin = await createUser(db)
    const org = await createOrgAs(db, owner.id)
    await addMember(db, org, admin.id, "admin")
    await expect(
      asUser(db, admin.id, (c) =>
        c.query("insert into public.org_invites (org_id, email, role, invited_by) values ($1, 'x@example.test', 'admin', $2)", [
          org,
          admin.id,
        ]),
      ),
    ).rejects.toThrow(/row-level security/)
  })

  it("aggregates activity under RLS", async () => {
    const alice = await createUser(db)
    const bob = await createUser(db)
    const org = await createOrgAs(db, alice.id)
    const { machineId } = await enroll(db, await createToken(db, org))
    await asService(db, (c) =>
      c.query("select * from public.ingest_events($1, $2)", [
        machineId,
        JSON.stringify([ev("1"), ev("2"), ev("3", { kind: "command.observed", decision: "info", body: { detail: { would_be: "deny" } } })]),
      ]),
    )
    const mine = await asUser(db, alice.id, (c) => c.query("select sum(denied)::int d, sum(observed)::int o from public.org_daily_activity($1, 14)", [org]))
    expect(mine.rows[0]).toEqual({ d: 2, o: 1 })
    const theirs = await asUser(db, bob.id, (c) => c.query("select sum(denied)::int d from public.org_daily_activity($1, 14)", [org]))
    expect(theirs.rows[0].d).toBe(0)
    const top = await asUser(db, alice.id, (c) =>
      c.query("select subject, hits::int, would_deny::int from public.org_top_rules($1, 'command.observed', now() - interval '1 day')", [org]),
    )
    expect(top.rows).toEqual([{ subject: "core.git:reset-hard", hits: 1, would_deny: 1 }])
  })

  it("prunes events past retention and keeps the latest report", async () => {
    const alice = await createUser(db)
    const org = await createOrgAs(db, alice.id)
    await db.query("update public.orgs set retention_days = 1 where id = $1", [org])
    const { machineId } = await enroll(db, await createToken(db, org))
    await asService(db, (c) => c.query("select * from public.ingest_events($1, $2)", [machineId, JSON.stringify([ev("old"), ev("new")])]))
    await db.query("update public.events set received_at = now() - interval '2 days' where machine_id = $1 and uid = 'old'", [machineId])
    await asService(db, (c) => c.query("select public.ingest_report($1, '{}'::jsonb, true)", [machineId]))
    await db.query("update public.reports set received_at = now() - interval '5 days' where machine_id = $1", [machineId])
    await asService(db, (c) => c.query("select * from public.prune_expired()"))
    const left = await db.query("select uid from public.events where machine_id = $1", [machineId])
    expect(left.rows.map((r) => r.uid)).toEqual(["new"])
    const reports = await db.query("select count(*)::int n from public.reports where machine_id = $1", [machineId])
    expect(reports.rows[0].n).toBe(1)
  })

  it("rate-limits per key and window", async () => {
    const key = `test-${Math.random()}`
    const results: boolean[] = []
    for (let i = 0; i < 4; i++) {
      const { rows } = await asService(db, (c) => c.query("select public.take_rate_limit($1, 3, 60) as ok", [key]))
      results.push(rows[0].ok)
    }
    expect(results).toEqual([true, true, true, false])
  })
})
