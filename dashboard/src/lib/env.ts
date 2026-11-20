import { z } from "zod"

// Validated once, on first use, so a missing variable fails with its name
// instead of an opaque error deep inside a Supabase call.

const publicSchema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z.url(),
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: z.string().min(20),
})

const serverSchema = publicSchema.extend({
  SUPABASE_SECRET_KEY: z.string().min(20),
  // Public origin of this app, used in enrollment responses and auth redirects.
  APP_URL: z.url(),
  // Shared secret Vercel Cron sends as a bearer token.
  CRON_SECRET: z.string().min(16).optional(),
})

function fail(error: z.ZodError): never {
  const names = error.issues.map((i) => i.path.join(".")).join(", ")
  throw new Error(`Missing or invalid environment variables: ${names}. See dashboard/README.md.`)
}

let publicEnv: z.infer<typeof publicSchema> | undefined
export function getPublicEnv() {
  if (!publicEnv) {
    // Referenced literally so Next.js inlines them into client bundles.
    const parsed = publicSchema.safeParse({
      NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    })
    if (!parsed.success) fail(parsed.error)
    publicEnv = parsed.data
  }
  return publicEnv
}

let serverEnv: z.infer<typeof serverSchema> | undefined
export function getServerEnv() {
  if (!serverEnv) {
    const parsed = serverSchema.safeParse({
      NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
      SUPABASE_SECRET_KEY: process.env.SUPABASE_SECRET_KEY,
      APP_URL: process.env.APP_URL,
      CRON_SECRET: process.env.CRON_SECRET || undefined,
    })
    if (!parsed.success) fail(parsed.error)
    serverEnv = parsed.data
  }
  return serverEnv
}
