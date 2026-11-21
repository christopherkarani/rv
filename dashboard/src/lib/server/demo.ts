import "server-only";
import { db } from "./db";
import { storeEvents, storeReport } from "./store";
import { alertsOnIngest } from "./alerts";
import { parseBatch } from "../ingest/normalize";
import { parseReport } from "../ingest/report";
import { chain, demoDevices, demoFleet, randomEvent, toOCSF, toRV } from "../demo/generate";

export const demoEnabled = () => process.env.RV_CONSOLE_DEMO === "1";

/** Loads 30 days of synthetic fleet history through the real ingest path. */
export function seedDemo(now = Date.now()) {
  const fleet = demoFleet(now, 30);
  let accepted = 0;
  for (const batch of fleet.batches) {
    const events = parseBatch(batch.body, batch.device.hostname.toLowerCase());
    accepted += storeEvents(events, batch.device.hostname).accepted;
  }
  for (const report of fleet.reports) storeReport(parseReport(report));
  return { accepted, devices: fleet.reports.length };
}

const globalDemo = globalThis as unknown as { __rvDemoTimer?: NodeJS.Timeout };

/** Streams a new event every few seconds so a demo's live views move. */
export function startDemoSimulator() {
  if (globalDemo.__rvDemoTimer) return;
  const devices = demoDevices();
  const tick = () => {
    try {
      const totalWeight = devices.reduce((s, d) => s + d.activity, 0);
      let r = Math.random() * totalWeight;
      const device = devices.find((d) => (r -= d.activity) <= 0) ?? devices[0];
      const event = randomEvent(Math.random, device, Date.now());
      const row = db().prepare("SELECT chain_head FROM devices WHERE id = ?").get(device.hostname.toLowerCase()) as { chain_head: string | null } | undefined;
      chain([event], row?.chain_head ?? null);
      const body = device.format === "rv" ? [toRV(event)] : [toOCSF(event, device.hostname)];
      alertsOnIngest(storeEvents(parseBatch(body, device.hostname.toLowerCase()), device.hostname));
    } catch (error) {
      console.error("[rv-console] demo simulator", error);
    }
    globalDemo.__rvDemoTimer = setTimeout(tick, 2500 + Math.random() * 4500);
  };
  globalDemo.__rvDemoTimer = setTimeout(tick, 3000);
}
