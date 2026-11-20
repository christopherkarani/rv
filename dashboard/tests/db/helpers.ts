import crypto from "node:crypto"
import pg from "pg"

export const DATABASE_URL = process.env.DATABASE_URL

export function pool() {
  return new pg.Pool({ connectionString: DATABASE_URL, max: 4 })
}

export const rid = () => crypto.randomBytes(4).toString("hex")

export async function createUser(db: pg.Pool, email = `user-${rid()}@example.test`) {
  const id = crypto.randomUUID()
  await db.query(
    `insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
     values ($1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', $2, now(), now(), now())`,
    [id, email],
  )
  return { id, email }
}

/** Run `fn` as a signed-in user, the way PostgREST does: role + JWT claims. */
export async function asUser<T>(db: pg.Pool, userId: string, fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
  const c = await db.connect()
  try {
    await c.query("begin")
    await c.query("set local role authenticated")
    await c.query("select set_config('request.jwt.claims', $1, true)", [
      JSON.stringify({ sub: userId, role: "authenticated" }),
    ])
    const out = await fn(c)
    await c.query("commit")
    return out
  } catch (e) {
    await c.query("rollback").catch(() => {})
    throw e
  } finally {
    c.release()
  }
}

export async function asService<T>(db: pg.Pool, fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
  const c = await db.connect()
  try {
    await c.query("begin")
    await c.query("set local role service_role")
    const out = await fn(c)
    await c.query("commit")
    return out
  } catch (e) {
    await c.query("rollback").catch(() => {})
    throw e
  } finally {
    c.release()
  }
}

export const sha256 = (s: string) => crypto.createHash("sha256").update(s).digest("hex")

export async function createOrgAs(db: pg.Pool, userId: string, name = "Org") {
  const slug = `org-${rid()}`
  const { rows } = await asUser(db, userId, (c) => c.query("select public.create_org($1, $2) as id", [name, slug]))
  return rows[0].id as string
}

export async function addMember(db: pg.Pool, orgId: string, userId: string, role: "owner" | "admin" | "viewer") {
  await db.query("insert into public.org_members (org_id, user_id, role) values ($1, $2, $3)", [orgId, userId, role])
}

export async function createToken(db: pg.Pool, orgId: string, opts: { expiresIn?: string; maxUses?: number } = {}) {
  const token = `rvc_enr_${rid()}${rid()}`
  await db.query(
    `insert into public.enrollment_tokens (org_id, token_hash, prefix, expires_at, max_uses)
     values ($1, $2, $3, now() + $4::interval, $5)`,
    [orgId, sha256(token), token.slice(0, 12), opts.expiresIn ?? "7 days", opts.maxUses ?? 100],
  )
  return token
}

export async function enroll(db: pg.Pool, token: string, name = `mbp-${rid()}`) {
  const credential = `rvc_mch_${rid()}${rid()}`
  const { rows } = await asService(db, (c) =>
    c.query("select * from public.enroll_machine($1, $2, $3, $4, $5, $6)", [
      sha256(token),
      sha256(credential),
      credential.slice(0, 12),
      name,
      "macos",
      "0.2.2",
    ]),
  )
  return { machineId: rows[0]?.machine_id as string | undefined, orgId: rows[0]?.org_id as string | undefined, credential }
}

export function ev(uid: string, extra: Record<string, unknown> = {}) {
  return {
    uid,
    time: new Date().toISOString(),
    kind: "command.denied",
    decision: "denied",
    subject: "core.git:reset-hard",
    host: "claude",
    tool: "Bash",
    reason: null,
    prev: null,
    chainHead: null,
    body: { kind: "command.denied" },
    ...extra,
  }
}
