"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { ArrowDown, ArrowUp, Search } from "lucide-react";
import { Input } from "@/components/ui/input";
import { fmtFull } from "@/lib/format";
import { hostLabel, SEVERITY_ORDER } from "@/lib/kinds";
import type { RuleStat } from "@/lib/types";
import { cn } from "@/lib/utils";
import { SeverityBadge } from "./badges";
import { Sparkline } from "./sparkline";
import { EmptyState } from "./panel";
import { LocalTime } from "./local-time";

type SortKey = "rule" | "severity" | "blocked" | "observed" | "overrides" | "devices" | "lastSeen";
type Sort = { key: SortKey; desc: boolean };

function Head({ k, sort, onSort, children, className }: {
  k: SortKey; sort: Sort; onSort: (k: SortKey) => void; children: React.ReactNode; className?: string;
}) {
  return (
    <th className={cn("px-2 py-2 font-medium whitespace-nowrap", className)} aria-sort={sort.key === k ? (sort.desc ? "descending" : "ascending") : "none"}>
      <button type="button" onClick={() => onSort(k)} className="inline-flex items-center gap-1 hover:text-foreground">
        {children}
        {sort.key === k && (sort.desc ? <ArrowDown className="size-3" /> : <ArrowUp className="size-3" />)}
      </button>
    </th>
  );
}

export function RulesTable({ rules, rangeQuery }: { rules: RuleStat[]; rangeQuery: string }) {
  const [sort, setSort] = useState<Sort>({ key: "blocked", desc: true });
  const [q, setQ] = useState("");
  const rows = useMemo(() => {
    const needle = q.trim().toLowerCase();
    const filtered = needle
      ? rules.filter((r) => `${r.rule} ${r.packName ?? ""} ${r.description ?? ""}`.toLowerCase().includes(needle))
      : rules;
    const value = (r: RuleStat) => (sort.key === "severity" ? SEVERITY_ORDER[r.severity ?? ""] ?? 0 : r[sort.key]);
    return [...filtered].sort((a, b) => {
      const av = value(a);
      const bv = value(b);
      const cmp = typeof av === "string" ? av.localeCompare(String(bv)) : Number(av) - Number(bv);
      return sort.desc ? -cmp : cmp;
    });
  }, [rules, sort, q]);

  const onSort = (k: SortKey) => setSort((s) => ({ key: k, desc: s.key === k ? !s.desc : true }));
  const h = { sort, onSort };

  return (
    <div>
      <div className="relative mx-4 mb-2 max-w-sm">
        <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
        <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Filter rules…" aria-label="Filter rules" className="h-8 bg-faint pl-8 text-[12.5px]" />
      </div>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[980px] text-left text-[12.5px]">
          <thead>
            <tr className="border-y text-[11px] text-muted-foreground">
              <Head {...h} k="rule" className="pl-4">Rule</Head>
              <Head {...h} k="severity">Severity</Head>
              <Head {...h} k="blocked" className="text-right">Blocked</Head>
              <Head {...h} k="observed" className="text-right">Would-be</Head>
              <Head {...h} k="overrides" className="text-right">Overrides</Head>
              <Head {...h} k="devices" className="text-right">Devices</Head>
              <th className="px-2 py-2 font-medium">Agents</th>
              <th className="px-2 py-2 font-medium">Trend</th>
              <Head {...h} k="lastSeen" className="pr-4">Last seen</Head>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.rule} className="group border-b border-border/60 transition-colors hover:bg-hover">
                <td className="max-w-[380px] py-2 pr-2 pl-4">
                  <Link href={`/activity?q=${encodeURIComponent(r.rule)}${rangeQuery}`} className="mono block truncate underline-offset-4 group-hover:underline">{r.rule}</Link>
                  <div className="truncate text-[11.5px] text-muted-foreground" title={r.description ?? undefined}>
                    {r.packName ?? r.pack}{r.description ? ` · ${r.description}` : ""}
                  </div>
                </td>
                <td className="px-2 py-2"><SeverityBadge severity={r.severity} /></td>
                <td className="px-2 py-2 text-right font-mono tabular-nums">{fmtFull(r.blocked)}</td>
                <td className="px-2 py-2 text-right font-mono tabular-nums text-muted-foreground">{fmtFull(r.observed)}</td>
                <td className="px-2 py-2 text-right font-mono tabular-nums text-muted-foreground">{fmtFull(r.overrides)}</td>
                <td className="px-2 py-2 text-right font-mono tabular-nums">{r.devices}</td>
                <td className="px-2 py-2 text-[11.5px] whitespace-nowrap text-muted-foreground" title={r.hosts.map(hostLabel).join(", ")}>{r.hosts.slice(0, 2).map(hostLabel).join(", ")}{r.hosts.length > 2 ? ` +${r.hosts.length - 2}` : ""}</td>
                <td className="px-2 py-2"><Sparkline values={r.trend} tone={r.blocked >= r.observed ? "blocked" : "observed"} className="h-6 w-24" /></td>
                <td className="px-2 py-2 pr-4 text-[11.5px] whitespace-nowrap text-muted-foreground"><LocalTime ms={r.lastSeen} /></td>
              </tr>
            ))}
          </tbody>
        </table>
        {rows.length === 0 && <EmptyState icon={Search} title="No rules fired in this range" />}
      </div>
    </div>
  );
}
