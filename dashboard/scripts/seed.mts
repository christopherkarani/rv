#!/usr/bin/env node
/**
 * Loads the demo fleet into a running console over HTTP, exactly as rv
 * machines would send it. Usage:
 *   RV_CONSOLE_TOKEN=rvc_… node scripts/seed.mts [--url http://localhost:3000] [--days 30]
 */
import { demoFleet } from "../src/lib/demo/generate.ts";

const args = process.argv.slice(2);
const flag = (name: string, fallback: string) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const url = flag("url", "http://localhost:3000").replace(/\/+$/, "");
const days = Number(flag("days", "30"));
const token = process.env.RV_CONSOLE_TOKEN;
if (!token) {
  console.error("Set RV_CONSOLE_TOKEN to an ingest token from Settings.");
  process.exit(2);
}

const fleet = demoFleet(Date.now(), days);
let accepted = 0;
for (const batch of fleet.batches) {
  const res = await fetch(`${url}/api/v1/ingest`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      ...(batch.format === "rv" ? { "x-rv-device": batch.device.hostname } : {}),
    },
    body: JSON.stringify(batch.body),
  });
  if (!res.ok) {
    console.error(`ingest failed: HTTP ${res.status} ${await res.text()}`);
    process.exit(1);
  }
  accepted += (await res.json()).accepted;
}
for (const report of fleet.reports) {
  const res = await fetch(`${url}/api/v1/reports`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(report),
  });
  if (!res.ok) {
    console.error(`report failed: HTTP ${res.status} ${await res.text()}`);
    process.exit(1);
  }
}
console.log(`seeded ${accepted} events and ${fleet.reports.length} reports into ${url}`);
