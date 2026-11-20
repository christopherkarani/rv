"use client"

import { useMemo, useState } from "react"
import Link from "next/link"
import { useSearchParams } from "next/navigation"
import { SearchIcon } from "lucide-react"
import { Input } from "@/components/ui/input"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { EmptyState, HostModeBadge, Mono, StatusDot, type Tone } from "@/components/shared"
import type { MachineState } from "@/lib/machine-status"
import { platformLabel, type HostMode } from "@/lib/vocab"

export type MachineListItem = {
  id: string
  name: string
  team: string | null
  platform: string | null
  rvVersion: string | null
  outdated: boolean
  policy: string | null
  policyBad: boolean
  hosts: Partial<Record<string, HostMode>> | null
  lastSeen: string
  lastSeenAt: string | null
  state: MachineState
  label: string
  tone: Exclude<Tone, "info">
  issues: string[]
}

type Filter = "all" | "attention" | "noncompliant" | "silent" | "revoked"
const FILTERS: Record<Filter, (m: MachineListItem) => boolean> = {
  all: (m) => m.state !== "revoked",
  attention: (m) => m.state !== "revoked" && m.issues.length > 0,
  noncompliant: (m) => m.state === "noncompliant",
  silent: (m) => m.state === "silent" || m.state === "pending",
  revoked: (m) => m.state === "revoked",
}
const ORDER: Record<MachineState, number> = { noncompliant: 0, drift: 1, silent: 2, pending: 3, healthy: 4, revoked: 5 }

export function MachinesTable({ items, latestVersion }: { items: MachineListItem[]; latestVersion: string | null }) {
  const param = useSearchParams().get("filter")
  const [filter, setFilter] = useState<Filter>((Object.keys(FILTERS) as Filter[]).find((f) => f === param) ?? "all")
  const [query, setQuery] = useState("")
  const [team, setTeam] = useState("all")
  const teams = useMemo(() => [...new Set(items.map((m) => m.team).filter((t): t is string => Boolean(t)))].sort(), [items])

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase()
    return items
      .filter(FILTERS[filter])
      .filter((m) => team === "all" || m.team === team)
      .filter((m) => !q || m.name.toLowerCase().includes(q) || (m.team ?? "").toLowerCase().includes(q))
      .sort((a, b) => ORDER[a.state] - ORDER[b.state] || a.name.localeCompare(b.name))
  }, [items, filter, team, query])

  if (items.length === 0) {
    return (
      <EmptyState title="No machines enrolled yet">
        Create an enrollment token in <Link href="/settings" className="underline">Settings</Link> and enroll your first machine.
      </EmptyState>
    )
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <Tabs value={filter} onValueChange={(v) => setFilter(v as Filter)}>
          <TabsList className="max-w-full overflow-x-auto">
            <TabsTrigger value="all">All {items.filter(FILTERS.all).length}</TabsTrigger>
            <TabsTrigger value="attention">Attention {items.filter(FILTERS.attention).length}</TabsTrigger>
            <TabsTrigger value="noncompliant">Non-compliant {items.filter(FILTERS.noncompliant).length}</TabsTrigger>
            <TabsTrigger value="silent">Silent {items.filter(FILTERS.silent).length}</TabsTrigger>
            {items.some(FILTERS.revoked) && <TabsTrigger value="revoked">Revoked</TabsTrigger>}
          </TabsList>
        </Tabs>
        <div className="flex gap-2">
          <div className="relative flex-1 md:w-64">
            <SearchIcon className="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search machines…" className="pl-8" aria-label="Search machines" />
          </div>
          {teams.length > 0 && (
            <Select value={team} onValueChange={(v) => setTeam(String(v))}>
              <SelectTrigger className="w-36" aria-label="Team">
                <SelectValue>{(v: string) => (v === "all" ? "All teams" : v)}</SelectValue>
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All teams</SelectItem>
                {teams.map((t) => (
                  <SelectItem key={t} value={t}>
                    {t}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </div>
      </div>

      <div className="overflow-hidden rounded-xl border">
        <Table>
          <TableHeader>
            <TableRow className="bg-muted/40 hover:bg-muted/40">
              <TableHead>Machine</TableHead>
              <TableHead>Status</TableHead>
              <TableHead className="hidden lg:table-cell">Agent hosts</TableHead>
              <TableHead className="hidden md:table-cell">rv</TableHead>
              <TableHead className="hidden md:table-cell">Policy</TableHead>
              <TableHead className="text-right">Last seen</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((m) => (
              <TableRow key={m.id} className="relative">
                <TableCell>
                  <Link href={`/machines/${m.id}`} className="font-medium after:absolute after:inset-0 hover:underline">
                    {m.name}
                  </Link>
                  <div className="text-xs text-muted-foreground">
                    {[m.team, platformLabel(m.platform)].filter(Boolean).join(" · ")}
                  </div>
                </TableCell>
                <TableCell>
                  <div className="flex items-center gap-2">
                    <StatusDot tone={m.tone} />
                    <span className="text-sm">{m.label}</span>
                  </div>
                  {m.issues[0] && <div className="max-w-56 truncate text-xs text-muted-foreground">{m.issues[0]}</div>}
                </TableCell>
                <TableCell className="hidden lg:table-cell">
                  {m.hosts ? (
                    <div className="flex flex-wrap gap-1">
                      {Object.entries(m.hosts).map(([h, mode]) => mode && <HostModeBadge key={h} host={h} mode={mode} compact />)}
                    </div>
                  ) : (
                    <span className="text-xs text-muted-foreground">Not reported</span>
                  )}
                </TableCell>
                <TableCell className="hidden md:table-cell">
                  <Mono className={m.outdated ? "text-warning" : ""}>{m.rvVersion ?? "—"}</Mono>
                </TableCell>
                <TableCell className="hidden text-sm md:table-cell">
                  <span className={m.policyBad ? "text-destructive" : m.policy ? "" : "text-muted-foreground"}>{m.policy ?? "—"}</span>
                </TableCell>
                <TableCell className="text-right text-sm text-muted-foreground">
                  <time dateTime={m.lastSeenAt ?? undefined}>{m.lastSeen}</time>
                </TableCell>
              </TableRow>
            ))}
            {rows.length === 0 && (
              <TableRow>
                <TableCell colSpan={6} className="py-12 text-center text-sm text-muted-foreground">
                  No machines match these filters.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </div>
      <p className="text-xs text-muted-foreground">
        Showing {rows.length} of {items.filter(FILTERS.all).length} machines.
        {latestVersion && (
          <>
            {" "}
            Newest rv in this org: <Mono>{latestVersion}</Mono>.
          </>
        )}
      </p>
    </div>
  )
}
