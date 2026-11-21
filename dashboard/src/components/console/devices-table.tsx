"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { motion } from "motion/react";
import { Apple, Search, Server } from "lucide-react";
import { Input } from "@/components/ui/input";
import { fmtFull } from "@/lib/format";
import { hostLabel } from "@/lib/kinds";
import type { DeviceRow } from "@/lib/types";
import { cn } from "@/lib/utils";
import { SPRING } from "@/components/motion/primitives";
import { ChainBadge, StatusPill } from "./badges";
import { EmptyState } from "./panel";
import { LocalTime } from "./local-time";

const FILTERS = {
  all: { label: "All", test: () => true },
  noncompliant: { label: "Not compliant", test: (d: DeviceRow) => d.compliant === false },
  chain: { label: "Chain issues", test: (d: DeviceRow) => d.chainVerdict === "broken" || d.chainVerdict === "behind" },
  outdated: { label: "Outdated", test: (d: DeviceRow, latest: string | null) => !!latest && !!d.rvVersion && d.rvVersion !== latest },
  stale: { label: "Stale", test: (d: DeviceRow) => d.stale },
  unreported: { label: "No report", test: (d: DeviceRow) => d.reportAt == null },
} as const;
type FilterKey = keyof typeof FILTERS;

export function DevicesTable({ devices, latestVersion, rangeQuery }: { devices: DeviceRow[]; latestVersion: string | null; rangeQuery: string }) {
  const [filter, setFilter] = useState<FilterKey>("all");
  const [q, setQ] = useState("");
  const counts = useMemo(() => Object.fromEntries((Object.keys(FILTERS) as FilterKey[]).map((k) => [k, devices.filter((d) => FILTERS[k].test(d, latestVersion)).length])), [devices, latestVersion]);
  const rows = devices.filter((d) => FILTERS[filter].test(d, latestVersion) && (!q || `${d.hostname} ${d.osUser ?? ""} ${d.rvVersion ?? ""}`.toLowerCase().includes(q.toLowerCase())));
  return (
    <div>
      <div className="flex flex-wrap items-center gap-2 px-4 pb-3">
        <div className="flex flex-wrap gap-1" role="tablist" aria-label="Device filter">
          {(Object.keys(FILTERS) as FilterKey[]).map((k) => (
            <button
              key={k}
              role="tab"
              aria-selected={filter === k}
              type="button"
              onClick={() => setFilter(k)}
              className={cn("relative h-7 rounded-md px-2.5 text-[12px] transition-colors", filter === k ? "text-foreground" : "text-muted-foreground hover:bg-hover hover:text-foreground")}
            >
              {filter === k && <motion.span layoutId="device-filter" transition={SPRING} className="absolute inset-0 rounded-md bg-hover ring-1 ring-border" />}
              <span className="relative">{FILTERS[k].label} <span className="font-mono text-[11px] text-muted-foreground">{counts[k]}</span></span>
            </button>
          ))}
        </div>
        <div className="relative ml-auto w-56">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Find a device…" aria-label="Find a device" className="h-8 bg-faint pl-8 text-[12.5px]" />
        </div>
      </div>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[1040px] text-left text-[12.5px]">
          <thead>
            <tr className="border-y text-[11px] text-muted-foreground">
              <th className="py-2 pr-2 pl-4 font-medium">Device</th>
              <th className="px-2 py-2 font-medium">rv</th>
              <th className="px-2 py-2 font-medium">Org policy</th>
              <th className="px-2 py-2 font-medium">Compliance</th>
              <th className="px-2 py-2 font-medium">Audit chain</th>
              <th className="px-2 py-2 text-right font-medium">Blocked 24h</th>
              <th className="px-2 py-2 font-medium">Agents</th>
              <th className="px-2 py-2 pr-4 font-medium">Last seen</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((d) => {
              const stale = d.stale;
              const outdated = latestVersion && d.rvVersion && d.rvVersion !== latestVersion;
              return (
                <tr key={d.id} className="group border-b border-border/60 transition-colors hover:bg-hover">
                  <td className="py-2 pr-2 pl-4">
                    <Link href={`/fleet/${encodeURIComponent(d.id)}${rangeQuery}`} className="flex items-center gap-2.5">
                      <span className="grid size-7 place-items-center rounded-md border bg-faint">
                        {d.platform === "macos" ? <Apple className="size-3.5" /> : <Server className="size-3.5" />}
                      </span>
                      <span className="min-w-0">
                        <span className="mono block truncate group-hover:underline">{d.hostname}</span>
                        <span className="block text-[11px] text-muted-foreground">{d.osUser ?? "—"} · {d.platform ?? "unknown"}</span>
                      </span>
                    </Link>
                  </td>
                  <td className="px-2 py-2">
                    <span className="font-mono text-[12px]">{d.rvVersion ?? "—"}</span>
                    {outdated && <span className="ml-1.5 rounded bg-status-warning/12 px-1 text-[10.5px] ring-1 ring-status-warning/35 ring-inset">update</span>}
                  </td>
                  <td className="px-2 py-2 text-[12px]">
                    {d.managedState === "active" ? <span>serial <span className="font-mono">{d.policySerial ?? "?"}</span></span>
                      : d.managedState === "invalid" ? <StatusPill status="critical" label="Invalid" />
                      : d.managedState === "none" ? <span className="text-muted-foreground">None</span>
                      : <span className="text-muted-foreground">—</span>}
                  </td>
                  <td className="px-2 py-2">
                    {d.compliant == null ? <StatusPill status="pending" label="No report" /> : d.compliant ? <StatusPill status="good" label="Compliant" /> : <StatusPill status="critical" label="Not compliant" />}
                  </td>
                  <td className="px-2 py-2"><ChainBadge verdict={d.chainVerdict} /></td>
                  <td className="px-2 py-2 text-right font-mono tabular-nums">{fmtFull(d.blocked)}</td>
                  <td className="px-2 py-2 text-[11.5px] text-muted-foreground">{d.hosts.map(hostLabel).join(", ") || "—"}</td>
                  <td className="px-2 py-2 pr-4 text-[11.5px] whitespace-nowrap">
                    {stale ? <StatusPill status="warning" label={<LocalTime ms={d.lastSeen} />} /> : <span className="text-muted-foreground"><LocalTime ms={d.lastSeen} /></span>}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
        {rows.length === 0 && <EmptyState icon={Search} title="No devices match" />}
      </div>
    </div>
  );
}
