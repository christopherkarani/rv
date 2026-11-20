import { Suspense } from "react"
import Link from "next/link"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { EmptyState, Mono, PageBody, PageHeader, Section, Status, TableSkeleton } from "@/components/shared"
import { ruleInfo } from "@/lib/rules"
import { listMachines, observedByHost, topRules } from "@/lib/queries"
import { getSession, requestTime } from "@/lib/session"
import { readiness } from "@/lib/rollout"
import { hostLabel } from "@/lib/vocab"

const DAY = 86_400_000
const WINDOW_DAYS = 14

async function Rollout() {
  const { org } = await getSession()
  const since = requestTime() - WINDOW_DAYS * DAY
  const [byHost, rules, machines] = await Promise.all([
    observedByHost(org.orgId, since),
    topRules(org.orgId, "command.observed", since, 10),
    listMachines(org.orgId),
  ])
  const topByHost = new Map(
    await Promise.all(byHost.map(async (h) => [h.host, await topRules(org.orgId, "command.observed", since, 3, h.host)] as const)),
  )

  // Host modes come from reports when the client sends them.
  const modes = new Map<string, { block: number; observe: number; off: number }>()
  for (const m of machines) {
    if (m.revoked_at) continue
    for (const [host, mode] of Object.entries(m.latest_report?.hosts ?? {})) {
      if (!mode) continue
      const c = modes.get(host) ?? { block: 0, observe: 0, off: 0 }
      c[mode]++
      modes.set(host, c)
    }
  }

  if (byHost.length === 0) {
    return (
      <EmptyState title="No would-be blocks in the last 14 days">
        Machines in observe mode record what rv would have blocked. Install with <Mono>RV_INSTALL_MODE=observe</Mono> or run{" "}
        <Mono>rv setup --observe</Mono>, and this report fills in.
      </EmptyState>
    )
  }

  return (
    <div className="space-y-10">
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {byHost.map((h) => {
          const observing = modes.get(h.host)?.observe || h.machines
          const rate = Math.round(((h.would_deny + h.would_ask) / Math.max(observing, 1) / WINDOW_DAYS) * 10) / 10
          const r = readiness(rate)
          const counts = modes.get(h.host)
          const total = counts ? counts.block + counts.observe + counts.off : 0
          return (
            <Card key={h.host} className="flex flex-col">
              <CardHeader>
                <div className="flex items-center justify-between gap-2">
                  <CardTitle>{hostLabel(h.host)}</CardTitle>
                  <Status tone={r.tone}>{r.label}</Status>
                </div>
                <CardDescription>{r.note}</CardDescription>
              </CardHeader>
              <CardContent className="flex-1 space-y-4">
                {counts && total > 0 && (
                  <div>
                    <div className="flex h-2 overflow-hidden rounded-full bg-muted">
                      <div className="bg-success" style={{ width: `${(counts.block / total) * 100}%` }} />
                      <div className="bg-warning" style={{ width: `${(counts.observe / total) * 100}%` }} />
                      <div className="bg-destructive" style={{ width: `${(counts.off / total) * 100}%` }} />
                    </div>
                    <div className="mt-2 flex gap-4 text-xs text-muted-foreground">
                      <span>{counts.block} enforce</span>
                      <span>{counts.observe} observe</span>
                      {counts.off > 0 && <span className="text-destructive">{counts.off} off</span>}
                    </div>
                  </div>
                )}
                <dl className="grid grid-cols-3 gap-2 text-sm">
                  <div>
                    <dt className="text-xs text-muted-foreground">Would deny</dt>
                    <dd className="font-semibold tabular-nums">{h.would_deny}</dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">Would ask</dt>
                    <dd className="font-semibold tabular-nums">{h.would_ask}</dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">Per machine/day</dt>
                    <dd className="font-semibold tabular-nums">{rate.toFixed(1)}</dd>
                  </div>
                </dl>
                {(topByHost.get(h.host)?.length ?? 0) > 0 && (
                  <div className="space-y-1">
                    <div className="text-xs text-muted-foreground">Top would-be rules</div>
                    {topByHost.get(h.host)!.map((t) => (
                      <div key={t.subject} className="flex justify-between gap-2 text-xs">
                        <Mono className="truncate">{t.subject}</Mono>
                        <span className="tabular-nums text-muted-foreground">{t.hits}</span>
                      </div>
                    ))}
                  </div>
                )}
              </CardContent>
              <CardFooter className="flex-col items-start gap-1.5">
                <span className="text-xs text-muted-foreground">Each owner flips it on their machine:</span>
                <Mono className="w-full rounded-md border bg-muted/50 px-2 py-1.5">rv host mode {h.host} block</Mono>
              </CardFooter>
            </Card>
          )
        })}
      </div>

      <Section title="What observe would have blocked" description={`All observing hosts, last ${WINDOW_DAYS} days`}>
        <div className="overflow-hidden rounded-xl border">
          <Table>
            <TableHeader>
              <TableRow className="bg-muted/40 hover:bg-muted/40">
                <TableHead>Rule</TableHead>
                <TableHead className="text-right">Would-be blocks</TableHead>
                <TableHead className="hidden text-right sm:table-cell">Machines</TableHead>
                <TableHead className="hidden md:table-cell">Hosts</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rules.map((r) => (
                <TableRow key={r.subject}>
                  <TableCell>
                    <Mono>{r.subject}</Mono>
                    {ruleInfo(r.subject) && <div className="max-w-md truncate text-xs text-muted-foreground">{ruleInfo(r.subject)!.description}</div>}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">{r.hits}</TableCell>
                  <TableCell className="hidden text-right tabular-nums sm:table-cell">{r.machines}</TableCell>
                  <TableCell className="hidden md:table-cell">
                    <div className="flex flex-nowrap gap-1">
                      {r.hosts.map((h) => (
                        <Badge key={h} variant="outline" className="font-normal">
                          {h}
                        </Badge>
                      ))}
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      </Section>
    </div>
  )
}

export default function RolloutPage() {
  return (
    <>
      <PageHeader
        title="Rollout"
        description="What enforcement would have blocked on machines still in observe mode, so you can switch with evidence."
        actions={<Button render={<Link href="/policy" />}>Pin enforce with an org gate</Button>}
      />
      <PageBody>
        <Suspense fallback={<TableSkeleton rows={6} />}>
          <Rollout />
        </Suspense>
      </PageBody>
    </>
  )
}
