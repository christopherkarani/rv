"use server"

import { cookies } from "next/headers"
import { revalidatePath } from "next/cache"
import { redirect } from "next/navigation"
import { z } from "zod"
import { RETENTION_LIMIT } from "@/lib/plans"
import { ENROLL_PREFIX, displayPrefix, hashSecret, newSecret } from "@/lib/server/credentials"
import { ORG_COOKIE, requireRole } from "@/lib/session"
import { adminClient } from "@/lib/supabase/admin"
import { serverClient } from "@/lib/supabase/server"

export type ActionState = { ok?: boolean; error?: string; message?: string; token?: string }

async function audit(orgId: string, actor: string, action: string, target: string | null, detail: Record<string, unknown> = {}) {
  const supabase = await serverClient()
  const { error } = await supabase.from("admin_audit").insert({ org_id: orgId, actor, action, target, detail })
  if (error) console.error("admin audit insert failed", action, error.message)
}

export async function updateOrg(_prev: ActionState, form: FormData): Promise<ActionState> {
  const s = await requireRole(["owner", "admin"])
  const parsed = z
    .object({ name: z.string().trim().min(1).max(100), retention: z.coerce.number().int().min(1) })
    .safeParse({ name: form.get("name"), retention: form.get("retention") })
  if (!parsed.success) return { error: "Enter a name and a retention of at least one day." }
  const max = RETENTION_LIMIT[s.org.plan] ?? 30
  if (parsed.data.retention > max) return { error: `Your plan keeps events for at most ${max} days.` }
  const supabase = await serverClient()
  const { error } = await supabase
    .from("orgs")
    .update({ name: parsed.data.name, retention_days: parsed.data.retention })
    .eq("id", s.org.orgId)
  if (error) return { error: "Could not save." }
  await audit(s.org.orgId, s.userId, "org.updated", parsed.data.name, { retention_days: parsed.data.retention })
  revalidatePath("/", "layout")
  return { ok: true, message: "Saved." }
}

export async function createToken(_prev: ActionState, form: FormData): Promise<ActionState> {
  const s = await requireRole(["owner", "admin"])
  const parsed = z
    .object({
      label: z.string().trim().max(64).optional(),
      days: z.coerce.number().int().min(1).max(90),
      maxUses: z.coerce.number().int().min(1).max(10000),
    })
    .safeParse({ label: form.get("label") || undefined, days: form.get("days"), maxUses: form.get("maxUses") })
  if (!parsed.success) return { error: "Expiry is 1–90 days and uses 1–10,000." }
  const token = newSecret(ENROLL_PREFIX)
  const supabase = await serverClient()
  const { error } = await supabase.from("enrollment_tokens").insert({
    org_id: s.org.orgId,
    token_hash: hashSecret(token),
    prefix: displayPrefix(token),
    label: parsed.data.label ?? null,
    created_by: s.userId,
    expires_at: new Date(Date.now() + parsed.data.days * 86_400_000).toISOString(),
    max_uses: parsed.data.maxUses,
  })
  if (error) {
    console.error("token insert failed", error.message)
    return { error: "Could not create the token." }
  }
  await audit(s.org.orgId, s.userId, "token.created", displayPrefix(token), { days: parsed.data.days, max_uses: parsed.data.maxUses })
  revalidatePath("/settings")
  return { ok: true, token }
}

export async function revokeToken(form: FormData) {
  const s = await requireRole(["owner", "admin"])
  const id = z.uuid().safeParse(form.get("id"))
  if (!id.success) return
  const supabase = await serverClient()
  const { data } = await supabase
    .from("enrollment_tokens")
    .update({ revoked_at: new Date().toISOString() })
    .eq("id", id.data)
    .eq("org_id", s.org.orgId)
    .is("revoked_at", null)
    .select("prefix")
  if (data?.length) await audit(s.org.orgId, s.userId, "token.revoked", data[0].prefix)
  revalidatePath("/settings")
}

export async function inviteMember(_prev: ActionState, form: FormData): Promise<ActionState> {
  const s = await requireRole(["owner", "admin"])
  const parsed = z
    .object({ email: z.email().max(320).transform((e) => e.toLowerCase()), role: z.enum(["admin", "viewer"]) })
    .safeParse({ email: String(form.get("email") ?? "").trim(), role: form.get("role") })
  if (!parsed.success) return { error: "Enter a valid email." }
  if (parsed.data.role === "admin" && s.org.role !== "owner") return { error: "Only owners can invite admins." }
  const supabase = await serverClient()
  const { error } = await supabase.from("org_invites").upsert(
    { org_id: s.org.orgId, email: parsed.data.email, role: parsed.data.role, invited_by: s.userId, accepted_at: null, expires_at: new Date(Date.now() + 14 * 86_400_000).toISOString() },
    { onConflict: "org_id,email" },
  )
  if (error) return { error: "Could not save the invitation." }
  await audit(s.org.orgId, s.userId, "member.invited", parsed.data.email, { role: parsed.data.role })
  revalidatePath("/settings")
  return { ok: true, message: `Invited ${parsed.data.email}. They join when they sign in with that email.` }
}

export async function cancelInvite(form: FormData) {
  const s = await requireRole(["owner", "admin"])
  const id = z.uuid().safeParse(form.get("id"))
  if (!id.success) return
  const supabase = await serverClient()
  const { data } = await supabase.from("org_invites").delete().eq("id", id.data).eq("org_id", s.org.orgId).select("email")
  if (data?.length) await audit(s.org.orgId, s.userId, "invite.cancelled", data[0].email)
  revalidatePath("/settings")
}

export async function changeRole(form: FormData) {
  const s = await requireRole(["owner"])
  const parsed = z.object({ userId: z.uuid(), role: z.enum(["owner", "admin", "viewer"]) }).safeParse({ userId: form.get("userId"), role: form.get("role") })
  if (!parsed.success) return
  const supabase = await serverClient()
  const { error } = await supabase.from("org_members").update({ role: parsed.data.role }).eq("org_id", s.org.orgId).eq("user_id", parsed.data.userId)
  if (!error) await audit(s.org.orgId, s.userId, "member.role_changed", parsed.data.userId, { role: parsed.data.role })
  revalidatePath("/settings")
}

export async function removeMember(form: FormData) {
  const s = await requireRole(["owner", "admin", "viewer"])
  const userId = z.uuid().safeParse(form.get("userId"))
  if (!userId.success) return
  const supabase = await serverClient()
  const { data } = await supabase.from("org_members").delete().eq("org_id", s.org.orgId).eq("user_id", userId.data).select("user_id")
  if (data?.length) await audit(s.org.orgId, s.userId, userId.data === s.userId ? "member.left" : "member.removed", userId.data)
  if (userId.data === s.userId) {
    ;(await cookies()).delete(ORG_COOKIE)
    redirect("/")
  }
  revalidatePath("/settings")
}

export async function deleteOrg(_prev: ActionState, form: FormData): Promise<ActionState> {
  const s = await requireRole(["owner"])
  if (String(form.get("confirm") ?? "").trim() !== s.org.slug) return { error: `Type ${s.org.slug} to confirm.` }
  // Owner checked above; the cascade removes machines, events, reports and policy.
  const { error } = await adminClient().from("orgs").delete().eq("id", s.org.orgId)
  if (error) {
    console.error("org delete failed", error.message)
    return { error: "Could not delete the organization." }
  }
  ;(await cookies()).delete(ORG_COOKIE)
  redirect("/")
}
