"use server"

import { redirect } from "next/navigation"
import { z } from "zod"
import { getServerEnv } from "@/lib/env"
import { safeNext } from "@/lib/safe-next"
import { serverClient } from "@/lib/supabase/server"

export type LoginState = { status: "idle" | "sent" | "error"; message?: string; email?: string }

function callbackUrl(next: string) {
  const base = getServerEnv().APP_URL.replace(/\/$/, "")
  return `${base}/auth/callback?next=${encodeURIComponent(safeNext(next))}`
}

export async function sendMagicLink(_prev: LoginState, form: FormData): Promise<LoginState> {
  const parsed = z.email().max(320).safeParse(String(form.get("email") ?? "").trim().toLowerCase())
  if (!parsed.success) return { status: "error", message: "Enter a valid email address." }
  const supabase = await serverClient()
  const { error } = await supabase.auth.signInWithOtp({
    email: parsed.data,
    options: { emailRedirectTo: callbackUrl(String(form.get("next") ?? "/")), shouldCreateUser: true },
  })
  if (error) {
    console.error("magic link failed", error.message)
    return { status: "error", message: error.status === 429 ? "Too many attempts. Wait a minute and try again." : "Could not send the link. Try again." }
  }
  return { status: "sent", email: parsed.data }
}

export async function signInWithGitHub(form: FormData) {
  const supabase = await serverClient()
  const { data, error } = await supabase.auth.signInWithOAuth({
    provider: "github",
    options: { redirectTo: callbackUrl(String(form.get("next") ?? "/")) },
  })
  if (error || !data.url) redirect("/login?error=oauth")
  redirect(data.url)
}

export async function signOut() {
  const supabase = await serverClient()
  await supabase.auth.signOut()
  redirect("/login")
}
