import crypto from "node:crypto"
import { describe, expect, it } from "vitest"
import { PolicyError, parsePublicKey, summarize, validatePolicy, verifySignature } from "@/lib/policy"

// Same encoding as `rv managed keygen` / `rv managed sign`: base64 raw keys,
// base64 signature over the exact policy bytes.
function keygen() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519")
  const raw = Buffer.from((publicKey.export({ format: "jwk" }) as { x: string }).x, "base64url")
  return { pub: raw.toString("base64"), privateKey }
}
const sign = (bytes: Buffer, key: crypto.KeyObject) => crypto.sign(null, bytes, key).toString("base64")

const POLICY = JSON.stringify(
  {
    version: 1,
    organization: "Acme",
    serial: 15,
    mcp: { blocked: ["filesystem-*"], allowDirect: false, requireSandbox: true, deny: ["github/delete_*"], defaultDecision: "ask" },
    secrets: { allowedSources: ["keychain", "vault"], allowEnvironmentDelivery: false },
    audit: { forward: { url: "https://cloud.example/api/v1/events", headers: { Authorization: "Bearer ${secret:RV_CLOUD}" } } },
    gate: { requirePacks: ["core.git", "core.filesystem", "system.disk"], safety: "strict" },
  },
  null,
  2,
)

describe("validatePolicy", () => {
  it("accepts a full policy and summarizes it", () => {
    const s = validatePolicy(POLICY)
    expect(s).toMatchObject({ serial: 15, strict: true, mcpBlocked: 1, mcpRules: 1, mcpDefault: "ask", requireSandbox: true })
    expect(summarize(s)).toBe("3 required packs, strict safety · MCP: 1 blocked, 1 tool rules, default ask · 2 secret sources · audit forwarding")
  })

  const bad: [string, string, RegExp][] = [
    ["unknown top-level key", '{"version":1,"serial":1,"extra":true}', /unknown key "extra"/],
    ["wrong version", '{"version":2,"serial":1}', /version/],
    ["missing serial", '{"version":1}', /serial/],
    ["negative serial", '{"version":1,"serial":-1}', /non-negative integer/],
    ["fractional serial", '{"version":1,"serial":1.5}', /non-negative integer/],
    ["loosening safety", '{"version":1,"serial":1,"gate":{"safety":"normal"}}', /only be "strict"/],
    ["bad pack id", '{"version":1,"serial":1,"gate":{"requirePacks":["Core Git"]}}', /invalid pack id/],
    ["unknown secret source", '{"version":1,"serial":1,"secrets":{"allowedSources":["dropbox"]}}', /unknown secret source/],
    ["bad default decision", '{"version":1,"serial":1,"mcp":{"defaultDecision":"maybe"}}', /allow, ask, or deny/],
    ["forward without url", '{"version":1,"serial":1,"audit":{"forward":{}}}', /url" is required/],
    ["literal token in header", '{"version":1,"serial":1,"audit":{"forward":{"url":"https://x","headers":{"Authorization":"Bearer abcdefghijklmnopqrstuvwxyz"}}}}', /literal token/],
    ["not an object", "[]", /not a JSON object/],
    ["not JSON", "{", /invalid/],
  ]
  for (const [name, text, re] of bad) {
    it(`rejects ${name}`, () => {
      expect(() => validatePolicy(text)).toThrow(PolicyError)
      expect(() => validatePolicy(text)).toThrow(re)
    })
  }

  it("rejects policies over 256 KiB", () => {
    expect(() => validatePolicy(`{"version":1,"serial":1,"organization":"${"x".repeat(270_000)}"}`)).toThrow(/256 KiB/)
  })
})

describe("signatures", () => {
  const a = keygen()
  const b = keygen()
  const bytes = Buffer.from(POLICY, "utf8")

  it("verifies a signature from any pinned key", () => {
    expect(verifySignature(bytes, sign(bytes, a.privateKey), [a.pub])).toBe(0)
    expect(verifySignature(bytes, sign(bytes, b.privateKey) + "\n", [a.pub, b.pub])).toBe(1)
  })

  it("rejects tampered policies, wrong keys and junk", () => {
    const sig = sign(bytes, a.privateKey)
    expect(verifySignature(Buffer.from(POLICY.replace('"serial": 15', '"serial": 16')), sig, [a.pub])).toBe(-1)
    expect(verifySignature(bytes, sig, [b.pub])).toBe(-1)
    expect(verifySignature(bytes, "not base64!", [a.pub])).toBe(-1)
    expect(verifySignature(bytes, sig, [])).toBe(-1)
  })

  it("parses only 32-byte base64 keys", () => {
    expect(parsePublicKey(a.pub)).not.toBeNull()
    expect(parsePublicKey("AAAA")).toBeNull()
    expect(parsePublicKey(Buffer.alloc(31).toString("base64"))).toBeNull()
  })
})
