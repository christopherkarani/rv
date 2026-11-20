import { NextResponse } from "next/server";
import { currentUser } from "@/lib/server/auth";
import { statusSnapshot } from "@/lib/server/queries";

export const dynamic = "force-dynamic";

export async function GET() {
  if (!(await currentUser())) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  return NextResponse.json(statusSnapshot(), { headers: { "Cache-Control": "no-store" } });
}
