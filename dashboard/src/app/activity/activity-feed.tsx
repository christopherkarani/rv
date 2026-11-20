"use client"

import { useMemo, useState } from "react"
import Link from "next/link"
import { SearchIcon } from "lucide-react"
import { cn } from "@/lib/utils"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { AGENT_HOSTS, EVENTS, HOST_LABEL, fmtTime, machineById, type AuditEvent } from "@/lib/data"

type KindFilter = "all" | "denied" | "observed" | "override" | "other"
const KIND: Record<KindFilter, (e: AuditEvent) => boolean> = {
  all: () => true,
  denied: (e) => e.kind === "command.denied",
  observed: (e) => e.kind === "command.observed",
  override: (e) => e.kind === "command.override",
  other: (e) => e.kind === "secret.misuse" || e.kind === "config.changed" || e.kind === "policy.managed",
}

const LEVEL: Record<AuditEvent["kind"], { label: string; className: string }> = {
  "command.denied": { label: "DENY", className: "bg-destructive/10 text-destructive" },
  "command.observed": { label: "OBSERVE", className: "bg-warning/10 text-warning" },
  "command.override": { label: "OVERRIDE", className: "bg-info/10 text-info" },
  "secret.misuse": { label: "ALERT", className: "bg-destructive text-white" },
  "config.changed": { label: "CONFIG", className: "bg-muted text-muted-foreground" },
  "policy.managed": { label: "POLICY", className: "bg-muted text-muted-foreground" },
}

export function ActivityFeed() {
  const [kind, setKind] = useState<KindFilter>("all")
  const [host, setHost] = useState("all")
  const [query, setQuery] = useState("")
  const [limit, setLimit] = useState(60)

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase()
    return EVENTS.filter(KIND[kind])
      .filter((e) => host === "all" || e.host === host)
      .filter((e) => !q || e.subject.toLowerCase().includes(q) || machineById(e.machineId)!.name.includes(q))
  }, [kind, host, query])

  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <Tabs value={kind} onValueChange={(v) => setKind(v as KindFilter)}>
          <TabsList>
            <TabsTrigger value="all">All</TabsTrigger>
            <TabsTrigger value="denied">Denied</TabsTrigger>
            <TabsTrigger value="observed">Observed</TabsTrigger>
            <TabsTrigger value="override">Overrides</TabsTrigger>
            <TabsTrigger value="other">Alerts &amp; config</TabsTrigger>
          </TabsList>
        </Tabs>
        <div className="flex gap-2">
          <div className="relative flex-1 md:w-64">
            <SearchIcon className="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Rule id or machine…" className="pl-8" />
          </div>
          <Select value={host} onValueChange={(v) => setHost(String(v))}>
            <SelectTrigger className="w-36">
              <SelectValue>{(v: string) => (v === "all" ? "All hosts" : HOST_LABEL[v as keyof typeof HOST_LABEL])}</SelectValue>
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All hosts</SelectItem>
              {AGENT_HOSTS.map((h) => (
                <SelectItem key={h} value={h}>
                  {HOST_LABEL[h]}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      <div className="overflow-hidden rounded-xl border bg-card font-mono text-[0.8rem]">
        <div className="hidden grid-cols-[170px_88px_1fr_120px_140px] gap-4 border-b bg-muted/40 px-4 py-2 font-sans text-xs font-medium text-muted-foreground md:grid">
          <span>Time</span>
          <span>Level</span>
          <span>Rule / subject</span>
          <span>Host</span>
          <span>Machine</span>
        </div>
        <div className="divide-y">
          {rows.slice(0, limit).map((e) => {
            const m = machineById(e.machineId)!
            const level = LEVEL[e.kind]
            return (
              <div key={e.id} className="grid grid-cols-[88px_1fr] gap-x-4 gap-y-1 px-4 py-2 hover:bg-muted/40 md:grid-cols-[170px_88px_1fr_120px_140px] md:items-center">
                <span className="col-span-2 text-muted-foreground md:col-span-1">{fmtTime(e.recordedAt)}</span>
                <span>
                  <span className={cn("rounded px-1.5 py-0.5 text-[10px] font-semibold tracking-wide", level.className)}>{level.label}</span>
                </span>
                <span className="min-w-0 truncate">
                  {e.subject}
                  {e.wouldBe && <span className="text-muted-foreground"> → would {e.wouldBe}</span>}
                  {e.override && <span className="text-muted-foreground"> → {e.override}</span>}
                  {e.detail && <span className="text-muted-foreground"> — {e.detail}</span>}
                </span>
                <span className="hidden truncate font-sans text-muted-foreground md:block">{HOST_LABEL[e.host]}</span>
                <Link href={`/machines/${m.id}`} className="hidden truncate font-sans hover:underline md:block">
                  {m.name}
                </Link>
              </div>
            )
          })}
        </div>
        {rows.length === 0 && <div className="p-10 text-center font-sans text-sm text-muted-foreground">No events match.</div>}
      </div>
      <div className="flex items-center justify-between text-xs text-muted-foreground">
        <span>
          {Math.min(limit, rows.length)} of {rows.length.toLocaleString()} events · 14 days
        </span>
        {limit < rows.length && (
          <Button variant="outline" size="sm" onClick={() => setLimit((l) => l + 100)}>
            Load more
          </Button>
        )}
      </div>
    </div>
  )
}
