import Link from "next/link"
import { ArrowRightIcon, ArrowUpRightIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { ActivityChart } from "@/components/activity-chart"
import { Mono, PageBody, PageHeader, Section, SeverityBadge, Stat, StatGrid, Status, StatusDot } from "@/components/shared"
import {
  DAY,
  EVENTS,
  HOST_LABEL,
  MACHINES,
  NOW,
  dailySeries,
  isOnline,
  machineById,
  overrideCounts,
  rolloutByHost,
  timeAgo,
  topRules,
} from "@/lib/data"

export default function OverviewPage() {
  const online = MACHINES.filter(isOnline)
  const compliant = MACHINES.filter((m) => m.compliant)
  const week = EVENTS.filter((e) => e.recordedAt > NOW - 7 * DAY)
  const prevWeek = EVENTS.filter((e) => e.recordedAt <= NOW - 7 * DAY && e.recordedAt > NOW - 14 * DAY)
  const denied = week.filter((e) => e.kind === "command.denied").length
  const deniedPrev = prevWeek.filter((e) => e.kind === "command.denied").length
  const observed = week.filter((e) => e.kind === "command.observed").length
  const delta = deniedPrev ? Math.round(((denied - deniedPrev) / deniedPrev) * 100) : 0
  const drifting = MACHINES.filter((m) => m.drift.length > 0)
  const rules = topRules().slice(0, 6)
  const overrides = overrideCounts()
  const rollout = rolloutByHost().filter((r) => r.observing.length > 0)
  const recent = EVENTS.filter((e) => e.kind !== "command.observed").slice(0, 7)

  return (
    <>
      <PageHeader
        title="Overview"
        description="What coding agents tried to do across Acme Engineering in the last 7 days."
        actions={
          <>
            <Button variant="outline" render={<Link href="/settings" />}>
              Enroll machines
            </Button>
            <Button render={<Link href="/policy" />}>Edit policy</Button>
          </>
        }
      />
      <PageBody className="space-y-10">
        <StatGrid>
          <Stat label="Machines reporting" tone="success" value={`${online.length}/${MACHINES.length}`} sub={`${MACHINES.length - online.length} silent for over 24h`} />
          <Stat
            label="Compliant"
            tone={compliant.length / MACHINES.length > 0.9 ? "success" : "warning"}
            value={`${Math.round((compliant.length / MACHINES.length) * 100)}%`}
            sub={`${MACHINES.length - compliant.length} machines need attention`}
          />
          <Stat label="Commands denied" value={denied.toLocaleString()} sub={`${delta >= 0 ? "+" : ""}${delta}% vs previous 7 days`} />
          <Stat label="Would-be blocks (observe)" tone="warning" value={observed.toLocaleString()} sub="Not blocked: these hosts are observing" />
        </StatGrid>

        <Card>
          <CardHeader>
            <CardTitle>Agent activity</CardTitle>
            <CardDescription>Denied commands and would-be blocks per day, last 14 days</CardDescription>
          </CardHeader>
          <CardContent>
            <ActivityChart data={dailySeries()} />
          </CardContent>
        </Card>

        <div className="grid grid-cols-1 gap-10 lg:grid-cols-5">
          <Section
            className="lg:col-span-3"
            title="Top rules"
            description="Most-hit rules in enforce mode, 7 days"
            action={
              <Button variant="ghost" size="sm" render={<Link href="/activity" />}>
                View all <ArrowRightIcon />
              </Button>
            }
          >
            <div className="overflow-hidden rounded-xl border">
              <Table>
                <TableHeader>
                  <TableRow className="bg-muted/40 hover:bg-muted/40">
                    <TableHead>Rule</TableHead>
                    <TableHead className="hidden sm:table-cell">Severity</TableHead>
                    <TableHead className="text-right">Denies</TableHead>
                    <TableHead className="hidden text-right sm:table-cell">Machines</TableHead>
                    <TableHead className="text-right">Overrides</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {rules.map((r) => (
                    <TableRow key={r.rule.id}>
                      <TableCell>
                        <Mono>{r.rule.id}</Mono>
                        <div className="max-w-72 truncate text-xs text-muted-foreground">{r.rule.description}</div>
                      </TableCell>
                      <TableCell className="hidden sm:table-cell">
                        <SeverityBadge severity={r.rule.severity} />
                      </TableCell>
                      <TableCell className="text-right tabular-nums">{r.count}</TableCell>
                      <TableCell className="hidden text-right tabular-nums sm:table-cell">{r.machines}</TableCell>
                      <TableCell className="text-right tabular-nums text-muted-foreground">{overrides.get(r.rule.id) ?? 0}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          </Section>

          <Section
            className="lg:col-span-2"
            title="Needs attention"
            description={`${drifting.length} machines drifted from policy`}
            action={
              <Button variant="ghost" size="sm" render={<Link href="/machines?filter=drift" />}>
                View all <ArrowRightIcon />
              </Button>
            }
          >
            <div className="divide-y rounded-xl border">
              {drifting.slice(0, 6).map((m) => (
                <Link key={m.id} href={`/machines/${m.id}`} className="flex items-start gap-3 p-3 text-sm transition-colors hover:bg-muted/40">
                  <span className="mt-1.5">
                    <StatusDot tone={m.compliant ? "warning" : "error"} />
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center justify-between gap-2">
                      <span className="font-medium">{m.name}</span>
                      <span className="shrink-0 text-xs text-muted-foreground">{m.team}</span>
                    </div>
                    <div className="truncate text-muted-foreground">{m.drift[0]}</div>
                    {m.drift.length > 1 && <div className="text-xs text-muted-foreground">+{m.drift.length - 1} more</div>}
                  </div>
                </Link>
              ))}
            </div>
          </Section>
        </div>

        <div className="grid grid-cols-1 gap-10 lg:grid-cols-2">
          <Section
            title="Observe rollout"
            description="Hosts still observing, and how noisy enforcement would be"
            action={
              <Button variant="ghost" size="sm" render={<Link href="/rollout" />}>
                Rollout report <ArrowRightIcon />
              </Button>
            }
          >
            <div className="divide-y rounded-xl border">
              {rollout.map((r) => (
                <div key={r.host} className="flex items-center justify-between gap-4 p-3 text-sm">
                  <div>
                    <div className="font-medium">{HOST_LABEL[r.host]}</div>
                    <div className="text-muted-foreground">
                      {r.observing.length} observing · {r.rate.toFixed(1)} would-be blocks per machine per day
                    </div>
                  </div>
                  <Status tone={r.readiness === "ready" ? "success" : r.readiness === "review" ? "warning" : "error"}>
                    {r.readiness === "ready" ? "Ready" : r.readiness === "review" ? "Review" : "Not ready"}
                  </Status>
                </div>
              ))}
            </div>
          </Section>

          <Section
            title="Recent events"
            action={
              <Button variant="ghost" size="sm" render={<Link href="/activity" />}>
                Activity <ArrowUpRightIcon />
              </Button>
            }
          >
            <div className="divide-y rounded-xl border">
              {recent.map((e) => {
                const m = machineById(e.machineId)!
                return (
                  <div key={e.id} className="flex items-center gap-3 p-3 text-sm">
                    <StatusDot tone={e.kind === "command.override" ? "info" : e.kind === "secret.misuse" ? "error" : e.kind === "config.changed" ? "neutral" : "warning"} />
                    <div className="min-w-0 flex-1">
                      <Mono className="block truncate">{e.subject}</Mono>
                      <div className="truncate text-xs text-muted-foreground">
                        {e.kind} · {HOST_LABEL[e.host]} on {m.name}
                      </div>
                    </div>
                    <span className="shrink-0 text-xs text-muted-foreground">{timeAgo(e.recordedAt)}</span>
                  </div>
                )
              })}
            </div>
          </Section>
        </div>
      </PageBody>
    </>
  )
}
