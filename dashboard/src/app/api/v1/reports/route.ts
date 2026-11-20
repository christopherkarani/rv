import { NextResponse } from "next/server";
import { complianceFindings, isCompliant, parseReport } from "@/lib/ingest/report";
import { authenticateIngest } from "@/lib/server/tokens";
import { errorResponse, parseJSONBody, readBody } from "@/lib/server/http";
import { storeReport } from "@/lib/server/store";

export const dynamic = "force-dynamic";

/** `rv report --json | curl --data-binary @- <console>/api/v1/reports` from an MDM script. */
export async function POST(request: Request) {
  if (!authenticateIngest(request.headers.get("authorization"))) {
    return NextResponse.json({ error: "missing or revoked ingest token" }, { status: 401 });
  }
  try {
    const report = parseReport(parseJSONBody(await readBody(request, 2 * 1024 * 1024), "application/json"));
    const device = storeReport(report);
    return NextResponse.json({ device, compliant: isCompliant(report), findings: complianceFindings(report) });
  } catch (error) {
    return errorResponse(error);
  }
}
