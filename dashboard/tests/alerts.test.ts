import { createHmac } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { chain, demoDevices, demoReport, toOCSF, type DemoEvent } from "@/lib/demo/generate";
import { destinationProblem, slackPayload, type Alert } from "@/lib/alerts/format";

const dir = mkdtempSync(join(tmpdir(), "rv-console-alerts-"));
process.env.RV_CONSOLE_DATA_DIR = dir;
process.env.RV_CONSOLE_PUBLIC_URL = "https://console.northwind.example";

let alerts: typeof import("@/lib/server/alerts");
let store: typeof import("@/lib/server/store");
let normalize: typeof import("@/lib/ingest/normalize");
let report: typeof import("@/lib/ingest/report");
let db: typeof import("@/lib/server/db");

type Sent = { url: string; headers: Record<string, string>; body: string };
let sent: Sent[] = [];
let statuses: number[] = [];
let slackId = "";
let webhookId = "";
let webhookSecret = "";

beforeAll(async () => {
  alerts = await import("@/lib/server/alerts");
  store = await import("@/lib/server/store");
  normalize = await import("@/lib/ingest/normalize");
  report = await import("@/lib/ingest/report");
  db = await import("@/lib/server/db");
  alerts.setAlertTransport(async (url, init) => {
    sent.push({ url, headers: init.headers as Record<string, string>, body: String(init.body) });
    return new Response("ok", { status: statuses.shift() ?? 200 });
  });
  const slack = alerts.createDestination({ name: "#sec-alerts", kind: "slack", url: "https://hooks.slack.com/services/T000/B000/XXXXSECRET", minSeverity: "medium" }, "admin");
  const hook = alerts.createDestination({ name: "PagerDuty bridge", kind: "webhook", url: "https://hooks.northwind.example/rv", minSeverity: "critical" }, "admin");
  if (!slack.ok || !hook.ok) throw new Error("setup failed");
  slackId = slack.destination.id;
  webhookId = hook.destination.id;
  webhookSecret = hook.signingSecret!;
});

beforeEach(() => { sent = []; statuses = []; });
afterAll(() => rmSync(dir, { recursive: true, force: true }));

function ingest(events: DemoEvent[], host = "eng-mbp-0142") {
  const outcome = store.storeEvents(normalize.parseBatch(events.map((e) => toOCSF(e, host)), host), host);
  return alerts.evaluateIngest(outcome);
}

const misuse = (time = Date.now(), name = "STRIPE_SECRET_KEY"): DemoEvent => ({
  time, kind: "secret.misuse", decision: "denied", subject: name, reason: "placeholder used against its policy",
  source: "secret-gateway", detail: { refusal: "foreignPlaceholder", fingerprint: "ab12" },
});

describe("destinations", () => {
  it("validates URLs and stores them sealed", () => {
    expect(destinationProblem("slack", "https://example.com/hook")).toMatch(/Slack incoming webhook/);
    expect(destinationProblem("webhook", "http://hooks.example/rv")).toMatch(/https/);
    expect(destinationProblem("webhook", "http://hooks.example/rv", true)).toBeNull();
    expect(destinationProblem("webhook", "https://user:pw@hooks.example/rv")).toMatch(/credentials/);
    const row = db.db().prepare("SELECT url_enc, url_hint FROM alert_destinations WHERE id = ?").get(slackId) as { url_enc: string; url_hint: string };
    expect(row.url_enc).not.toContain("XXXXSECRET");
    expect(row.url_hint).toBe("hooks.slack.com…CRET");
    expect(webhookSecret).toMatch(/^whsec_/);
  });
});

describe("raising and delivering", () => {
  it("sends secret misuse to Slack and a signed webhook, then holds repeats in cooldown", async () => {
    const raised = ingest([misuse()]);
    expect(raised).toHaveLength(1);
    expect(raised[0]).toMatchObject({ rule: "secret.misuse", severity: "critical", deviceId: "eng-mbp-0142" });
    await alerts.dispatch(raised, []);
    expect(sent.map((s) => s.url).sort()).toEqual(["https://hooks.northwind.example/rv", "https://hooks.slack.com/services/T000/B000/XXXXSECRET"]);

    const hook = sent.find((s) => s.url.includes("northwind"))!;
    const [t, v1] = hook.headers["x-rv-console-signature"].split(",").map((p) => p.split("=")[1]);
    expect(v1).toBe(createHmac("sha256", webhookSecret).update(`${t}.${hook.body}`).digest("hex"));
    expect(JSON.parse(hook.body)).toMatchObject({ schema: "rv.console.alert.v1", rule: "secret.misuse", url: "https://console.northwind.example/secrets" });
    const slack = JSON.parse(sent.find((s) => s.url.includes("slack"))!.body);
    expect(slack.blocks[0].text.text).toContain("Secret misuse: STRIPE_SECRET_KEY");

    expect(ingest([misuse(Date.now() + 1)])).toHaveLength(0); // same device and secret: cooldown
    expect(ingest([misuse(Date.now() + 2, "GITHUB_TOKEN")])).toHaveLength(1); // another secret is a new subject
  });

  it("does not page for old events from a backfill", () => {
    expect(ingest([misuse(Date.now() - 3 * 3_600_000, "OLD_KEY")], "laptop-backfill")).toHaveLength(0);
  });

  it("routes by minimum severity: a high alert skips the critical-only webhook", async () => {
    const loosened: DemoEvent = {
      time: Date.now(), kind: "config.changed", decision: "info", subject: "safety", source: "audit.jsonl",
      detail: { setting: "safety", direction: "loosening", authorized_by: "none", prior: "strict", new: "normal" },
    };
    const raised = ingest(chain([loosened], null).events, "contractor-mbp-881");
    expect(raised[0]).toMatchObject({ rule: "gate.loosened", severity: "high" });
    await alerts.dispatch(raised, []);
    expect(sent.map((s) => s.url)).toEqual(["https://hooks.slack.com/services/T000/B000/XXXXSECRET"]);
  });

  it("raises a critical alert for a chain break", () => {
    const t = Date.now();
    const first = chain([{ time: t, kind: "command.denied", decision: "denied", subject: "core.git:reset-hard", source: "audit.jsonl", detail: {} }], null);
    ingest(first.events, "eng-mbp-0226");
    const second = chain([{ time: t + 1, kind: "command.denied", decision: "denied", subject: "core.git:reset-hard", source: "audit.jsonl", detail: {} }], "f".repeat(64));
    const raised = ingest(second.events, "eng-mbp-0226");
    expect(raised.map((a) => a.rule)).toContain("chain.break");
  });

  it("retries 5xx and records the outcome", async () => {
    statuses = [503, 200];
    const raised = ingest([misuse(Date.now(), "AWS_PROD_DEPLOY")], "ds-ws-03");
    await alerts.dispatch(raised, [0]);
    const delivery = db.db().prepare("SELECT status, attempts FROM alert_deliveries WHERE alert_id = ? AND destination_id = ?").get(raised[0].id, webhookId) as { status: string; attempts: number } | undefined;
    const other = db.db().prepare("SELECT status, attempts FROM alert_deliveries WHERE alert_id = ? AND destination_id = ?").get(raised[0].id, slackId) as { status: string; attempts: number };
    expect([delivery?.attempts, other.attempts].sort()).toEqual([1, 2]);
    expect(delivery?.status).toBe("sent");
  });

  it("does nothing for a disabled rule", () => {
    alerts.updateRule("secret.misuse", { enabled: false }, "admin");
    expect(ingest([misuse(Date.now(), "ANTHROPIC_API_KEY")], "ml-gpu-11")).toHaveLength(0);
    alerts.updateRule("secret.misuse", { enabled: true }, "admin");
  });

  it("finds block spikes with the configured threshold", () => {
    alerts.updateRule("blocks.spike", { threshold: 5 }, "admin");
    const t = Date.now() - 60_000;
    ingest(Array.from({ length: 6 }, (_, i) => ({ time: t + i, kind: "command.denied", decision: "denied" as const, subject: "core.filesystem:rm-rf-general", source: "denials.jsonl", detail: { i: String(i) } })), "ci-runner-02");
    const raised = alerts.evaluateSweep();
    expect(raised.find((a) => a.rule === "blocks.spike")).toMatchObject({ hostname: "ci-runner-02" });
    expect(alerts.evaluateSweep().filter((a) => a.rule === "blocks.spike")).toHaveLength(0);
  });

  it("alerts when a device falls out of compliance, once", () => {
    const device = { ...demoDevices()[2], hostname: "eng-mbp-0163" };
    expect(alerts.evaluateReport(store.storeReport(report.parseReport(demoReport(device, Date.now(), null))))).toHaveLength(0);
    const bad = demoReport({ ...device, mcpOk: false }, Date.now(), null);
    expect(alerts.evaluateReport(store.storeReport(report.parseReport(bad)))).toHaveLength(1);
    expect(alerts.evaluateReport(store.storeReport(report.parseReport(bad)))).toHaveLength(0);
  });

  it("sends a test alert regardless of minimum severity and reports failures", async () => {
    statuses = [404];
    const result = await alerts.sendTest(webhookId, "admin@northwind.example");
    expect(result).toMatchObject({ status: "failed", httpStatus: 404, attempts: 1 });
    expect(alerts.listDestinations().find((d) => d.id === webhookId)?.lastStatus).toBe("HTTP 404");
  });
});

describe("slack payload", () => {
  it("escapes Slack control characters in event text", () => {
    const alert: Alert = { id: "a", rule: "test", severity: "high", title: "t", summary: "<!channel> & <x>", occurredAt: 0, deviceId: null, hostname: null, fields: [], path: "/" };
    expect(JSON.stringify(slackPayload(alert, null))).toContain("&lt;!channel&gt; &amp; &lt;x&gt;");
  });
});
