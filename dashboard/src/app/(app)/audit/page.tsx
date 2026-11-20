import { Suspense } from "react"
import Link from "next/link"
import { DownloadIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { EmptyState, Mono, PageBody, PageHeader, Section, Stat, StatGrid, Status, TableSkeleton } from "@/components/shared"
import { timeAgo } from "@/lib/machine-status"
import { chainFindings, listMachines } from "@/lib/queries"
import { getSession, requestTime } from "@/lib/session"

const fmt = (iso: string) => new Date(iso).toISOString().replace("T", " ").slice(0, 16) + " UTC"

async function Audit() {
  const { org } = await getSession()
  const now = requestTime()
  const [machines, findings] = await Promise.all([listMachines(org.orgId), chainFindings(org.orgId)])
  const live = machines.filter((m) => !m.revoked_at)
  const count = (s: string) => live.filter((m) => m.chain_status === s).length
  const names = new Map(machines.map((m) => [m.id, m.name]))
  const problems = live.filter((m) => m.chain_status === "gap" || m.chain_status === "broken")

  return (
    <div className="space-y-10">
      <StatGrid>
        <Stat label="Chains continuous" tone="success" value={count("ok")} sub="Each batch continues the last head" />
        <Stat label="Gaps" tone={count("gap") ? "error" : "success"} value={count("gap")} sub="Forwarded events skipped or rewrote history" />
        <Stat label="Broken locally" tone={count("broken") ? "error" : "success"} value={count("broken")} sub="rv audit verify fails on the machine" />
        <Stat label="No chain yet" tone="neutral" value={count("unknown")} sub="Nothing chained forwarded so far" />
      </StatGrid>

      <Section title="Machines to investigate" description="A gap means a forwarded event did not continue the previous head: the local log was edited, truncated or replaced.">
        {problems.length === 0 ? (
          <EmptyState title="No chain problems">Every machine&apos;s forwarded audit chain is continuous.</EmptyState>
        ) : (
          <div className="overflow-hidden rounded-xl border">
            <Table>
              <TableHeader>
                <TableRow className="bg-muted/40 hover:bg-muted/40">
                  <TableHead>Machine</TableHead>
                  <TableHead>Finding</TableHead>
                  <TableHead className="hidden md:table-cell">Last head</TableHead>
                  <TableHead className="text-right">Last event</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {problems.map((m) => (
                  <TableRow key={m.id}>
                    <TableCell>
                      <Link href={`/machines/${m.id}`} className="font-medium hover:underline">
                        {m.name}
                      </Link>
                    </TableCell>
                    <TableCell>
                      <Status tone="error">{m.chain_status === "gap" ? "Gap in forwarded chain" : "Local chain broken"}</Status>
                    </TableCell>
                    <TableCell className="hidden md:table-cell">
                      <Mono className="text-muted-foreground">{m.chain_head ? `${m.chain_head.slice(0, 16)}…` : "—"}</Mono>
                    </TableCell>
                    <TableCell className="text-right text-muted-foreground">{timeAgo(m.last_event_at, now)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </Section>

      {findings.length > 0 && (
        <Section title="Finding log" description="Most recent first.">
          <div className="divide-y rounded-xl border text-sm">
            {findings.slice(0, 50).map((f) => (
              <div key={f.id} className="flex flex-wrap items-center gap-x-4 gap-y-1 p-3">
                <span className="w-40 shrink-0 text-muted-foreground">{fmt(f.detected_at)}</span>
                <Link href={`/machines/${f.machine_id}`} className="font-medium hover:underline">
                  {names.get(f.machine_id) ?? "unknown"}
                </Link>
                <span className="text-muted-foreground">{f.detail}</span>
                {f.expected && (
                  <Mono className="text-xs text-muted-foreground">
                    expected {f.expected.slice(0, 12)}… got {f.got ? `${f.got.slice(0, 12)}…` : "none"}
                  </Mono>
                )}
              </div>
            ))}
          </div>
        </Section>
      )}

      <div className="grid grid-cols-1 gap-6 md:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Export</CardTitle>
            <CardDescription>Everything rv Cloud holds for this organization, within your retention window.</CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap gap-2">
            <Button variant="outline" render={<a href="/api/export/events" download />}>
              <DownloadIcon />
              Events (JSON Lines)
            </Button>
            <p className="w-full text-xs text-muted-foreground">Each line holds the event as the machine sent it: OCSF 1.3.0 by default.</p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Send to your SIEM too</CardTitle>
            <CardDescription>
              rv keeps a separate cursor per destination, so machines can forward OCSF straight to your SIEM alongside rv Cloud.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Mono className="block overflow-x-auto rounded-md border bg-muted/40 px-3 py-2 text-xs">
              rv audit forward --to https://siem.example/collector --format ocsf --install
            </Mono>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}

export default function AuditPage() {
  return (
    <>
      <PageHeader
        title="Audit"
        description="rv's audit log is a SHA-256 hash chain on each machine. rv Cloud keeps every chain head off the machine, so a rewritten or truncated log shows up here."
      />
      <PageBody>
        <Suspense fallback={<TableSkeleton rows={6} />}>
          <Audit />
        </Suspense>
      </PageBody>
    </>
  )
}
