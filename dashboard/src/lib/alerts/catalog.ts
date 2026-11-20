/** The alert rules the console can raise. Client-safe: the Alerts page renders this. */
export type Severity = "critical" | "high" | "medium";

export const SEVERITY_RANK: Record<Severity, number> = { critical: 3, high: 2, medium: 1 };

export interface RuleDef {
  id: RuleId;
  title: string;
  description: string;
  severity: Severity;
  /** How the rule waits before firing again for the same subject. */
  cooldownMs: number;
  threshold?: { label: string; unit: string; default: number; min: number; max: number };
}

export type RuleId =
  | "chain.break"
  | "secret.misuse"
  | "mcp.forged"
  | "gate.loosened"
  | "device.noncompliant"
  | "blocks.spike"
  | "device.silent";

const MIN = 60_000;

export const RULES: RuleDef[] = [
  {
    id: "chain.break", severity: "critical", cooldownMs: 60 * MIN,
    title: "Audit chain broken",
    description: "A forwarded event does not follow the chain head the console holds: a line on the machine was edited, removed or reordered, or forwarding skipped events.",
  },
  {
    id: "secret.misuse", severity: "critical", cooldownMs: 15 * MIN,
    title: "Secret misuse",
    description: "The secret gateway refused a placeholder used against its own policy or from the wrong process.",
  },
  {
    id: "mcp.forged", severity: "critical", cooldownMs: 15 * MIN,
    title: "Forged MCP approval",
    description: "The MCP gateway rejected an approval grant that rv did not sign.",
  },
  {
    id: "gate.loosened", severity: "high", cooldownMs: 15 * MIN,
    title: "Gate loosened without owner authentication",
    description: "A change made rv's rules weaker (safety, packs, allowlist, host or guard mode) with no owner check recorded.",
  },
  {
    id: "device.noncompliant", severity: "high", cooldownMs: 6 * 60 * MIN,
    title: "Device fell out of compliance",
    description: "A machine's latest rv report fails rv's compliance rule: invalid org policy, MCP servers around the gateway, a secret policy violation, or a broken local chain.",
  },
  {
    id: "blocks.spike", severity: "medium", cooldownMs: 30 * MIN,
    title: "Block spike",
    description: "One machine hit many blocks in 10 minutes, often an agent looping on a destructive command.",
    threshold: { label: "Blocks in 10 minutes", unit: "blocks", default: 25, min: 3, max: 10_000 },
  },
  {
    // Keyed by the device's last-seen time, so it fires once per silence.
    id: "device.silent", severity: "medium", cooldownMs: 30 * 24 * 60 * MIN,
    title: "Device stopped forwarding",
    description: "A machine that forwarded events has sent nothing for a while: rv may be uninstalled, its forward job stopped, or the machine offline.",
    threshold: { label: "Silent for", unit: "hours", default: 24, min: 1, max: 720 },
  },
];

export const ruleDef = (id: string) => RULES.find((r) => r.id === id);
