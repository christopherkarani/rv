/**
 * Port of rv's `AuditReasonCode` (Sources/RVHistory/AuditReasonCode.swift)
 * for events forwarded in `rv` format, which carry no `status_code`. OCSF
 * batches carry rv's own code and skip this.
 */
const SECRET_PATH_CATEGORIES = new Set([
  "environment", "credentials", "ssh", "cloud", "kubernetes", "container", "keychain", "host",
]);
const JUDGE_RULES = new Set(["core.judge:laya-block", "core.judge:laya-review"]);
const EGRESS_REASONS = new Set([
  "denied-policy", "denied-credential", "header-too-large", "malformed", "dns-failed", "address-filtered",
  "dial-failed", "binary-mismatch", "unattributed-peer", "sni-mismatch",
]);
const SECRET_REFUSALS: Record<string, string> = {
  malformed: "malformed", unknownRoute: "unknown-route", noPlaceholder: "no-placeholder",
  unknownPlaceholder: "unknown-placeholder", foreignPlaceholder: "foreign-placeholder", tooLarge: "too-large",
  unsafeValue: "unsafe-value", echoMethod: "echo-method", encodedPlaceholder: "encoded-placeholder",
  surfaceNotAllowed: "surface-not-allowed", repeatedPlaceholder: "repeated-placeholder",
  outsideAllowRules: "outside-allow-rules", ambiguousPath: "ambiguous-path", auditUnavailable: "audit-unavailable",
  runtimeMismatch: "runtime-mismatch", runtimeUnverified: "runtime-unverified", expired: "expired",
  refreshFailed: "refresh-failed", awsKeyMismatch: "aws-key-mismatch", awsSignedStreaming: "aws-signed-streaming",
  approvalPending: "approval-pending", approvalDenied: "approval-denied", approvalUnavailable: "approval-unavailable",
  binaryMismatch: "binary-mismatch", awsUnsignedPayload: "aws-unsigned-payload",
  awsCredentialsInResponse: "aws-credentials-in-response", requestTimeout: "request-timeout",
};

export interface ReasonInput {
  kind: string;
  decision: string;
  subject: string;
  reason: string | null;
  source: string;
  detail: Record<string, string>;
}

const matches = (kind: string, family: string) => kind === family || kind.startsWith(family + ".");

export function reasonCode(event: ReasonInput): string | null {
  if (event.kind === "command.observed") {
    const wouldBe = event.detail.would_be;
    return wouldBe === "deny" ? "rv.command.observed-deny" : wouldBe === "ask" ? "rv.command.observed-ask" : "rv.command.observed-other";
  }
  if (event.kind === "egress.observed") {
    return event.reason === "denied-policy" ? "rv.egress.observed-denied-policy" : "rv.egress.observed-other";
  }
  if (event.decision !== "denied") return null;
  switch (event.kind) {
    case "command.denied":
      if (event.detail.category && SECRET_PATH_CATEGORIES.has(event.detail.category)) return "rv.command.denied-secret-path";
      if (JUDGE_RULES.has(event.subject)) return "rv.command.denied-judge";
      return "rv.command.denied-rule";
    case "egress.denied":
      return event.reason && EGRESS_REASONS.has(event.reason) ? `rv.egress.${event.reason}` : "rv.egress.denied-other";
    case "mcp.call":
      if (event.detail.policy === "deny") return "rv.mcp.denied-policy";
      return event.detail.policy === "ask" ? "rv.mcp.not-approved" : "rv.mcp.call-denied-other";
    case "mcp.approval":
      if (event.source === "rv mcp approve") return "rv.mcp.approval-refused";
      if (event.reason === "forged grant rejected") return "rv.mcp.approval-forged";
      if (event.reason === "secret refused at launch" || event.reason === "secret refused at relaunch") return "rv.mcp.secret-refused";
      return "rv.mcp.approval-denied-other";
    case "secret.use":
    case "secret.misuse": {
      const code = event.detail.refusal ? SECRET_REFUSALS[event.detail.refusal] : undefined;
      return code ? `rv.secret.${code}` : "rv.secret.refused-other";
    }
    case "admission":
      return event.detail.authorization === "rejected" ? "rv.admission.rejected" : "rv.admission.denied";
    case "owner.action":
      return "rv.owner.refused";
    default:
      return matches(event.kind, "agent") ? "rv.agent.refused" : "rv.denied-other";
  }
}
