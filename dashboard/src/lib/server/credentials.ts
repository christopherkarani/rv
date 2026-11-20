import crypto from "node:crypto"

// Enrollment tokens and machine credentials are 256-bit random secrets.
// Only their SHA-256 is stored; a fast hash is right for high-entropy tokens.

export const ENROLL_PREFIX = "rvc_enr_"
export const MACHINE_PREFIX = "rvc_mch_"
const TOKEN_RE = /^rvc_(enr|mch)_[A-Za-z0-9_-]{43}$/

export function newSecret(prefix: typeof ENROLL_PREFIX | typeof MACHINE_PREFIX) {
  return prefix + crypto.randomBytes(32).toString("base64url")
}

export function hashSecret(secret: string) {
  return crypto.createHash("sha256").update(secret, "utf8").digest("hex")
}

/** First characters shown in the UI so people can tell tokens apart. */
export function displayPrefix(secret: string) {
  return secret.slice(0, 14)
}

export function isWellFormed(secret: string, kind: "enr" | "mch") {
  const m = TOKEN_RE.exec(secret)
  return m !== null && m[1] === kind
}

export function bearer(request: Request): string | null {
  const header = request.headers.get("authorization")
  if (!header) return null
  const m = /^Bearer\s+(\S+)$/i.exec(header.trim())
  return m ? m[1] : null
}
