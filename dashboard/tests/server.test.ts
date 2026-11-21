import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { chain, demoDevices, demoReport, toOCSF, toRV, type DemoEvent } from "@/lib/demo/generate";

// Each test file runs in its own process (pool: forks), so this data dir is private.
const dir = mkdtempSync(join(tmpdir(), "rv-console-test-"));
process.env.RV_CONSOLE_DATA_DIR = dir;

type Tokens = typeof import("@/lib/server/tokens");
type Queries = typeof import("@/lib/server/queries");
type Route = typeof import("@/app/api/v1/ingest/route");
type ReportRoute = typeof import("@/app/api/v1/reports/route");
let tokens: Tokens, queries: Queries, ingest: Route, reports: ReportRoute;
let token = "";

beforeAll(async () => {
  tokens = await import("@/lib/server/tokens");
  queries = await import("@/lib/server/queries");
  ingest = await import("@/app/api/v1/ingest/route");
  reports = await import("@/app/api/v1/reports/route");
  token = tokens.createToken("fleet", "test").token;
});

afterAll(() => rmSync(dir, { recursive: true, force: true }));

const post = (body: unknown, headers: Record<string, string> = {}, raw?: string) =>
  ingest.POST(new Request("http://console/api/v1/ingest", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", ...headers },
    body: raw ?? JSON.stringify(body),
  }));

function events(n: number, start: number, subject = "core.git:reset-hard"): DemoEvent[] {
  return Array.from({ length: n }, (_, i) => ({
    time: start + i * 1000, kind: "command.denied", decision: "denied" as const, subject, agent: "claude",
    source: "audit.jsonl", detail: { host: "claude", tool: "Bash", seq: String(i) },
  }));
}

describe("POST /api/v1/ingest", () => {
  it("refuses requests without a live token", async () => {
    const res = await ingest.POST(new Request("http://console/api/v1/ingest", { method: "POST", body: "[]" }));
    expect(res.status).toBe(401);
    const wrong = await ingest.POST(new Request("http://console/api/v1/ingest", {
      method: "POST", headers: { authorization: "Bearer rvc_notarealtokennotarealtoken" }, body: "[]",
    }));
    expect(wrong.status).toBe(401);
  });

  it("stores an OCSF batch, dedupes a resend, and keeps the chain intact", async () => {
    const batch = chain(events(5, Date.now() - 60_000), null).events.map((e) => toOCSF(e, "Laptop-A"));
    const first = await post(batch);
    expect(first.status).toBe(200);
    expect(await first.json()).toMatchObject({ accepted: 5, duplicates: 0, chainBreaks: 0, devices: ["laptop-a"] });
    const again = await (await post(batch)).json();
    expect(again).toMatchObject({ accepted: 0, duplicates: 5, chainBreaks: 0 });
    const device = queries.getDevice("laptop-a")!;
    expect(device.device).toMatchObject({ hostname: "Laptop-A", chainEvents: 5, chainBreaks: 0, chainVerdict: "intact" });
  });

  it("flags a chain break when a forwarded event does not follow the head", async () => {
    const start = Date.now() - 30_000;
    const { events: first, head } = chain(events(3, start, "core.secrets:env"), null);
    await post(first.map((e) => toOCSF(e, "laptop-b")));
    const { events: second } = chain(events(2, start + 10_000, "core.secrets:env"), `${head}`.replace(/^./, "f"));
    const res = await (await post(second.map((e) => toOCSF(e, "laptop-b")))).json();
    expect(res.chainBreaks).toBe(1);
    const device = queries.getDevice("laptop-b")!;
    expect(device.device.chainVerdict).toBe("broken");
    expect(device.breaks).toHaveLength(1);
    expect(queries.recentChainBreaks().some((b) => b.deviceId === "laptop-b")).toBe(true);
  });

  it("names rv-format events by X-RV-Device and accepts JSON Lines", async () => {
    const lines = events(3, Date.now() - 5_000).map(toRV).map((e) => JSON.stringify(e)).join("\n");
    const res = await post(null, { "content-type": "application/x-ndjson", "x-rv-device": "build-host-7" }, lines);
    expect(await res.json()).toMatchObject({ accepted: 3, devices: ["build-host-7"] });
  });

  it("rejects malformed bodies with 400 and oversized batches with 413", async () => {
    expect((await post(null, {}, "{nope")).status).toBe(400);
    expect((await post([{ hello: 1 }])).status).toBe(400);
    const big = new Array(5001).fill(toOCSF(events(1, 1)[0], "x"));
    expect((await post(big)).status).toBe(413);
  });
});

describe("POST /api/v1/reports", () => {
  it("stores posture and answers with compliance findings", async () => {
    const device = { ...demoDevices()[0], hostname: "laptop-a", secretViolation: true };
    const res = await reports.POST(new Request("http://console/api/v1/reports", {
      method: "POST", headers: { authorization: `Bearer ${token}` }, body: JSON.stringify(demoReport(device, Date.now(), null)),
    }));
    const body = await res.json();
    expect(body.compliant).toBe(false);
    expect(body.findings[0]).toMatch(/^Secret ANTHROPIC_API_KEY/);
    const row = queries.listDevices().find((d) => d.id === "laptop-a")!;
    expect(row).toMatchObject({ compliant: false, managedState: "active", policySerial: device.serial, rvVersion: device.version });
  });
});

describe("queries", () => {
  it("pages by event time with a composite cursor", () => {
    const first = queries.searchEvents({ limit: 4 });
    expect(first.total).toBeGreaterThanOrEqual(13);
    const times = first.rows.map((r) => r.time);
    expect([...times].sort((a, b) => b - a)).toEqual(times);
    const next = queries.searchEvents({ limit: 4, before: queries.cursorOf(first.rows[3]) });
    expect(next.rows[0].time).toBeLessThanOrEqual(first.rows[3].time);
    expect(new Set([...first.rows, ...next.rows].map((r) => r.seq)).size).toBe(8);
  });

  it("searches subjects literally (LIKE wildcards are escaped)", () => {
    expect(queries.searchEvents({ q: "core.secrets:env" }).total).toBe(5);
    expect(queries.searchEvents({ q: "%" }).total).toBe(0);
  });

  it("counts KPIs and rule stats", () => {
    const k = queries.overviewKpis("24h");
    expect(k.blocked.value).toBe(13);
    const rules = queries.topRules("24h");
    expect(rules.find((r) => r.rule === "core.git:reset-hard")).toMatchObject({ blocked: 8, packName: "Core Git", severity: "critical" });
  });

  it("revoked tokens stop authenticating", () => {
    const { token: t, record } = tokens.createToken("temp", "test");
    expect(tokens.authenticateIngest(`Bearer ${t}`)?.id).toBe(record.id);
    tokens.revokeToken(record.id, "test");
    expect(tokens.authenticateIngest(`Bearer ${t}`)).toBeNull();
  });
});
