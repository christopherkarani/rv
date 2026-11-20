import { NextResponse, type NextRequest } from "next/server"
import { safeNext } from "@/lib/safe-next"
import { serverClient } from "@/lib/supabase/server"

// Magic links and OAuth both land here with a PKCE `code`.
export async function GET(request: NextRequest) {
  const url = request.nextUrl
  const code = url.searchParams.get("code")
  const next = safeNext(url.searchParams.get("next"))
  const fail = new URL("/login?error=link", url.origin)

  if (!code) return NextResponse.redirect(fail)
  const supabase = await serverClient()
  const { error } = await supabase.auth.exchangeCodeForSession(code)
  if (error) {
    console.error("code exchange failed", error.message)
    return NextResponse.redirect(fail)
  }
  // Join any orgs this email was invited to.
  const { error: inviteError } = await supabase.rpc("accept_invites")
  if (inviteError) console.error("accept_invites failed", inviteError.message)
  return NextResponse.redirect(new URL(next, url.origin))
}
