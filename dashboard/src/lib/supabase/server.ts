import "server-only"
import { cookies } from "next/headers"
import { connection } from "next/server"
import { createServerClient } from "@supabase/ssr"
import { getPublicEnv } from "@/lib/env"

// Per-request client acting as the signed-in user; row-level security applies.
export async function serverClient() {
  // Read cookies first: it marks the render dynamic before env is touched,
  // so a build without secrets can still prerender static shells. Then wait
  // for the real request: Supabase reads the clock and user data must never
  // be part of a prefetch or prerender.
  const store = await cookies()
  await connection()
  const env = getPublicEnv()
  return createServerClient(env.NEXT_PUBLIC_SUPABASE_URL, env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, {
    cookies: {
      getAll: () => store.getAll(),
      setAll: (list) => {
        try {
          for (const { name, value, options } of list) store.set(name, value, options)
        } catch {
          // Called from a Server Component, where cookies are read-only.
          // proxy.ts refreshes the session, so this is safe to ignore.
        }
      },
    },
  })
}
