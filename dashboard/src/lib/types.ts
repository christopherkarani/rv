/** Shapes shared by server queries and client components. */
export interface EventRow {
  seq: number;
  uid: string;
  deviceId: string;
  hostname: string;
  time: number;
  receivedAt: number;
  kind: string;
  decision: "allowed" | "denied" | "pending" | "failed" | "info";
  subject: string;
  reason: string | null;
  reasonCode: string | null;
  agent: string | null;
  host: string | null;
  workspace: string | null;
  runtime: string | null;
  source: string | null;
  severity: number;
  detail: Record<string, string>;
  prev: string | null;
  chainHead: string | null;
  format: "ocsf" | "rv";
}

export interface Kpi {
  value: number;
  previous: number;
}

export interface TimelinePoint {
  t: number;
  blocked: number;
  overrides: number;
  observed: number;
  mcp: number;
}

export interface RuleStat {
  rule: string;
  pack: string;
  packName: string | null;
  severity: string | null;
  description: string | null;
  blocked: number;
  observed: number;
  overrides: number;
  devices: number;
  hosts: string[];
  lastSeen: number;
  trend: number[];
}

export type ChainVerdict = "intact" | "broken" | "unchained" | "behind";

export interface DeviceRow {
  id: string;
  hostname: string;
  firstSeen: number;
  lastSeen: number;
  lastEventAt: number | null;
  rvVersion: string | null;
  platform: string | null;
  osUser: string | null;
  managedState: string | null;
  organization: string | null;
  policySerial: number | null;
  compliant: boolean | null;
  reportAt: number | null;
  chainVerdict: ChainVerdict;
  chainBreaks: number;
  chainEvents: number;
  chainHead: string | null;
  blocked: number;
  observed: number;
  events: number;
  hosts: string[];
  /** Silent for more than 24 hours. */
  stale: boolean;
}
