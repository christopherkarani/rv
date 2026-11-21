import { describe, expect, it } from "vitest";
import { IngestError, parseBatch } from "@/lib/ingest/normalize";
import { advanceChain, chainVerdict } from "@/lib/ingest/chain";
import { reasonCode } from "@/lib/ingest/reason-code";
import { complianceFindings, isCompliant, parseReport } from "@/lib/ingest/report";
import { chain, demoFleet, demoReport, demoDevices, toOCSF, toRV, type DemoEvent } from "@/lib/demo/generate";

const H = (c: string) => c.repeat(64);

// Shaped like AuditOCSF.object output for a hook deny (Sources/RVHistory/AuditOCSF.swift).
const ocsfDeny = {
  action: "Denied", action_id: 2, activity_id: 1, activity_name: "Launch", category_uid: 1, class_uid: 1007,
  class_name: "Process Activity", disposition: "Blocked", disposition_id: 2,
  device: { hostname: "Eng-MBP-0142", type_id: 0 },
  actor: { app_name: "claude", session: { uid: "sess-1" } },
  message: "rv command.denied core.git:reset-hard: denied",
  metadata: { log_name: "audit.jsonl", product: { name: "rv", vendor_name: "rv", version: "0.12.1" }, uid: "0123456789abcdef0123456789abcdef", version: "1.3.0" },
  process: { name: "Bash", uid: "0123456789abcdef0123456789abcdef" },
  severity: "Medium", severity_id: 3, status: "Failure", status_code: "rv.command.denied-rule", status_id: 2,
  time: 1763600000000, type_uid: 100701,
  unmapped: {
    rv_kind: "command.denied", rv_subject: "core.git:reset-hard",
    rv_detail: { host: "claude", tool: "Bash", path: "~/src/app", session: "sess-1" },
    rv_prev: H("a"), rv_chain_head: H("b"),
  },
};

describe("parseBatch", () => {
  it("reads rv's OCSF events", () => {
    const [e] = parseBatch([ocsfDeny], "token");
    expect(e).toMatchObject({
      uid: "0123456789abcdef0123456789abcdef", hostname: "Eng-MBP-0142", kind: "command.denied", decision: "denied",
      subject: "core.git:reset-hard", reasonCode: "rv.command.denied-rule", agent: "claude", host: "claude",
      source: "audit.jsonl", severity: 3, prev: H("a"), chainHead: H("b"), format: "ocsf",
    });
    expect(e.detail.path).toBe("~/src/app");
  });

  it("reads rv.audit.v1 events and derives a reason code", () => {
    const [e] = parseBatch([{
      schema: "rv.audit.v1", time: "2026-11-17T19:37:03Z", kind: "command.denied", decision: "denied",
      subject: "core.secrets:env", source: "denials.jsonl", detail: { host: "cursor", category: "environment" },
    }], "laptop");
    expect(e.format).toBe("rv");
    expect(e.time).toBe(Date.parse("2026-11-17T19:37:03Z"));
    expect(e.reasonCode).toBe("rv.command.denied-secret-path");
    expect(e.hostname).toBeNull();
    // Stable id: the same event from the same device dedupes.
    expect(parseBatch([toRV({ time: 1, kind: "x", decision: "info", subject: "s", source: "a", detail: {} })], "d")[0].uid)
      .toBe(parseBatch([toRV({ time: 1, kind: "x", decision: "info", subject: "s", source: "a", detail: {} })], "d")[0].uid);
  });

  it("drops non-hex chain fields and coerces detail values", () => {
    const [e] = parseBatch([{ ...ocsfDeny, unmapped: { ...ocsfDeny.unmapped, rv_prev: "nope", rv_detail: { n: 3 } } }], "t");
    expect(e.prev).toBeNull();
    expect(e.detail.n).toBe("3");
  });

  it("rejects malformed bodies with a useful message", () => {
    expect(() => parseBatch("hello", "t")).toThrow(IngestError);
    expect(() => parseBatch([{ time: 1 }], "t")).toThrow(/event 0/);
    expect(() => parseBatch(new Array(5001).fill(ocsfDeny), "t")).toThrow(/too large/);
  });
});

describe("hash chain", () => {
  it("anchors, follows, and flags a mismatch", () => {
    let s = advanceChain({ head: null }, { prev: H("0"), chainHead: H("1") });
    expect(s).toMatchObject({ anchored: true, broken: null, head: H("1") });
    s = advanceChain({ head: s.head }, { prev: H("1"), chainHead: H("2") });
    expect(s.broken).toBeNull();
    s = advanceChain({ head: s.head }, { prev: H("9"), chainHead: H("3") });
    expect(s.broken).toEqual({ expected: H("2"), got: H("9") });
    expect(s.head).toBe(H("3"));
  });

  it("ignores unchained events", () => {
    expect(advanceChain({ head: H("1") }, { prev: null, chainHead: null })).toMatchObject({ broken: null, head: H("1") });
  });

  it("detects the demo fleet's tampered device and only that one", () => {
    const now = Date.UTC(2026, 10, 20);
    const fleet = demoFleet(now, 3);
    const breaks = new Map<string, number>();
    for (const batch of fleet.batches) {
      for (const e of parseBatch(batch.body, batch.device.hostname)) {
        const key = batch.device.hostname;
        const state = { head: (breaks as unknown as Map<string, string>).get(`${key}#head`) ?? null };
        const step = advanceChain(state, e);
        (breaks as unknown as Map<string, string | number>).set(`${key}#head`, step.head as string);
        if (step.broken) breaks.set(key, (breaks.get(key) ?? 0) + 1);
      }
    }
    const broken = [...breaks.entries()].filter(([k, v]) => !k.endsWith("#head") && v > 0).map(([k]) => k);
    expect(broken).toEqual(["eng-mbp-0226"]);
  });

  it("gives verdicts", () => {
    expect(chainVerdict({ chainEvents: 5, chainBreaks: 0, reportHeadKnown: true, reportChainIntact: true })).toBe("intact");
    expect(chainVerdict({ chainEvents: 5, chainBreaks: 1, reportHeadKnown: true, reportChainIntact: true })).toBe("broken");
    expect(chainVerdict({ chainEvents: 5, chainBreaks: 0, reportHeadKnown: false, reportChainIntact: true })).toBe("behind");
    expect(chainVerdict({ chainEvents: 0, chainBreaks: 0, reportHeadKnown: null, reportChainIntact: null })).toBe("unchained");
    expect(chainVerdict({ chainEvents: 5, chainBreaks: 0, reportHeadKnown: null, reportChainIntact: false })).toBe("broken");
  });
});

describe("reasonCode", () => {
  const base = { reason: null, source: "audit.jsonl", detail: {} as Record<string, string> };
  it("matches rv's derivation for common kinds", () => {
    expect(reasonCode({ ...base, kind: "command.denied", decision: "denied", subject: "core.judge:laya-block" })).toBe("rv.command.denied-judge");
    expect(reasonCode({ ...base, kind: "command.observed", decision: "info", subject: "x", detail: { would_be: "ask" } })).toBe("rv.command.observed-ask");
    expect(reasonCode({ ...base, kind: "egress.denied", decision: "denied", subject: "h:443", reason: "sni-mismatch" })).toBe("rv.egress.sni-mismatch");
    expect(reasonCode({ ...base, kind: "secret.misuse", decision: "denied", subject: "K", detail: { refusal: "foreignPlaceholder" } })).toBe("rv.secret.foreign-placeholder");
    expect(reasonCode({ ...base, kind: "mcp.call", decision: "denied", subject: "a/b", detail: { policy: "deny" } })).toBe("rv.mcp.denied-policy");
    expect(reasonCode({ ...base, kind: "agent.refused", decision: "denied", subject: "a" })).toBe("rv.agent.refused");
    expect(reasonCode({ ...base, kind: "mcp.call", decision: "allowed", subject: "a/b" })).toBeNull();
  });
});

describe("reports", () => {
  const device = demoDevices()[0];
  it("accepts rv.report.v1 and applies rv's compliance rule", () => {
    const report = parseReport(demoReport(device, Date.now(), H("c")));
    expect(isCompliant(report)).toBe(true);
    expect(complianceFindings(report)).toEqual([]);
  });

  it("explains why a machine is not compliant", () => {
    const bad = demoReport({ ...device, managed: "invalid", mcpOk: false, secretViolation: true }, Date.now(), null);
    const report = parseReport(bad);
    expect(isCompliant(report)).toBe(false);
    const findings = complianceFindings(report);
    expect(findings[0]).toMatch(/Organization policy is invalid/);
    expect(findings.some((f) => f.startsWith("MCP gateway"))).toBe(true);
    expect(findings.some((f) => f.startsWith("Secret ANTHROPIC_API_KEY"))).toBe(true);
  });

  it("rejects other documents", () => {
    expect(() => parseReport({ schema: "rv.audit.v1" })).toThrow(IngestError);
  });
});

describe("demo generator", () => {
  it("emits OCSF that round-trips through the parser", () => {
    const event: DemoEvent = { time: 5, kind: "config.changed", decision: "info", subject: "safety", source: "audit.jsonl", detail: { direction: "loosening" } };
    chain([event], null);
    const [parsed] = parseBatch([toOCSF(event, "host-1")], "t");
    expect(parsed).toMatchObject({ kind: "config.changed", hostname: "host-1", prev: H("0"), chainHead: event.chainHead });
  });
});

describe("safeNext", () => {
  it("keeps same-origin paths and drops everything else", async () => {
    const { safeNext } = await import("@/lib/safe-next");
    expect(safeNext("/activity?q=core.git%3Areset-hard&range=30d")).toBe("/activity?q=core.git%3Areset-hard&range=30d");
    for (const bad of ["//evil.example", "/\\evil.example", "https://evil.example", "/ok\n", "javascript:alert(1)", ""]) {
      expect(safeNext(bad)).toBe("/");
    }
  });
});
