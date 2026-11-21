import "server-only";
import type { DatabaseSync } from "node:sqlite";
import { config } from "./config";
import { db, transaction } from "./db";
import { pruneAlerts } from "./alerts";
import { advanceChain } from "../ingest/chain";
import { deviceIdFor, type NormalizedEvent } from "../ingest/normalize";
import { complianceFindings, isCompliant, type RVReport } from "../ingest/report";

export interface StoredEvent {
  event: NormalizedEvent;
  deviceId: string;
  hostname: string;
  seq: number;
}

export interface StoredBreak {
  deviceId: string;
  hostname: string;
  seq: number;
  time: number;
  expected: string;
  got: string | null;
}

export interface IngestOutcome {
  accepted: number;
  duplicates: number;
  chainBreaks: number;
  devices: string[];
  /** New events and breaks, for the alert engine; not part of the HTTP answer. */
  stored: StoredEvent[];
  breaks: StoredBreak[];
}

/** What the ingest endpoint answers rv with. */
export const ingestAnswer = ({ accepted, duplicates, chainBreaks, devices }: IngestOutcome) =>
  ({ accepted, duplicates, chainBreaks, devices });

function upsertDevice(handle: DatabaseSync, id: string, hostname: string, now: number) {
  handle.prepare(`
    INSERT INTO devices (id, hostname, first_seen, last_seen) VALUES (?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET last_seen = MAX(last_seen, excluded.last_seen)
  `).run(id, hostname, now, now);
}

/**
 * Stores one forwarded batch. `fallbackHost` names the device for events that
 * carry no host name (rv format): the `X-RV-Device` header, else the token name.
 * Duplicates (at-least-once resends) are skipped and do not touch the chain.
 */
export function storeEvents(events: NormalizedEvent[], fallbackHost: string): IngestOutcome {
  const now = Date.now();
  return transaction((handle) => {
    const insert = handle.prepare(`
      INSERT OR IGNORE INTO events
        (uid, device_id, time, received_at, kind, decision, subject, reason, reason_code, agent, host,
         workspace, runtime, source, severity, detail, prev, chain_head, format)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    const chainOf = handle.prepare("SELECT chain_head FROM devices WHERE id = ?");
    const recordBreak = handle.prepare(
      "INSERT INTO chain_breaks (device_id, seq, time, detected_at, expected, got) VALUES (?, ?, ?, ?, ?, ?)");
    const touch = handle.prepare(`
      UPDATE devices SET
        event_count = event_count + 1,
        first_seen = MIN(first_seen, ?),
        last_event_at = MAX(COALESCE(last_event_at, 0), ?),
        chain_head = ?,
        chain_events = chain_events + ?,
        chain_breaks = chain_breaks + ?,
        chain_anchor_seq = COALESCE(chain_anchor_seq, ?)
      WHERE id = ?
    `);
    const seen = new Set<string>();
    const stored: StoredEvent[] = [];
    const breakList: StoredBreak[] = [];
    let accepted = 0;
    let duplicates = 0;
    let breaks = 0;
    for (const event of events) {
      const hostname = event.hostname ?? fallbackHost;
      const deviceId = deviceIdFor(hostname);
      if (!seen.has(deviceId)) {
        upsertDevice(handle, deviceId, hostname, now);
        seen.add(deviceId);
      }
      const result = insert.run(
        event.uid, deviceId, event.time, now, event.kind, event.decision, event.subject, event.reason,
        event.reasonCode, event.agent, event.host, event.workspace, event.runtime, event.source, event.severity,
        JSON.stringify(event.detail), event.prev, event.chainHead, event.format);
      if (result.changes === 0) {
        duplicates++;
        continue;
      }
      accepted++;
      const seq = Number(result.lastInsertRowid);
      const current = chainOf.get(deviceId) as { chain_head: string | null };
      const step = advanceChain({ head: current.chain_head }, event);
      stored.push({ event, deviceId, hostname, seq });
      if (step.broken) {
        breaks++;
        recordBreak.run(deviceId, seq, event.time, now, step.broken.expected, step.broken.got);
        breakList.push({ deviceId, hostname, seq, time: event.time, ...step.broken });
      }
      const chained = event.chainHead ? 1 : 0;
      touch.run(event.time, event.time, step.head, chained, step.broken ? 1 : 0, step.anchored ? seq : null, deviceId);
    }
    return { accepted, duplicates, chainBreaks: breaks, devices: [...seen], stored, breaks: breakList };
  });
}

export interface StoredReport {
  deviceId: string;
  hostname: string;
  compliant: boolean;
  /** Compliance before this report; null for a device's first report. */
  previous: boolean | null;
  findings: string[];
}

export function storeReport(report: RVReport): StoredReport {
  const now = Date.now();
  const id = deviceIdFor(report.host.name);
  return transaction((handle) => {
    const before = handle.prepare("SELECT compliant FROM devices WHERE id = ?").get(id) as { compliant: number | null } | undefined;
    upsertDevice(handle, id, report.host.name, now);
    handle.prepare(`
      UPDATE devices SET
        hostname = ?, rv_version = ?, platform = ?, os_user = ?, managed_state = ?, organization = ?,
        policy_serial = ?, compliant = ?, report_json = ?, report_at = ?, report_chain_head = ?, report_chain_intact = ?
      WHERE id = ?
    `).run(
      report.host.name, report.rv.version, report.rv.platform, report.host.user, report.managed.state,
      report.managed.organization ?? null, report.managed.serial ?? null, isCompliant(report) ? 1 : 0,
      JSON.stringify(report), now, report.audit.chainHead ?? null,
      report.audit.chainIntact === undefined || report.audit.chainIntact === null ? null : report.audit.chainIntact ? 1 : 0,
      id);
    return {
      deviceId: id, hostname: report.host.name, compliant: isCompliant(report),
      previous: before?.compliant == null ? null : before.compliant === 1, findings: complianceFindings(report),
    };
  });
}

let lastPrune = 0;
/** Drops events past retention, at most once an hour. */
export function pruneIfDue() {
  const now = Date.now();
  if (now - lastPrune < 60 * 60 * 1000) return;
  lastPrune = now;
  const cutoff = now - config.retentionDays * 86_400_000;
  db().prepare("DELETE FROM events WHERE time < ?").run(cutoff);
  db().prepare("DELETE FROM chain_breaks WHERE detected_at < ?").run(cutoff);
  pruneAlerts(config.retentionDays);
}
