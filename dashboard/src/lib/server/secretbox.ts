import "server-only";
import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from "node:crypto";
import { sessionSecret } from "./config";

/**
 * AES-256-GCM with a key derived from RV_CONSOLE_SECRET per purpose, for
 * values the console must read back (webhook URLs, the SSO flow cookie).
 * Format: base64url(iv | tag | ciphertext). Rotating the secret makes old
 * values unreadable; callers treat that as "re-enter it".
 */
const keys = new Map<string, Buffer>();

function key(purpose: string): Buffer {
  let k = keys.get(purpose);
  if (!k) {
    k = Buffer.from(hkdfSync("sha256", sessionSecret(), "rv-console", `rv-console/${purpose}`, 32));
    keys.set(purpose, k);
  }
  return k;
}

export function seal(plaintext: string, purpose: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key(purpose), iv);
  const body = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), body]).toString("base64url");
}

export function open(sealed: string, purpose: string): string | null {
  try {
    const raw = Buffer.from(sealed, "base64url");
    if (raw.length < 29) return null;
    const decipher = createDecipheriv("aes-256-gcm", key(purpose), raw.subarray(0, 12));
    decipher.setAuthTag(raw.subarray(12, 28));
    return Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString("utf8");
  } catch {
    return null;
  }
}
