import { Suspense } from "react"
import Link from "next/link"
import { ArrowRightIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { ActivityChart } from "@/components/activity-chart"
import {
  EmptyState,
  Mono,
  PageBody,
  PageHeader,
  Section,
  SeverityBadge,
  Skeleton,
  Stat,
  StatGrid,
  StatusDot,
  TableSkeleton,
} from "@/components/shared"
import { ruleInfo } from "@/lib/rules"
import { assess, newestVersion, timeAgo } from "@/lib/machine-status"
import { currentPolicySerial, dailyActivity, listEvents, listMachines, overrideCounts, topRules } from "@/lib/queries"
import { getSession, requestTime } from "@/lib/session"
import { hostLabel } from "@/lib/vocab"

const DAY = 86_400_000

async function Overview() {
  const { org } = await getSession()
  const now = requestTime()
  const [machines, daily, rules, overrides, serial, recent] = await Promise.all([
    listMachines(org.orgId),
    dailyActivity(org.orgId, 14),
    topRules(org.orgId, "command.denied", now - 7 * DAY, 6),
    overrideCounts(org.orgId, now - 7 * DAY),
    currentPolicySerial(org.orgId),
    listEvents(org.orgId, { kinds: ["command.denied", "command.override", "secret.misuse", "config.changed", "policy.managed"], limit: 8 }),
  ])

  if (machines.length === 0) {
    return (
      <EmptyState
        title="No machines enrolled yet"
        action={<Button render={<Link href="/settings" />}>Create an enrollment token</Button>}
      >
        Create an enrollment token in Settings, run <Mono>rv</Mono>&apos;s enroll command on each machine, and activity shows up
        here within five minutes.
      </EmptyState>
    )
  }

  const latest = newestVersion(machines.map((m) => m.rv_version))
  const live = machines.filter((m) => !m.revoked_at)
  const assessed = live.map((m) => ({ m, a: assess(m, { now, currentSerial: serial, latestVersion: latest }) }))
  const reporting = assessed.filter(({ a }) => a.state !== "silent" && a.state !== "pending").length
  const withReport = assessed.filter(({ m }) => m.compliant !== null)
  const compliant = withReport.filter(({ m }) => m.compliant).length
  const attention = assessed.filter(({ a }) => a.issues.length > 0).sort((x, y) => (x.a.tone === "error" ? -1 : 0) - (y.a.tone === "error" ? -1 : 0))

  const week = daily.slice(-7)
  const prev = daily.slice(0, 7)
  const denied = week.reduce((n, d) => n + d.denied, 0)
  const deniedPrev = prev.reduce((n, d) => n + d.denied, 0)
  const observed = week.reduce((n, d) => n + d.observed, 0)
  const delta = deniedPrev ? Math.round(((denied - deniedPrev) / deniedPrev) * 100) : null
  const names = new Map(machines.map((m) => [m.id, m.name]))

  return (
    <div className="space-y-10">
      <StatGrid>
        <Stat
          label="Machines reporting"
          tone={reporting === live.length ? "success" : "warning"}
          value={`${reporting}/${live.length}`}
          sub={`${live.length - reporting} silent or awaiting a first report`}
        />
        <Stat
          label="Compliant"
          tone={withReport.length === 0 ? "neutral" : compliant === withReport.length ? "success" : "warning"}
          value={withReport.length ? `${Math.round((compliant / withReport.length) * 100)}%` : "—"}
          sub={withReport.length ? `${withReport.length - compliant} of ${withReport.length} reported machines fail` : "No reports yet"}
        />
        <Stat
          label="Commands denied"
          value={denied.toLocaleString()}
          sub={delta === null ? "Last 7 days" : `${delta >= 0 ? "+" : ""}${delta}% vs previous 7 days`}
        />
        <Stat label="Would-be blocks (observe)" tone={observed ? "warning" : undefined} value={observed.toLocaleString()} sub="Last 7 days, not blocked" />
      </StatGrid>

      <Card>
        <CardHeader>
          <CardTitle>Agent activity</CardTitle>
          <CardDescription>Denied commands and would-be blocks per day (UTC), last 14 days</CardDescription>
        </CardHeader>
        <CardContent>
          <ActivityChart data={daily} />
        </CardContent>
      </Card>

      <div className="grid grid-cols-1 gap-10 lg:grid-cols-5">
        <Section
          className="lg:col-span-3"
          title="Top rules"
          description="Most-hit rules in enforce mode, last 7 days"
          action={
            <Button variant="ghost" size="sm" render={<Link href="/activity?kind=denied" />}>
              View all <ArrowRightIcon />
            </Button>
          }
        >
          {rules.length === 0 ? (
            <EmptyState title="No denies in the last 7 days" />
          ) : (
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
                  {rules.map((r) => {
                    const info = ruleInfo(r.subject)
                    return (
                      <TableRow key={r.subject}>
                        <TableCell>
                          <Mono>{r.subject}</Mono>
                          {info && <div className="max-w-72 truncate text-xs text-muted-foreground">{info.description}</div>}
                        </TableCell>
                        <TableCell className="hidden sm:table-cell">{info && <SeverityBadge severity={info.severity} />}</TableCell>
                        <TableCell className="text-right tabular-nums">{r.hits}</TableCell>
                        <TableCell className="hidden text-right tabular-nums sm:table-cell">{r.machines}</TableCell>
                        <TableCell className="text-right tabular-nums text-muted-foreground">{overrides.get(r.subject) ?? 0}</TableCell>
                      </TableRow>
                    )
                  })}
                </TableBody>
              </Table>
            </div>
          )}
        </Section>

        <Section
          className="lg:col-span-2"
          title="Needs attention"
          description={`${attention.length} of ${live.length} machines`}
          action={
            <Button variant="ghost" size="sm" render={<Link href="/machines?filter=attention" />}>
              View all <ArrowRightIcon />
            </Button>
          }
        >
          {attention.length === 0 ? (
            <EmptyState title="Every machine is healthy" />
          ) : (
            <div className="divide-y rounded-xl border">
              {attention.slice(0, 6).map(({ m, a }) => (
                <Link key={m.id} href={`/machines/${m.id}`} className="flex items-start gap-3 p-3 text-sm transition-colors hover:bg-muted/40">
                  <span className="mt-1.5">
                    <StatusDot tone={a.tone} />
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center justify-between gap-2">
                      <span className="truncate font-medium">{m.name}</span>
                      <span className="shrink-0 text-xs text-muted-foreground">{a.label}</span>
                    </div>
                    <div className="truncate text-muted-foreground">{a.issues[0]}</div>
                    {a.issues.length > 1 && <div className="text-xs text-muted-foreground">+{a.issues.length - 1} more</div>}
                  </div>
                </Link>
              ))}
            </div>
          )}
        </Section>
      </div>

      <Section
        title="Recent events"
        description="Denies, overrides, alerts and configuration changes"
        action={
          <Button variant="ghost" size="sm" render={<Link href="/activity" />}>
            Activity <ArrowRightIcon />
          </Button>
        }
      >
        {recent.length === 0 ? (
          <EmptyState title="Nothing yet" />
        ) : (
          <div className="divide-y rounded-xl border">
            {recent.map((e) => (
              <div key={`${e.machine_id}-${e.uid}`} className="flex items-center gap-3 p-3 text-sm">
                <StatusDot
                  tone={e.kind === "command.override" ? "info" : e.kind === "secret.misuse" ? "error" : e.kind.startsWith("command") ? "warning" : "neutral"}
                />
                <div className="min-w-0 flex-1">
                  <Mono className="block truncate">{e.subject}</Mono>
                  <div className="truncate text-xs text-muted-foreground">
                    {e.kind} · {hostLabel(e.host)} on {names.get(e.machine_id) ?? "unknown machine"}
                  </div>
                </div>
                <span className="shrink-0 text-xs text-muted-foreground">{timeAgo(e.time, now)}</span>
              </div>
            ))}
          </div>
        )}
      </Section>
    </div>
  )
}

function OverviewSkeleton() {
  return (
    <div className="space-y-10">
      <Skeleton className="h-28 w-full rounded-xl" />
      <Skeleton className="h-80 w-full rounded-xl" />
      <TableSkeleton />
    </div>
  )
}

export default function OverviewPage() {
  return (
    <>
      <PageHeader title="Overview" description="What coding agents tried to do across your organization." />
      <PageBody>
        <Suspense fallback={<OverviewSkeleton />}>
          <Overview />
        </Suspense>
      </PageBody>
    </>
  )
}
