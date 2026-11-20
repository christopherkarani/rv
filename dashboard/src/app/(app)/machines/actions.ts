"use server"

import { revalidatePath } from "next/cache"
import { z } from "zod"
import { requireRole } from "@/lib/session"
import { serverClient } from "@/lib/supabase/server"

export type ActionState = { ok?: boolean; error?: string }

const id = z.uuid()

export async function setTeam(_prev: ActionState, form: FormData): Promise<ActionState> {
  const session = await requireRole(["owner", "admin"])
  const machineId = id.safeParse(form.get("machineId"))
  const team = z.string().trim().max(64).safeParse(form.get("team") ?? "")
  if (!machineId.success || !team.success) return { error: "Invalid team name." }
  const supabase = await serverClient()
  const { data, error } = await supabase
    .from("machines")
    .update({ team: team.data || null })
    .eq("id", machineId.data)
    .eq("org_id", session.org.orgId)
    .select("id, name")
  if (error || !data?.length) return { error: "Could not update the team." }
  await supabase.from("admin_audit").insert({
    org_id: session.org.orgId,
    actor: session.userId,
    action: "machine.team_set",
    target: data[0].name,
    detail: { machine_id: machineId.data, team: team.data || null },
  })
  revalidatePath(`/machines/${machineId.data}`)
  return { ok: true }
}

export async function revokeMachine(_prev: ActionState, form: FormData): Promise<ActionState> {
  const session = await requireRole(["owner", "admin"])
  const machineId = id.safeParse(form.get("machineId"))
  if (!machineId.success) return { error: "Unknown machine." }
  const supabase = await serverClient()
  const { data, error } = await supabase
    .from("machines")
    .update({ revoked_at: new Date().toISOString() })
    .eq("id", machineId.data)
    .eq("org_id", session.org.orgId)
    .is("revoked_at", null)
    .select("id, name")
  if (error || !data?.length) return { error: "Could not revoke the credential." }
  await supabase.from("admin_audit").insert({
    org_id: session.org.orgId,
    actor: session.userId,
    action: "machine.revoked",
    target: data[0].name,
    detail: { machine_id: machineId.data },
  })
  revalidatePath(`/machines/${machineId.data}`)
  return { ok: true }
}
