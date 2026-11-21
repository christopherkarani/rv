import { type NextRequest } from "next/server";
import { currentUser } from "@/lib/server/auth";
import { cursorOf, searchEvents } from "@/lib/server/queries";
import { parseRange, RANGES } from "@/lib/range";
import type { EventRow } from "@/lib/types";

export const dynamic = "force-dynamic";

const CSV_COLUMNS: (keyof EventRow)[] = [
  "time", "hostname", "kind", "decision", "subject", "reason", "reasonCode", "host", "agent", "workspace", "source", "uid",
];

function csvCell(value: unknown): string {
  let text = value == null ? "" : typeof value === "object" ? JSON.stringify(value) : String(value);
  // Neutralize spreadsheet formula injection from event text.
  if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`;
  return /[",\n\r]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

/** Filtered export of up to 50,000 events as CSV or JSON Lines. */
export async function GET(request: NextRequest) {
  if (!(await currentUser())) return new Response("unauthorized", { status: 401 });
  const p = request.nextUrl.searchParams;
  const format = p.get("format") === "csv" ? "csv" : "jsonl";
  const range = p.get("range");
  const filter = {
    q: p.get("q")?.slice(0, 200) || undefined,
    kind: p.get("kind") || undefined,
    decision: p.get("decision") || undefined,
    device: p.get("device") || undefined,
    host: p.get("host") || undefined,
    range: range && range in RANGES ? parseRange(range) : undefined,
  };
  const rows: EventRow[] = [];
  let before: string | undefined;
  while (rows.length < 50_000) {
    const page = searchEvents({ ...filter, before, limit: 500 }).rows;
    if (page.length === 0) break;
    rows.push(...page);
    before = cursorOf(page[page.length - 1]);
  }
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const body = format === "csv"
    ? [CSV_COLUMNS.join(","), ...rows.map((r) => CSV_COLUMNS.map((c) => csvCell(c === "time" ? new Date(r.time).toISOString() : r[c])).join(","))].join("\n")
    : rows.map((r) => JSON.stringify({ ...r, time: new Date(r.time).toISOString() })).join("\n");
  return new Response(body + "\n", {
    headers: {
      "Content-Type": format === "csv" ? "text/csv; charset=utf-8" : "application/x-ndjson",
      "Content-Disposition": `attachment; filename="rv-events-${stamp}.${format}"`,
      "Cache-Control": "no-store",
    },
  });
}
