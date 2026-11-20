import { Suspense } from "react"
import Link from "next/link"
import { DownloadIcon } from "lucide-react"
import { cn } from "@/lib/utils"
import { Button } from "@/components/ui/button"
import { EmptyState, PageBody, PageHeader, TableSkeleton } from "@/components/shared"
import { listEvents, listMachines } from "@/lib/queries"
import { getSession } from "@/lib/session"
import { hostLabel } from "@/lib/vocab"
import { ActivityFilters } from "./filters"

const KINDS: Record<string, string[] | undefined> = {
  all: undefined,
  denied: ["command.denied"],
  observed: ["command.observed"],
  override: ["command.override"],
  mcp: ["mcp.call", "mcp.approval", "mcp.tool.changed", "mcp.hosts.ungoverned"],
  alerts: ["secret.misuse", "config.changed", "policy.changed", "policy.managed", "owner.action", "egress.denied"],
}

function level(kind: string, decision: string) {
  if (kind === "secret.misuse") return { label: "ALERT", className: "bg-destructive text-white" }
  if (kind === "command.denied" || decision === "denied") return { label: "DENY", className: "bg-destructive/10 text-destructive" }
  if (kind === "command.observed") return { label: "OBSERVE", className: "bg-warning/10 text-warning" }
  if (kind === "command.override") return { label: "OVERRIDE", className: "bg-info/10 text-info" }
  if (decision === "pending") return { label: "PENDING", className: "bg-warning/10 text-warning" }
  if (decision === "failed") return { label: "FAILED", className: "bg-destructive/10 text-destructive" }
  if (decision === "allowed") return { label: "ALLOW", className: "bg-success/10 text-success" }
  return { label: "INFO", className: "bg-muted text-muted-foreground" }
}

const fmt = (iso: string) => new Date(iso).toISOString().replace("T", " ").slice(0, 19) + "Z"
const str = (v: string | string[] | undefined) => (typeof v === "string" && v ? v : undefined)

async function Feed({ searchParams }: { searchParams: PageProps<"/activity">["searchParams"] }) {
  const sp = await searchParams
  const { org } = await getSession()
  const kind = str(sp.kind) ?? "all"
  const host = str(sp.host)
  const q = str(sp.q)?.slice(0, 100)
  const machine = str(sp.machine)
  const before = str(sp.before)
  const PAGE = 100
  const [events, machines] = await Promise.all([
    listEvents(org.orgId, {
      kinds: KINDS[kind],
      host,
      subject: q,
      machineId: machine && /^[0-9a-f-]{36}$/.test(machine) ? machine : undefined,
      before: before && !Number.isNaN(Date.parse(before)) ? before : undefined,
      limit: PAGE,
    }),
    listMachines(org.orgId),
  ])
  const names = new Map(machines.map((m) => [m.id, m.name]))
  const older = new URLSearchParams(Object.entries(sp).flatMap(([k, v]) => (typeof v === "string" ? [[k, v]] : [])))
  if (events.length) older.set("before", events[events.length - 1].time)

  if (events.length === 0) {
    return <EmptyState title={before ? "No older events" : "No events match"}>Events appear here within five minutes of a deny on any enrolled machine.</EmptyState>
  }

  return (
    <div className="space-y-4">
      {machine && (
        <p className="text-sm text-muted-foreground">
          Showing one machine: <span className="text-foreground">{names.get(machine) ?? "unknown"}</span> ·{" "}
          <Link className="underline" href="/activity">
            show all
          </Link>
        </p>
      )}
      <div className="overflow-hidden rounded-xl border bg-card font-mono text-[0.8rem]">
        <div className="hidden grid-cols-[190px_88px_1fr_120px_150px] gap-4 border-b bg-muted/40 px-4 py-2 font-sans text-xs font-medium text-muted-foreground md:grid">
          <span>Time (UTC)</span>
          <span>Level</span>
          <span>Subject</span>
          <span>Host</span>
          <span>Machine</span>
        </div>
        <div className="divide-y">
          {events.map((e) => {
            const l = level(e.kind, e.decision)
            const detail = (e.body?.detail ?? (e.body?.unmapped as Record<string, unknown> | undefined)?.rv_detail) as Record<string, string> | undefined
            return (
              <div
                key={`${e.machine_id}-${e.uid}`}
                className="grid grid-cols-[88px_1fr] gap-x-4 gap-y-1 px-4 py-2 hover:bg-muted/40 md:grid-cols-[190px_88px_1fr_120px_150px] md:items-center"
              >
                <time dateTime={e.time} className="col-span-2 text-muted-foreground md:col-span-1">
                  {fmt(e.time)}
                </time>
                <span>
                  <span className={cn("rounded px-1.5 py-0.5 text-[10px] font-semibold tracking-wide", l.className)}>{l.label}</span>
                </span>
                <span className="min-w-0 truncate" title={`${e.kind} ${e.subject}`}>
                  {e.subject}
                  <span className="text-muted-foreground">
                    {detail?.would_be && ` → would ${detail.would_be}`}
                    {detail?.override && ` → ${detail.override}`}
                    {e.reason && ` — ${e.reason}`}
                    {!e.kind.startsWith("command.") && ` · ${e.kind}`}
                  </span>
                </span>
                <span className="hidden truncate font-sans text-muted-foreground md:block">{hostLabel(e.host)}</span>
                <Link href={`/machines/${e.machine_id}`} className="hidden truncate font-sans hover:underline md:block">
                  {names.get(e.machine_id) ?? "unknown"}
                </Link>
              </div>
            )
          })}
        </div>
      </div>
      <div className="flex items-center justify-between text-xs text-muted-foreground">
        <span>
          {events.length} events{before ? ` before ${fmt(before)}` : ""}
        </span>
        <div className="flex gap-2">
          {before && (
            <Button variant="ghost" size="sm" render={<Link href="/activity" />}>
              Newest
            </Button>
          )}
          {events.length === PAGE && (
            <Button variant="outline" size="sm" render={<Link href={`/activity?${older}`} scroll={false} />}>
              Older events
            </Button>
          )}
        </div>
      </div>
    </div>
  )
}

export default function ActivityPage({ searchParams }: PageProps<"/activity">) {
  return (
    <>
      <PageHeader
        title="Activity"
        description="Every deny, would-be deny, override and alert forwarded by rv audit forward. Rule ids only, never command text."
        actions={
          <Button variant="outline" render={<a href="/api/export/events" download />}>
            <DownloadIcon />
            Export JSONL
          </Button>
        }
      />
      <PageBody className="space-y-4">
        <Suspense fallback={<div className="h-9" />}>
          <ActivityFilters />
        </Suspense>
        <Suspense fallback={<TableSkeleton rows={10} />}>
          <Feed searchParams={searchParams} />
        </Suspense>
      </PageBody>
    </>
  )
}
