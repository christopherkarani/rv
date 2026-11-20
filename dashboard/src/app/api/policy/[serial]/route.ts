import { type NextRequest } from "next/server"
import { getSession } from "@/lib/session"
import { policyRevisionText, signingKeys } from "@/lib/queries"

// GET /api/policy/<serial>?file=policy.json|policy.json.sig|org-key.pub
// The exact bytes that were verified at upload, for MDM distribution.
export async function GET(request: NextRequest, ctx: RouteContext<"/api/policy/[serial]">) {
  const { serial } = await ctx.params
  const file = request.nextUrl.searchParams.get("file") ?? "policy.json"
  if (!/^[0-9]{1,15}$/.test(serial)) return new Response("not found", { status: 404 })
  const { org } = await getSession()

  if (file === "org-key.pub") {
    const keys = await signingKeys(org.orgId)
    const body = keys.map((k) => `# ${k.label ?? "key"} (added ${k.added_at.slice(0, 10)})\n${k.public_key}`).join("\n") + "\n"
    return new Response(body, { headers: { "content-type": "text/plain; charset=utf-8", "content-disposition": 'attachment; filename="org-key.pub"' } })
  }
  const rev = await policyRevisionText(org.orgId, Number(serial))
  if (!rev) return new Response("not found", { status: 404 })
  if (file === "policy.json") {
    return new Response(rev.policy_text, {
      headers: { "content-type": "application/json; charset=utf-8", "content-disposition": 'attachment; filename="policy.json"', "cache-control": "no-store" },
    })
  }
  if (file === "policy.json.sig") {
    return new Response(rev.signature + "\n", {
      headers: { "content-type": "text/plain; charset=utf-8", "content-disposition": 'attachment; filename="policy.json.sig"', "cache-control": "no-store" },
    })
  }
  return new Response("unknown file", { status: 400 })
}
