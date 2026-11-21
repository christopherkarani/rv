import { z } from "zod";
import { IngestError } from "./normalize";

/** `rv report --json` (schema `rv.report.v1`, Sources/RVCLI/Commands/ReportCommand.swift). */
export const reportSchema = z.object({
  schema: z.literal("rv.report.v1"),
  generatedAt: z.string(),
  rv: z.object({ version: z.string().max(64), platform: z.string().max(32) }),
  host: z.object({ name: z.string().min(1).max(253), user: z.string().max(128), uid: z.number() }),
  managed: z.object({
    state: z.enum(["none", "invalid", "active"]),
    directory: z.string().optional(),
    reason: z.string().optional(),
    organization: z.string().optional(),
    serial: z.number().int().optional(),
    sha256: z.string().optional(),
    signed: z.boolean().optional(),
    signingKey: z.number().optional(),
    highestSerial: z.number().optional(),
    restrictions: z.array(z.string()).optional(),
  }).loose(),
  config: z.array(z.object({ file: z.string(), present: z.boolean(), sha256: z.string().nullish() }).loose()).max(64),
  mcp: z.object({
    ok: z.boolean(),
    error: z.string().nullish(),
    servers: z.number().int(),
    counts: z.record(z.string(), z.number()),
    failing: z.array(z.object({ host: z.string(), name: z.string(), status: z.string(), config: z.string() }).loose()).max(500),
    plaintextCredentials: z.number().int(),
  }).loose(),
  secrets: z.object({
    error: z.string().nullish(),
    items: z.array(z.object({
      name: z.string(), source: z.string(), delivery: z.string(), policyViolation: z.string().nullish(),
    }).loose()).max(2000),
  }).loose(),
  audit: z.object({
    since: z.string(),
    total: z.number().int(),
    byKind: z.record(z.string(), z.record(z.string(), z.number())),
    lastEventAt: z.string().nullish(),
    chainIntact: z.boolean().nullish(),
    chainHead: z.string().nullish(),
  }).loose(),
  sandbox: z.object({ platform: z.string(), mcpSandbox: z.boolean(), peerTrustInstalled: z.boolean() }).loose(),
}).loose();

export type RVReport = z.infer<typeof reportSchema>;

export function parseReport(body: unknown): RVReport {
  const parsed = reportSchema.safeParse(body);
  if (!parsed.success) {
    throw new IngestError(`not an rv.report.v1 document: ${parsed.error.issues[0]?.path.join(".") || "shape"}`);
  }
  return parsed.data;
}

/** The same rule as `ReportRun.Report.compliant`, which rv does not encode. */
export function isCompliant(report: RVReport): boolean {
  return report.managed.state !== "invalid"
    && report.mcp.ok
    && !report.secrets.error
    && report.secrets.items.every((item) => !item.policyViolation)
    && report.audit.chainIntact !== false;
}

/** Why a report is not compliant, in the order an operator should fix it. */
export function complianceFindings(report: RVReport): string[] {
  const findings: string[] = [];
  if (report.managed.state === "invalid") findings.push(`Organization policy is invalid: ${report.managed.reason ?? "unknown reason"}`);
  if (report.audit.chainIntact === false) findings.push("Local audit chain is broken");
  if (!report.mcp.ok) findings.push(report.mcp.error ? `MCP gateway: ${report.mcp.error}` : `MCP gateway check fails (${report.mcp.failing.length} server entries bypass or fail)`);
  if (report.secrets.error) findings.push(`Secrets config: ${report.secrets.error}`);
  for (const item of report.secrets.items) {
    if (item.policyViolation) findings.push(`Secret ${item.name}: ${item.policyViolation}`);
  }
  return findings;
}
