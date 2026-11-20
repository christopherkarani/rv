import { z } from "zod"
import { AGENT_HOSTS } from "@/lib/vocab"

// `rv report --json` output (`rv.report.v1`, Sources/RVCLI/Commands/ReportCommand.swift).
// Unknown fields pass through so newer clients are not rejected.

const managedSchema = z.looseObject({
  state: z.enum(["none", "invalid", "active"]),
  directory: z.string().max(4096).optional(),
  reason: z.string().max(4096).optional(),
  organization: z.string().max(256).optional(),
  serial: z.number().int().optional(),
  sha256: z.string().max(128).optional(),
  signed: z.boolean().optional(),
  signingKey: z.number().int().optional(),
  highestSerial: z.number().int().optional(),
  restrictions: z.array(z.string().max(1024)).max(500).optional(),
})

const hostModeSchema = z.enum(["block", "observe", "off"])

export const reportSchema = z.looseObject({
  schema: z.literal("rv.report.v1"),
  generatedAt: z.iso.datetime({ offset: true }),
  rv: z.looseObject({ version: z.string().max(64), platform: z.string().max(64) }),
  host: z.looseObject({ name: z.string().max(255), user: z.string().max(255), uid: z.number().int() }),
  managed: managedSchema,
  config: z
    .array(z.looseObject({ file: z.string().max(255), present: z.boolean(), sha256: z.string().max(128).nullish() }))
    .max(100),
  mcp: z.looseObject({
    ok: z.boolean(),
    error: z.string().max(4096).nullish(),
    servers: z.number().int(),
    counts: z.record(z.string(), z.number().int()),
    failing: z
      .array(z.looseObject({ host: z.string(), name: z.string(), status: z.string(), config: z.string() }))
      .max(500),
    plaintextCredentials: z.number().int(),
  }),
  secrets: z.looseObject({
    error: z.string().max(4096).nullish(),
    items: z
      .array(
        z.looseObject({
          name: z.string().max(256),
          source: z.string().max(64),
          delivery: z.string().max(64),
          policyViolation: z.string().max(4096).nullish(),
        }),
      )
      .max(1000),
  }),
  audit: z.looseObject({
    since: z.string(),
    total: z.number().int(),
    byKind: z.record(z.string(), z.record(z.string(), z.number().int())),
    lastEventAt: z.string().nullish(),
    chainIntact: z.boolean().nullish(),
    chainHead: z.string().max(128).nullish(),
  }),
  sandbox: z.looseObject({ platform: z.string(), mcpSandbox: z.boolean(), peerTrustInstalled: z.boolean() }),
  // Not in rv.report.v1 yet: the client follow-up adds these. Optional so
  // current clients are accepted and the UI shows "not reported".
  hosts: z.partialRecord(z.enum(AGENT_HOSTS), hostModeSchema).optional(),
  packs: z.array(z.string().regex(/^[a-z0-9_.-]{1,64}$/)).max(200).optional(),
})

export type Report = z.infer<typeof reportSchema>

/** Same rule as `ReportRun.Report.compliant` in rv. */
export function isCompliant(r: Report) {
  return (
    r.managed.state !== "invalid" &&
    r.mcp.ok &&
    r.secrets.error == null &&
    r.secrets.items.every((i) => i.policyViolation == null) &&
    r.audit.chainIntact !== false
  )
}
