import "server-only";
import { db, logConsoleAction } from "./db";
import { newId, newToken, sha256Hex } from "./crypto";

export interface IngestToken {
  id: string;
  name: string;
  prefix: string;
  createdAt: number;
  createdBy: string | null;
  lastUsedAt: number | null;
  revokedAt: number | null;
}

interface TokenRow {
  id: string; name: string; prefix: string; created_at: number; created_by: string | null;
  last_used_at: number | null; revoked_at: number | null;
}

const toToken = (r: TokenRow): IngestToken => ({
  id: r.id, name: r.name, prefix: r.prefix, createdAt: r.created_at, createdBy: r.created_by,
  lastUsedAt: r.last_used_at, revokedAt: r.revoked_at,
});

export function listTokens(): IngestToken[] {
  return (db().prepare("SELECT * FROM tokens ORDER BY revoked_at IS NOT NULL, created_at DESC").all() as unknown as TokenRow[]).map(toToken);
}

/** Returns the plaintext once; only its hash is kept. */
export function createToken(name: string, actor: string): { token: string; record: IngestToken } {
  const { token, prefix, hash } = newToken();
  const id = newId("tok");
  db().prepare("INSERT INTO tokens (id, name, prefix, hash, created_at, created_by) VALUES (?, ?, ?, ?, ?, ?)")
    .run(id, name.trim().slice(0, 80), prefix, hash, Date.now(), actor);
  logConsoleAction(actor, "token.created", name);
  return { token, record: toToken(db().prepare("SELECT * FROM tokens WHERE id = ?").get(id) as unknown as TokenRow) };
}

export function revokeToken(id: string, actor: string) {
  const row = db().prepare("SELECT name FROM tokens WHERE id = ?").get(id) as { name: string } | undefined;
  db().prepare("UPDATE tokens SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL").run(Date.now(), id);
  logConsoleAction(actor, "token.revoked", row?.name ?? id);
}

/** Resolves an `Authorization: Bearer rvc_…` header to a live token. */
export function authenticateIngest(authorization: string | null): IngestToken | null {
  const match = authorization?.match(/^Bearer\s+(rvc_[A-Za-z0-9_-]{20,})$/);
  if (!match) return null;
  const row = db().prepare("SELECT * FROM tokens WHERE hash = ? AND revoked_at IS NULL").get(sha256Hex(match[1])) as TokenRow | undefined;
  if (!row) return null;
  // Throttle last-used writes to one per minute per token.
  if (!row.last_used_at || Date.now() - row.last_used_at > 60_000) {
    db().prepare("UPDATE tokens SET last_used_at = ? WHERE id = ?").run(Date.now(), row.id);
  }
  return toToken(row);
}
