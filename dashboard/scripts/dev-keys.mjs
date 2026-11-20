// Prints local-only Supabase keys (HS256 JWTs for the anon and service roles)
// signed with the dev stack's JWT secret. Never use these outside localhost.
import crypto from "node:crypto"

const secret = process.argv[2]
if (!secret) {
  console.error("usage: node scripts/dev-keys.mjs <jwt-secret>")
  process.exit(2)
}
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url")
const sign = (payload) => {
  const head = b64({ alg: "HS256", typ: "JWT" })
  const body = b64(payload)
  const sig = crypto.createHmac("sha256", secret).update(`${head}.${body}`).digest("base64url")
  return `${head}.${body}.${sig}`
}
const exp = Math.floor(Date.now() / 1000) + 10 * 365 * 86400
console.log("NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321")
console.log(`NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=${sign({ role: "anon", iss: "rv-dev", exp })}`)
console.log(`SUPABASE_SECRET_KEY=${sign({ role: "service_role", iss: "rv-dev", exp })}`)
console.log(`DATABASE_URL=postgres://postgres@127.0.0.1:54322/postgres`)
