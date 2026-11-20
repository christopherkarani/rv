"use client"

import { useEffect, useState, useTransition } from "react"
import { usePathname, useRouter, useSearchParams } from "next/navigation"
import { SearchIcon } from "lucide-react"
import { Input } from "@/components/ui/input"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { AGENT_HOSTS, hostLabel } from "@/lib/vocab"

export function ActivityFilters() {
  const router = useRouter()
  const pathname = usePathname()
  const params = useSearchParams()
  const [pending, start] = useTransition()
  const [q, setQ] = useState(params.get("q") ?? "")

  function update(key: string, value: string | null) {
    const next = new URLSearchParams(params)
    if (value && value !== "all") next.set(key, value)
    else next.delete(key)
    next.delete("before")
    start(() => router.replace(`${pathname}?${next}`, { scroll: false }))
  }

  useEffect(() => {
    const t = setTimeout(() => {
      if ((params.get("q") ?? "") !== q) update("q", q.trim() || null)
    }, 300)
    return () => clearTimeout(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q])

  return (
    <div className={`flex flex-col gap-3 md:flex-row md:items-center md:justify-between ${pending ? "opacity-70" : ""}`}>
      <Tabs value={params.get("kind") ?? "all"} onValueChange={(v) => update("kind", String(v))}>
        <TabsList className="max-w-full overflow-x-auto">
          <TabsTrigger value="all">All</TabsTrigger>
          <TabsTrigger value="denied">Denied</TabsTrigger>
          <TabsTrigger value="observed">Observed</TabsTrigger>
          <TabsTrigger value="override">Overrides</TabsTrigger>
          <TabsTrigger value="mcp">MCP</TabsTrigger>
          <TabsTrigger value="alerts">Alerts &amp; config</TabsTrigger>
        </TabsList>
      </Tabs>
      <div className="flex gap-2">
        <div className="relative flex-1 md:w-64">
          <SearchIcon className="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Rule or subject…" className="pl-8" aria-label="Filter by rule or subject" />
        </div>
        <Select value={params.get("host") ?? "all"} onValueChange={(v) => update("host", String(v))}>
          <SelectTrigger className="w-36" aria-label="Agent host">
            <SelectValue>{(v: string) => (v === "all" ? "All hosts" : hostLabel(v))}</SelectValue>
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">All hosts</SelectItem>
            {[...AGENT_HOSTS, "tty"].map((h) => (
              <SelectItem key={h} value={h}>
                {hostLabel(h)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
    </div>
  )
}
