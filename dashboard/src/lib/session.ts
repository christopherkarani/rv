import "server-only"
import { cache } from "react"
import { cookies } from "next/headers"
import { redirect } from "next/navigation"
import { serverClient } from "@/lib/supabase/server"
import type { Role } from "@/lib/vocab"

export const ORG_COOKIE = "rv_org"

export type Membership = { orgId: string; name: string; slug: string; plan: string; role: Role }
export type Session = {
  userId: string
  email: string | null
  orgs: Membership[]
  org: Membership
}

/** The signed-in user and their current org, once per request. */
export const getSession = cache(async (): Promise<Session> => {
  const supabase = await serverClient()
  const { data: auth } = await supabase.auth.getUser()
  if (!auth.user) redirect("/login")

  const { data, error } = await supabase
    .from("org_members")
    .select("role, orgs ( id, name, slug, plan )")
    .eq("user_id", auth.user.id)
  if (error) throw new Error(`could not load memberships: ${error.message}`)

  const orgs: Membership[] = (data ?? [])
    .map((row) => {
      const o = (Array.isArray(row.orgs) ? row.orgs[0] : row.orgs) as { id: string; name: string; slug: string; plan: string } | null
      return o ? { orgId: o.id, name: o.name, slug: o.slug, plan: o.plan, role: row.role as Role } : null
    })
    .filter((m): m is Membership => m !== null)
    .sort((a, b) => a.name.localeCompare(b.name))

  if (orgs.length === 0) redirect("/onboarding")
  const wanted = (await cookies()).get(ORG_COOKIE)?.value
  const org = orgs.find((o) => o.orgId === wanted) ?? orgs[0]
  return { userId: auth.user.id, email: auth.user.email ?? null, orgs, org }
})

/** For server actions: the session plus a guard on the caller's role. */
export async function requireRole(roles: Role[]) {
  const session = await getSession()
  if (!roles.includes(session.org.role)) {
    throw new Error("You don't have permission to do that in this organization.")
  }
  return session
}

/**
 * The current time for this request. Server Components here render once per
 * request (after reading cookies), so reading the clock is intended; this
 * keeps that decision in one place for the React compiler's purity rule.
 */
export function requestTime() {
  return Date.now()
}
