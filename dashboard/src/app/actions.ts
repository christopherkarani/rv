"use server"

import { cookies } from "next/headers"
import { redirect } from "next/navigation"
import { z } from "zod"
import { ORG_COOKIE, getSession } from "@/lib/session"
import { serverClient } from "@/lib/supabase/server"

export async function switchOrg(orgId: string) {
  const session = await getSession()
  if (!session.orgs.some((o) => o.orgId === orgId)) return
  ;(await cookies()).set(ORG_COOKIE, orgId, { httpOnly: true, sameSite: "lax", secure: true, path: "/", maxAge: 60 * 60 * 24 * 365 })
  redirect("/")
}

const orgSchema = z.object({
  name: z.string().trim().min(1, "Enter a name").max(100),
  slug: z
    .string()
    .trim()
    .toLowerCase()
    .regex(/^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$/, "3–40 lowercase letters, digits or dashes"),
})

export type CreateOrgState = { error?: string }

export async function createOrg(_prev: CreateOrgState, form: FormData): Promise<CreateOrgState> {
  const parsed = orgSchema.safeParse({ name: form.get("name"), slug: form.get("slug") })
  if (!parsed.success) return { error: parsed.error.issues[0]?.message }
  const supabase = await serverClient()
  const { data, error } = await supabase.rpc("create_org", { p_name: parsed.data.name, p_slug: parsed.data.slug })
  if (error) {
    if (error.code === "23505") return { error: "That URL is taken. Pick another." }
    if (error.message.includes("too many")) return { error: "You already own the maximum of 10 organizations." }
    console.error("create_org failed", error.message)
    return { error: "Could not create the organization. Try again." }
  }
  ;(await cookies()).set(ORG_COOKIE, String(data), { httpOnly: true, sameSite: "lax", secure: true, path: "/", maxAge: 60 * 60 * 24 * 365 })
  redirect("/settings?welcome=1")
}
