"use client"

import { useMemo, useState } from "react"
import Link from "next/link"
import { useSearchParams } from "next/navigation"
import { SearchIcon } from "lucide-react"
import { Input } from "@/components/ui/input"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { HostModeBadge, Mono, StatusDot } from "@/components/shared"
import {
  LATEST_VERSION,
  MACHINES,
  PLATFORM_LABEL,
  TEAMS,
  isOnline,
  timeAgo,
  type AgentHost,
  type HostMode,
  type Machine,
} from "@/lib/data"

type Filter = "all" | "drift" | "noncompliant" | "offline"

const FILTERS: Record<Filter, (m: Machine) => boolean> = {
  all: () => true,
  drift: (m) => m.drift.length > 0,
  noncompliant: (m) => !m.compliant,
  offline: (m) => !isOnline(m),
}

const VALID: Filter[] = ["all", "drift", "noncompliant", "offline"]

export function MachinesTable() {
  const param = useSearchParams().get("filter")
  const initialFilter = VALID.find((v) => v === param) ?? "all"
  const [query, setQuery] = useState("")
  const [team, setTeam] = useState<string>("all")
  const [filter, setFilter] = useState<Filter>(initialFilter)

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase()
    return MACHINES.filter(FILTERS[filter])
      .filter((m) => team === "all" || m.team === team)
      .filter((m) => !q || m.name.includes(q) || m.user.includes(q) || m.team.toLowerCase().includes(q))
      .sort((a, b) => Number(a.compliant) - Number(b.compliant) || b.drift.length - a.drift.length || b.lastSeen - a.lastSeen)
  }, [query, team, filter])

  const count = (f: Filter) => MACHINES.filter(FILTERS[f]).length

  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <Tabs value={filter} onValueChange={(v) => setFilter(v as Filter)}>
          <TabsList>
            <TabsTrigger value="all">All {count("all")}</TabsTrigger>
            <TabsTrigger value="drift">Drift {count("drift")}</TabsTrigger>
            <TabsTrigger value="noncompliant">Non-compliant {count("noncompliant")}</TabsTrigger>
            <TabsTrigger value="offline">Silent {count("offline")}</TabsTrigger>
          </TabsList>
        </Tabs>
        <div className="flex gap-2">
          <div className="relative flex-1 md:w-64">
            <SearchIcon className="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search machines…" className="pl-8" />
          </div>
          <Select value={team} onValueChange={(v) => setTeam(String(v))}>
            <SelectTrigger className="w-36">
              <SelectValue>{(v: string) => (v === "all" ? "All teams" : v)}</SelectValue>
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">All teams</SelectItem>
              {TEAMS.map((t) => (
                <SelectItem key={t} value={t}>
                  {t}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
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
            {rows.map((m) => {
              const online = isOnline(m)
              return (
                <TableRow key={m.id} className="relative">
                  <TableCell>
                    <Link href={`/machines/${m.id}`} className="font-medium after:absolute after:inset-0 hover:underline">
                      {m.name}
                    </Link>
                    <div className="text-xs text-muted-foreground">
                      {m.team} · {PLATFORM_LABEL[m.platform]}
                    </div>
                  </TableCell>
                  <TableCell>
                    <div className="flex items-center gap-2">
                      <StatusDot tone={!online ? "neutral" : !m.compliant ? "error" : m.drift.length ? "warning" : "success"} />
                      <span className="text-sm">{!online ? "Silent" : !m.compliant ? "Non-compliant" : m.drift.length ? "Drift" : "Healthy"}</span>
                    </div>
                    {m.drift.length > 0 && <div className="max-w-48 truncate text-xs text-muted-foreground">{m.drift[0]}</div>}
                  </TableCell>
                  <TableCell className="hidden lg:table-cell">
                    <div className="flex flex-wrap gap-1">
                      {(Object.entries(m.hosts) as [AgentHost, HostMode][]).map(([h, mode]) => (
                        <HostModeBadge key={h} host={h} mode={mode} compact />
                      ))}
                    </div>
                  </TableCell>
                  <TableCell className="hidden md:table-cell">
                    <Mono className={m.rvVersion === LATEST_VERSION ? "" : "text-warning"}>{m.rvVersion}</Mono>
                  </TableCell>
                  <TableCell className="hidden md:table-cell text-sm">
                    {m.managed.status === "verified" ? (
                      <span>serial {m.managed.serial}</span>
                    ) : (
                      <span className={m.managed.status === "invalid" ? "text-destructive" : "text-muted-foreground"}>{m.managed.status}</span>
                    )}
                  </TableCell>
                  <TableCell className="text-right text-sm text-muted-foreground">{timeAgo(m.lastSeen)}</TableCell>
                </TableRow>
              )
            })}
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
        Showing {rows.length} of {MACHINES.length} machines. Status mirrors the <Mono>compliant</Mono> flag in each machine&apos;s <Mono>rv report</Mono>.
      </p>
    </div>
  )
}
