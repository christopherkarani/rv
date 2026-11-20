import "server-only"
import { createClient, type SupabaseClient } from "@supabase/supabase-js"
import { getServerEnv } from "@/lib/env"

// Service-role client: bypasses row-level security. Use only in route
// handlers and server actions that have already decided the caller may act.
// Untyped like the user client; generate types with `supabase gen types` to tighten.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let client: SupabaseClient<any> | undefined

export function adminClient() {
  if (!client) {
    const env = getServerEnv()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    client = createClient<any>(env.NEXT_PUBLIC_SUPABASE_URL, env.SUPABASE_SECRET_KEY, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    })
  }
  return client
}
