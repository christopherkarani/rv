import "server-only";
import { DatabaseSync } from "node:sqlite";
import { config } from "./config";

/**
 * One SQLite database (WAL) holds the whole console. Migrations are an
 * ordered list; `user_version` records how many have run.
 */
const MIGRATIONS: string[] = [
  `
  CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    hostname TEXT NOT NULL,
    first_seen INTEGER NOT NULL,
    last_seen INTEGER NOT NULL,
    last_event_at INTEGER,
    event_count INTEGER NOT NULL DEFAULT 0,
    rv_version TEXT,
    platform TEXT,
    os_user TEXT,
    managed_state TEXT,
    organization TEXT,
    policy_serial INTEGER,
    compliant INTEGER,
    report_json TEXT,
    report_at INTEGER,
    report_chain_head TEXT,
    report_chain_intact INTEGER,
    chain_head TEXT,
    chain_events INTEGER NOT NULL DEFAULT 0,
    chain_breaks INTEGER NOT NULL DEFAULT 0,
    chain_anchor_seq INTEGER
  );

  CREATE TABLE events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    uid TEXT NOT NULL UNIQUE,
    device_id TEXT NOT NULL REFERENCES devices(id),
    time INTEGER NOT NULL,
    received_at INTEGER NOT NULL,
    kind TEXT NOT NULL,
    decision TEXT NOT NULL,
    subject TEXT NOT NULL,
    reason TEXT,
    reason_code TEXT,
    agent TEXT,
    host TEXT,
    workspace TEXT,
    runtime TEXT,
    source TEXT,
    severity INTEGER NOT NULL DEFAULT 1,
    detail TEXT NOT NULL DEFAULT '{}',
    prev TEXT,
    chain_head TEXT,
    format TEXT NOT NULL
  );
  CREATE INDEX events_time ON events(time);
  CREATE INDEX events_device_time ON events(device_id, time);
  CREATE INDEX events_kind_time ON events(kind, time);
  CREATE INDEX events_subject ON events(subject);

  CREATE TABLE chain_breaks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id TEXT NOT NULL REFERENCES devices(id),
    seq INTEGER NOT NULL,
    time INTEGER NOT NULL,
    detected_at INTEGER NOT NULL,
    expected TEXT,
    got TEXT
  );
  CREATE INDEX chain_breaks_device ON chain_breaks(device_id);

  CREATE TABLE tokens (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    prefix TEXT NOT NULL,
    hash TEXT NOT NULL UNIQUE,
    scope TEXT NOT NULL DEFAULT 'ingest',
    created_at INTEGER NOT NULL,
    created_by TEXT,
    last_used_at INTEGER,
    revoked_at INTEGER
  );

  CREATE TABLE users (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL UNIQUE COLLATE NOCASE,
    name TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('admin','viewer')),
    password_hash TEXT NOT NULL,
    session_epoch INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    last_login_at INTEGER
  );

  CREATE TABLE console_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    time INTEGER NOT NULL,
    actor TEXT,
    action TEXT NOT NULL,
    target TEXT
  );

  CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  `,
  // 2: single sign-on identities, alert destinations, rules and deliveries.
  `
  ALTER TABLE users ADD COLUMN auth_provider TEXT NOT NULL DEFAULT 'password';
  ALTER TABLE users ADD COLUMN oidc_sub TEXT;
  CREATE UNIQUE INDEX users_oidc_sub ON users(oidc_sub) WHERE oidc_sub IS NOT NULL;

  CREATE TABLE alert_destinations (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('slack','webhook')),
    url_enc TEXT NOT NULL,
    url_hint TEXT NOT NULL,
    secret_enc TEXT,
    min_severity TEXT NOT NULL DEFAULT 'high' CHECK (min_severity IN ('critical','high','medium')),
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    created_by TEXT,
    last_status TEXT,
    last_delivery_at INTEGER
  );

  CREATE TABLE alert_rules (
    id TEXT PRIMARY KEY,
    enabled INTEGER NOT NULL,
    threshold INTEGER,
    updated_at INTEGER NOT NULL,
    updated_by TEXT
  );

  CREATE TABLE alerts (
    id TEXT PRIMARY KEY,
    rule TEXT NOT NULL,
    severity TEXT NOT NULL,
    title TEXT NOT NULL,
    summary TEXT NOT NULL,
    device_id TEXT,
    payload TEXT NOT NULL,
    created_at INTEGER NOT NULL
  );
  CREATE INDEX alerts_created ON alerts(created_at);

  CREATE TABLE alert_deliveries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    alert_id TEXT NOT NULL,
    destination_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('sent','failed')),
    http_status INTEGER,
    error TEXT,
    attempts INTEGER NOT NULL,
    created_at INTEGER NOT NULL
  );
  CREATE INDEX alert_deliveries_created ON alert_deliveries(created_at);

  CREATE TABLE alert_cooldowns (key TEXT PRIMARY KEY, until INTEGER NOT NULL);
  `,
];

function open(): DatabaseSync {
  const db = new DatabaseSync(config.dbPath);
  db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;");
  const row = db.prepare("PRAGMA user_version").get() as { user_version: number };
  for (let v = row.user_version; v < MIGRATIONS.length; v++) {
    db.exec("BEGIN");
    try {
      db.exec(MIGRATIONS[v]);
      db.exec(`PRAGMA user_version = ${v + 1}`);
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
  }
  return db;
}

const globalForDb = globalThis as unknown as { __rvConsoleDb?: DatabaseSync };

export function db(): DatabaseSync {
  globalForDb.__rvConsoleDb ??= open();
  return globalForDb.__rvConsoleDb;
}

/** Runs `fn` in one write transaction. */
export function transaction<T>(fn: (db: DatabaseSync) => T): T {
  const handle = db();
  handle.exec("BEGIN IMMEDIATE");
  try {
    const result = fn(handle);
    handle.exec("COMMIT");
    return result;
  } catch (error) {
    handle.exec("ROLLBACK");
    throw error;
  }
}

export function logConsoleAction(actor: string | null, action: string, target?: string) {
  db().prepare("INSERT INTO console_log (time, actor, action, target) VALUES (?, ?, ?, ?)").run(Date.now(), actor, action, target ?? null);
}
