import { NextResponse } from "next/server";
import { parseBatch } from "@/lib/ingest/normalize";
import { authenticateIngest } from "@/lib/server/tokens";
import { deviceHeader, errorResponse, parseJSONBody, readBody } from "@/lib/server/http";
import { ingestAnswer, pruneIfDue, storeEvents } from "@/lib/server/store";
import { alertsOnIngest } from "@/lib/server/alerts";

export const dynamic = "force-dynamic";

/**
 * The endpoint for `rv audit forward --to <console>/api/v1/ingest`.
 * Accepts OCSF (default) or `--format rv` arrays, or JSON Lines from
 * `rv audit export` for a backfill. Answers 2xx only once the batch is
 * committed, so rv's cursor never moves past an event the console lacks.
 */
export async function POST(request: Request) {
  const token = authenticateIngest(request.headers.get("authorization"));
  if (!token) {
    return NextResponse.json({ error: "missing or revoked ingest token" }, {
      status: 401, headers: { "WWW-Authenticate": 'Bearer realm="rv-console"' },
    });
  }
  try {
    const body = parseJSONBody(await readBody(request), request.headers.get("content-type"));
    const device = deviceHeader(request.headers.get("x-rv-device")) ?? token.name;
    const events = parseBatch(body, device.toLowerCase());
    const outcome = storeEvents(events, device);
    pruneIfDue();
    // After the commit and off the response path: rv's retry depends only on storage.
    alertsOnIngest(outcome);
    return NextResponse.json(ingestAnswer(outcome));
  } catch (error) {
    return errorResponse(error);
  }
}
