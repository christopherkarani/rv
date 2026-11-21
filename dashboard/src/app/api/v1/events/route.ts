import { NextResponse, type NextRequest } from "next/server";
import { currentUser } from "@/lib/server/auth";
import { searchEvents, statusSnapshot } from "@/lib/server/queries";
import { parseRange, RANGES } from "@/lib/range";

export const dynamic = "force-dynamic";

/** Paging and live tail for the UI (session cookie). `after` returns newer events only. */
export async function GET(request: NextRequest) {
  if (!(await currentUser())) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const p = request.nextUrl.searchParams;
  const intParam = (name: string) => {
    const v = Number(p.get(name));
    return Number.isFinite(v) && v > 0 ? v : undefined;
  };
  const range = p.get("range");
  const result = searchEvents({
    q: p.get("q")?.slice(0, 200) || undefined,
    kind: p.get("kind") || undefined,
    decision: p.get("decision") || undefined,
    device: p.get("device") || undefined,
    host: p.get("host") || undefined,
    range: range && range in RANGES ? parseRange(range) : undefined,
    before: p.get("before") ?? undefined,
    after: intParam("after"),
    limit: intParam("limit"),
  });
  return NextResponse.json({ ...result, status: statusSnapshot() }, { headers: { "Cache-Control": "no-store" } });
}
