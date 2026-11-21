import "server-only";
import { randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";

/** Runtime configuration, read once from the environment. */
export const config = (() => {
  // Runtime-only path: keep it out of build-time file tracing.
  const dataDir = resolve(/*turbopackIgnore: true*/ process.env.RV_CONSOLE_DATA_DIR ?? join(/*turbopackIgnore: true*/ process.cwd(), "data"));
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  const retentionDays = Number(process.env.RV_CONSOLE_RETENTION_DAYS ?? 90);
  return {
    dataDir,
    dbPath: join(dataDir, "console.db"),
    retentionDays: Number.isFinite(retentionDays) && retentionDays > 0 ? retentionDays : 90,
    /** Public base URL shown in onboarding snippets. */
    publicUrl: process.env.RV_CONSOLE_PUBLIC_URL?.replace(/\/+$/, "") ?? null,
    production: process.env.NODE_ENV === "production",
    /** Cookies need https unless explicitly turned off for a plain-http lab install. */
    secureCookies: process.env.RV_CONSOLE_INSECURE_COOKIES !== "1" && process.env.NODE_ENV === "production",
    maxIngestBytes: 16 * 1024 * 1024,
  };
})();

/**
 * The HMAC key for session cookies. Production requires RV_CONSOLE_SECRET;
 * development generates one into the data dir so restarts keep sessions.
 */
export function sessionSecret(): string {
  const fromEnv = process.env.RV_CONSOLE_SECRET;
  if (fromEnv) {
    if (fromEnv.length < 32) throw new Error("RV_CONSOLE_SECRET must be at least 32 characters");
    return fromEnv;
  }
  if (config.production && process.env.RV_CONSOLE_ALLOW_GENERATED_SECRET !== "1") {
    throw new Error("RV_CONSOLE_SECRET is required in production (32+ random characters)");
  }
  const file = join(config.dataDir, ".session-secret");
  if (existsSync(file)) return readFileSync(file, "utf8").trim();
  const generated = randomBytes(48).toString("base64url");
  writeFileSync(file, generated, { mode: 0o600 });
  return generated;
}
