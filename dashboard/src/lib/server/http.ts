import "server-only";
import { NextResponse } from "next/server";
import { IngestError } from "../ingest/normalize";
import { config } from "./config";

/** Reads a request body with a hard size cap (Content-Length can lie or be absent). */
export async function readBody(request: Request, limit = config.maxIngestBytes): Promise<string> {
  const declared = Number(request.headers.get("content-length") ?? 0);
  if (declared > limit) throw new IngestError(`body larger than ${limit} bytes`, 413);
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      throw new IngestError(`body larger than ${limit} bytes`, 413);
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

export function parseJSONBody(text: string, contentType: string | null): unknown {
  const ndjson = contentType?.includes("ndjson") || contentType?.includes("jsonl");
  try {
    if (ndjson) return text.split("\n").filter((line) => line.trim()).map((line) => JSON.parse(line));
    return JSON.parse(text);
  } catch {
    throw new IngestError(ndjson ? "body is not valid JSON Lines" : "body is not valid JSON");
  }
}

export function errorResponse(error: unknown) {
  if (error instanceof IngestError) return NextResponse.json({ error: error.message }, { status: error.status });
  console.error("[rv-console]", error);
  return NextResponse.json({ error: "internal error" }, { status: 500 });
}

/** Host names a sender may claim with X-RV-Device. */
export function deviceHeader(value: string | null): string | null {
  if (!value) return null;
  const trimmed = value.trim();
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$/.test(trimmed) ? trimmed : null;
}
