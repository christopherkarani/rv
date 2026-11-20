import crypto from "node:crypto"
import { SECRET_SOURCES } from "@/lib/vocab"

// Server-side checks for an uploaded organization policy bundle, matching
// rv's own rules (Sources/RVPolicy/ManagedPolicy.swift):
//   - policy.json: closed key sets per object, version 1, restrict-only values
//   - policy.json.sig: Ed25519 over the exact policy bytes, base64 text
//   - org-key.pub: base64 raw 32-byte Ed25519 public keys

export const MAX_POLICY_BYTES = 256 * 1024
const PACK_ID = /^[a-z0-9_]+(\.[a-z0-9_]+)*$/
const DECISIONS = ["allow", "ask", "deny"] as const

export type PolicySummary = {
  organization: string | null
  serial: number
  requirePacks: string[]
  strict: boolean
  mcpBlocked: number
  mcpRules: number
  mcpDefault: string
  requireSandbox: boolean
  allowedSources: string[] | null
  auditForward: string | null
}

type Json = null | boolean | number | string | Json[] | { [k: string]: Json }
type Obj = { [k: string]: Json }

class PolicyError extends Error {}

const isObj = (v: Json | undefined): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v)

function keys(o: Obj, allowed: string[], context: string) {
  for (const k of Object.keys(o)) {
    if (!allowed.includes(k)) throw new PolicyError(`unknown key "${k}" in ${context}`)
  }
}
function strings(v: Json | undefined, name: string): string[] {
  if (v === undefined) return []
  if (!Array.isArray(v) || v.some((x) => typeof x !== "string")) throw new PolicyError(`"${name}" must be an array of strings`)
  return v as string[]
}
function bool(v: Json | undefined, name: string): boolean | undefined {
  if (v === undefined) return undefined
  if (typeof v !== "boolean") throw new PolicyError(`"${name}" must be true or false`)
  return v
}
function optString(v: Json | undefined, name: string): string | undefined {
  if (v === undefined) return undefined
  if (typeof v !== "string") throw new PolicyError(`"${name}" must be a string`)
  return v
}

/** Validates policy.json text. Returns a summary or throws PolicyError with rv-style wording. */
export function validatePolicy(text: string): PolicySummary {
  if (Buffer.byteLength(text, "utf8") > MAX_POLICY_BYTES) throw new PolicyError("policy.json is larger than 256 KiB")
  let root: Json
  try {
    root = JSON.parse(text) as Json
  } catch {
    throw new PolicyError("policy.json is invalid")
  }
  if (!isObj(root)) throw new PolicyError("policy.json is not a JSON object")
  keys(root, ["version", "organization", "serial", "mcp", "secrets", "audit", "gate"], "policy")
  if (root.version !== 1) throw new PolicyError('policy "version" must be 1')
  const organization = optString(root.organization, "organization") ?? null

  // rv reads serial from its source spelling; require a plain non-negative integer.
  const serialMatch = /"serial"\s*:\s*(-?[0-9][0-9eE.+-]*)/.exec(text)
  if (root.serial === undefined) throw new PolicyError('"serial" is required so machines can refuse rollbacks')
  if (!serialMatch || !/^[0-9]+$/.test(serialMatch[1]) || !Number.isSafeInteger(root.serial)) {
    throw new PolicyError('"serial" must be a non-negative integer')
  }
  const serial = root.serial as number

  let mcpBlocked = 0
  let mcpRules = 0
  let mcpDefault = "allow"
  let requireSandbox = false
  if (root.mcp !== undefined) {
    if (!isObj(root.mcp)) throw new PolicyError('"mcp" must be an object')
    const mcp = root.mcp
    keys(mcp, ["blocked", "allowDirect", "requireSandbox", "deny", "ask", "allow", "defaultDecision"], "mcp")
    mcpBlocked = strings(mcp.blocked, "mcp.blocked").length
    bool(mcp.allowDirect, "mcp.allowDirect")
    requireSandbox = bool(mcp.requireSandbox, "mcp.requireSandbox") ?? false
    for (const d of DECISIONS) {
      const list = mcp[d]
      if (list === undefined) continue
      if (!Array.isArray(list) || list.some((x) => typeof x !== "string" && !isObj(x))) {
        throw new PolicyError(`"mcp.${d}" must be an array of globs or rule objects`)
      }
      mcpRules += list.length
    }
    const dd = optString(mcp.defaultDecision, "mcp.defaultDecision")
    if (dd !== undefined) {
      if (!(DECISIONS as readonly string[]).includes(dd)) throw new PolicyError('"mcp.defaultDecision" must be allow, ask, or deny')
      mcpDefault = dd
    }
  }

  let allowedSources: string[] | null = null
  if (root.secrets !== undefined) {
    if (!isObj(root.secrets)) throw new PolicyError('"secrets" must be an object')
    keys(root.secrets, ["allowedSources", "allowEnvironmentDelivery"], "secrets")
    if (root.secrets.allowedSources !== undefined) {
      allowedSources = strings(root.secrets.allowedSources, "secrets.allowedSources")
      for (const s of allowedSources) {
        if (!(SECRET_SOURCES as readonly string[]).includes(s)) throw new PolicyError(`unknown secret source "${s}" in secrets.allowedSources`)
      }
    }
    bool(root.secrets.allowEnvironmentDelivery, "secrets.allowEnvironmentDelivery")
  }

  let requirePacks: string[] = []
  let strict = false
  if (root.gate !== undefined) {
    if (!isObj(root.gate)) throw new PolicyError('"gate" must be an object')
    keys(root.gate, ["requirePacks", "safety"], "gate")
    requirePacks = strings(root.gate.requirePacks, "gate.requirePacks")
    for (const id of requirePacks) if (!PACK_ID.test(id)) throw new PolicyError(`invalid pack id "${id}" in gate.requirePacks`)
    const safety = optString(root.gate.safety, "gate.safety")
    if (safety !== undefined && safety !== "strict") throw new PolicyError('"gate.safety" may only be "strict"')
    strict = safety === "strict"
  }

  let auditForward: string | null = null
  if (root.audit !== undefined) {
    if (!isObj(root.audit)) throw new PolicyError('"audit" must be an object')
    keys(root.audit, ["forward"], "audit")
    if (root.audit.forward !== undefined) {
      const f = root.audit.forward
      if (!isObj(f)) throw new PolicyError('"audit.forward" must be an object')
      keys(f, ["url", "headers"], "audit.forward")
      auditForward = optString(f.url, "audit.forward.url") ?? null
      if (!auditForward) throw new PolicyError('"audit.forward.url" is required')
      if (f.headers !== undefined) {
        if (!isObj(f.headers)) throw new PolicyError('"audit.forward.headers" must be an object of strings')
        for (const [name, value] of Object.entries(f.headers)) {
          if (typeof value !== "string") throw new PolicyError(`"audit.forward.headers.${name}" must be a string`)
          if (!value.includes("${secret:") && /bearer\s+\S{16,}/i.test(value)) {
            throw new PolicyError(`"audit.forward.headers.${name}" holds a literal token; use \${secret:NAME}`)
          }
        }
      }
    }
  }

  return { organization, serial, requirePacks, strict, mcpBlocked, mcpRules, mcpDefault, requireSandbox, allowedSources, auditForward }
}

export function summarize(s: PolicySummary) {
  const parts: string[] = []
  if (s.requirePacks.length) parts.push(`${s.requirePacks.length} required packs${s.strict ? ", strict safety" : ""}`)
  else if (s.strict) parts.push("strict safety")
  if (s.mcpBlocked || s.mcpRules) parts.push(`MCP: ${s.mcpBlocked} blocked, ${s.mcpRules} tool rules, default ${s.mcpDefault}`)
  if (s.allowedSources) parts.push(`${s.allowedSources.length} secret sources`)
  if (s.auditForward) parts.push("audit forwarding")
  return parts.join(" · ") || "No restrictions"
}

/** Parses one base64 raw Ed25519 public key, as in org-key.pub. */
export function parsePublicKey(b64: string): crypto.KeyObject | null {
  const text = b64.trim()
  if (!/^[A-Za-z0-9+/]{43}=$/.test(text)) return null
  const raw = Buffer.from(text, "base64")
  if (raw.length !== 32) return null
  try {
    return crypto.createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: raw.toString("base64url") }, format: "jwk" })
  } catch {
    return null
  }
}

/** Returns the index of the pinned key that verifies, or -1. */
export function verifySignature(policyBytes: Buffer, signatureText: string, publicKeys: string[]): number {
  const sigText = signatureText.trim()
  if (!/^[A-Za-z0-9+/=\s]+$/.test(sigText)) return -1
  const sig = Buffer.from(sigText.replace(/\s+/g, ""), "base64")
  if (sig.length !== 64) return -1
  for (let i = 0; i < publicKeys.length; i++) {
    const key = parsePublicKey(publicKeys[i])
    if (key && crypto.verify(null, policyBytes, key, sig)) return i
  }
  return -1
}

export { PolicyError }
