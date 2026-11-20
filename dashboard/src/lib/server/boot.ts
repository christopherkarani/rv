import "server-only";
import { db } from "./db";
import { ensureBootstrapAdmin } from "./auth";
import { demoEnabled, seedDemo, startDemoSimulator } from "./demo";
import { startAlertSweep } from "./alerts";

const globalBoot = globalThis as unknown as { __rvBoot?: Promise<void> };

/** One-time startup work, run on the first request that needs it. */
export function boot(): Promise<void> {
  globalBoot.__rvBoot ??= (async () => {
    await ensureBootstrapAdmin();
    startAlertSweep();
    if (demoEnabled()) {
      const seeded = db().prepare("SELECT value FROM meta WHERE key = 'demo_seeded'").get();
      if (!seeded) {
        const result = seedDemo();
        db().prepare("INSERT OR REPLACE INTO meta (key, value) VALUES ('demo_seeded', ?)").run(String(Date.now()));
        console.log(`[rv-console] demo fleet seeded: ${result.accepted} events, ${result.devices} reports`);
      }
      startDemoSimulator();
    }
  })().catch((error) => {
    globalBoot.__rvBoot = undefined;
    throw error;
  });
  return globalBoot.__rvBoot;
}
