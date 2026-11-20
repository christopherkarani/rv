"use server"

import crypto from "node:crypto"
import { revalidatePath } from "next/cache"
import { z } from "zod"
import { MAX_POLICY_BYTES, PolicyError, parsePublicKey, summarize, validatePolicy, verifySignature } from "@/lib/policy"
import { currentPolicySerial, signingKeys } from "@/lib/queries"
import { requireRole } from "@/lib/session"
import { adminClient } from "@/lib/supabase/admin"
import { serverClient } from "@/lib/supabase/server"

export type ActionState = { ok?: boolean; error?: string; message?: string }

async function fileText(value: FormDataEntryValue | null, max: number): Promise<{ bytes: Buffer; text: string } | string> {
  if (!(value instanceof File) || value.size === 0) return "missing file"
  if (value.size > max) return "file is too large"
  const bytes = Buffer.from(await value.arrayBuffer())
  try {
    return { bytes, text: new TextDecoder("utf-8", { fatal: true }).decode(bytes) }
  } catch {
    return "file is not UTF-8 text"
  }
}

export async function uploadPolicy(_prev: ActionState, form: FormData): Promise<ActionState> {
  const session = await requireRole(["owner", "admin"])
  const policy = await fileText(form.get("policy"), MAX_POLICY_BYTES)
  if (typeof policy === "string") return { error: `policy.json: ${policy}` }
  const sig = await fileText(form.get("signature"), 4096)
  if (typeof sig === "string") return { error: `policy.json.sig: ${sig}` }

  let summary
  try {
    summary = validatePolicy(policy.text)
  } catch (e) {
    if (e instanceof PolicyError) return { error: e.message }
    throw e
  }
  const keys = await signingKeys(session.org.orgId)
  if (keys.length === 0) return { error: "Pin your organization's public key below before uploading a policy." }
  const which = verifySignature(policy.bytes, sig.text, keys.map((k) => k.public_key))
  if (which < 0) return { error: "The signature does not verify against any pinned key. Sign the exact file you upload." }
  const current = await currentPolicySerial(session.org.orgId)
  if (current != null && summary.serial <= current) {
    return { error: `Serial ${summary.serial} is not newer than ${current}. Machines refuse a serial they have already passed.` }
  }

  const sha256 = crypto.createHash("sha256").update(policy.bytes).digest("hex")
  const admin = adminClient()
  const { error } = await admin.from("policy_revisions").insert({
    org_id: session.org.orgId,
    serial: summary.serial,
    policy_text: policy.text,
    policy_sha256: sha256,
    signature: sig.text.trim(),
    signing_key_id: keys[which].id,
    summary: summarize(summary),
    uploaded_by: session.userId,
  })
  if (error) {
    if (error.code === "23505") return { error: `Serial ${summary.serial} was already uploaded.` }
    console.error("policy insert failed", error.message)
    return { error: "Could not store the policy. Try again." }
  }
  await admin.from("admin_audit").insert({
    org_id: session.org.orgId,
    actor: session.userId,
    action: "policy.uploaded",
    target: `serial ${summary.serial}`,
    detail: { sha256, key: keys[which].label ?? keys[which].public_key.slice(0, 12) },
  })
  revalidatePath("/policy")
  return { ok: true, message: `Serial ${summary.serial} verified and stored. Push policy.json, policy.json.sig and org-key.pub with your MDM.` }
}

const keySchema = z.object({ publicKey: z.string().trim(), label: z.string().trim().max(64).optional() })

export async function addSigningKey(_prev: ActionState, form: FormData): Promise<ActionState> {
  const session = await requireRole(["owner"])
  const parsed = keySchema.safeParse({ publicKey: form.get("publicKey"), label: form.get("label") || undefined })
  if (!parsed.success || !parsePublicKey(parsed.data.publicKey)) {
    return { error: "Paste one base64 Ed25519 public key, as printed by rv managed keygen." }
  }
  const supabase = await serverClient()
  const { error } = await supabase.from("org_signing_keys").insert({
    org_id: session.org.orgId,
    public_key: parsed.data.publicKey,
    label: parsed.data.label ?? null,
    added_by: session.userId,
  })
  if (error) return { error: error.code === "23505" ? "That key is already pinned." : "Could not pin the key." }
  await supabase.from("admin_audit").insert({
    org_id: session.org.orgId,
    actor: session.userId,
    action: "signing_key.added",
    target: parsed.data.label ?? parsed.data.publicKey.slice(0, 12),
  })
  revalidatePath("/policy")
  return { ok: true }
}

export async function removeSigningKey(form: FormData) {
  const session = await requireRole(["owner"])
  const id = z.uuid().safeParse(form.get("id"))
  if (!id.success) return
  const supabase = await serverClient()
  const { data } = await supabase.from("org_signing_keys").delete().eq("id", id.data).eq("org_id", session.org.orgId).select("public_key, label")
  if (data?.length) {
    await supabase.from("admin_audit").insert({
      org_id: session.org.orgId,
      actor: session.userId,
      action: "signing_key.removed",
      target: data[0].label ?? String(data[0].public_key).slice(0, 12),
    })
  }
  revalidatePath("/policy")
}
