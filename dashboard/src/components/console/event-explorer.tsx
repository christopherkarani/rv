"use client";

import { withBase } from "@/lib/base-path";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Download, Loader2, Pause, Play, Search, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { fmtFull } from "@/lib/format";
import { hostLabel, kindMeta } from "@/lib/kinds";
import type { EventRow } from "@/lib/types";
import { cn } from "@/lib/utils";
import { LiveDot } from "@/components/motion/primitives";
import { DecisionBadge, EventKindBadge } from "./badges";
import { EventInspector } from "./event-inspector";
import { EmptyState } from "./panel";
import { LocalTime } from "./local-time";

interface Facets {
  kinds: { value: string; count: number }[];
  hosts: { value: string; count: number }[];
  devices: { value: string; label: string }[];
}

const ALL = "__all";

function FilterSelect({ name, value, placeholder, options, onChange, className }: {
  name: string;
  value: string;
  placeholder: string;
  options: { value: string; label: string; count?: number }[];
  onChange: (v: string) => void;
  className?: string;
}) {
  return (
    <Select value={value || ALL} onValueChange={(v) => onChange(v === ALL ? "" : v)}>
      <SelectTrigger aria-label={name} size="sm" className={cn("h-8 bg-faint text-[12.5px]", value && "border-brand/50", className)}>
        <SelectValue placeholder={placeholder} />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value={ALL}>{placeholder}</SelectItem>
        {options.map((o) => (
          <SelectItem key={o.value} value={o.value}>
            <span className="flex w-full items-center justify-between gap-3">
              {o.label}
              {o.count !== undefined && <span className="font-mono text-[11px] text-muted-foreground">{fmtFull(o.count)}</span>}
            </span>
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

export function EventExplorer({ initialRows, total, facets }: { initialRows: EventRow[]; total: number; facets: Facets }) {
  const router = useRouter();
  const pathname = usePathname();
  const params = useSearchParams();
  const [pending, startTransition] = useTransition();
  const [rows, setRows] = useState(initialRows);
  const [count, setCount] = useState(total);
  const [selected, setSelected] = useState<EventRow | null>(null);
  const [loadingMore, setLoadingMore] = useState(false);
  const [live, setLive] = useState(true);
  const [fresh, setFresh] = useState<Set<number>>(new Set());
  const [q, setQ] = useState(params.get("q") ?? "");
  const searchRef = useRef<HTMLInputElement>(null);

  // A new server render (filters changed) replaces the list.
  const [prevInitial, setPrevInitial] = useState(initialRows);
  if (prevInitial !== initialRows) {
    setPrevInitial(initialRows);
    setRows(initialRows);
    setCount(total);
  }

  const filterQS = useMemo(() => {
    const p = new URLSearchParams();
    for (const k of ["q", "kind", "decision", "device", "host", "range"]) {
      const v = params.get(k);
      if (v) p.set(k, v);
    }
    return p.toString();
  }, [params]);

  const setParam = (key: string, value: string) => {
    const p = new URLSearchParams(params.toString());
    if (value) p.set(key, value); else p.delete(key);
    startTransition(() => router.replace(`${pathname}${p.toString() ? `?${p}` : ""}`, { scroll: false }));
  };

  // Debounced search box.
  useEffect(() => {
    if (q === (params.get("q") ?? "")) return;
    const id = setTimeout(() => setParam("q", q.trim()), 280);
    return () => clearTimeout(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q]);

  // "/" focuses search, like most consoles.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "/" && document.activeElement?.tagName !== "INPUT") { e.preventDefault(); searchRef.current?.focus(); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  // Live tail: prepend new matching events.
  useEffect(() => {
    if (!live) return;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout>;
    const tick = async () => {
      const head = rows.reduce((m, r) => Math.max(m, r.seq), 0);
      if (document.visibilityState === "visible") {
        try {
          const res = await fetch(withBase(`/api/v1/events?after=${head}&limit=100${filterQS ? `&${filterQS}` : ""}`), { cache: "no-store" });
          if (res.ok && !stopped) {
            const data = (await res.json()) as { rows: EventRow[] };
            if (data.rows.length) {
              setRows((prev) => [...data.rows, ...prev].slice(0, 1000));
              setCount((c) => c + data.rows.length);
              setFresh(new Set(data.rows.map((r) => r.seq)));
            }
          }
        } catch { /* keep polling */ }
      }
      if (!stopped) timer = setTimeout(tick, 4000);
    };
    timer = setTimeout(tick, 4000);
    return () => { stopped = true; clearTimeout(timer); };
  }, [live, rows, filterQS]);

  const loadMore = async () => {
    const last = rows[rows.length - 1];
    if (!last) return;
    setLoadingMore(true);
    try {
      const res = await fetch(withBase(`/api/v1/events?before=${last.time}:${last.seq}&limit=100${filterQS ? `&${filterQS}` : ""}`), { cache: "no-store" });
      if (res.ok) {
        const data = (await res.json()) as { rows: EventRow[] };
        setRows((prev) => [...prev, ...data.rows]);
      }
    } finally {
      setLoadingMore(false);
    }
  };

  const active = ["kind", "decision", "device", "host", "q"].filter((k) => params.get(k));

  return (
    <div className="rounded-xl border bg-panel">
      <div className="flex flex-wrap items-center gap-2 border-b p-3">
        <div className="relative min-w-56 flex-1">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            ref={searchRef}
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Search rule, host, reason, detail…"
            aria-label="Search events"
            className="h-8 bg-faint pr-8 pl-8 text-[12.5px]"
          />
          {pending ? (
            <Loader2 className="absolute top-1/2 right-2.5 size-3.5 -translate-y-1/2 animate-spin text-muted-foreground" />
          ) : (
            <span className="kbd absolute top-1/2 right-2 -translate-y-1/2">/</span>
          )}
        </div>
        <FilterSelect name="Kind" value={params.get("kind") ?? ""} placeholder="All kinds" onChange={(v) => setParam("kind", v)}
          options={facets.kinds.map((k) => ({ value: k.value, label: kindMeta(k.value).label, count: k.count }))} className="w-44" />
        <FilterSelect name="Decision" value={params.get("decision") ?? ""} placeholder="Any decision" onChange={(v) => setParam("decision", v)}
          options={["denied", "allowed", "pending", "failed", "info"].map((d) => ({ value: d, label: d }))} className="w-36" />
        <FilterSelect name="Agent host" value={params.get("host") ?? ""} placeholder="All agents" onChange={(v) => setParam("host", v)}
          options={facets.hosts.map((h) => ({ value: h.value, label: hostLabel(h.value), count: h.count }))} className="w-40" />
        <FilterSelect name="Device" value={params.get("device") ?? ""} placeholder="All devices" onChange={(v) => setParam("device", v)}
          options={facets.devices.map((d) => ({ value: d.value, label: d.label }))} className="w-44" />
        <div className="ml-auto flex items-center gap-1.5">
          <Button variant="outline" size="sm" onClick={() => setLive((l) => !l)} aria-pressed={live}>
            {live ? <Pause /> : <Play />} {live ? "Live" : "Paused"}
            <LiveDot live={live} className="ml-0.5" />
          </Button>
          <Button variant="outline" size="sm" asChild>
            <a href={withBase(`/api/v1/export?format=csv${filterQS ? `&${filterQS}` : ""}`)}><Download /> CSV</a>
          </Button>
          <Button variant="outline" size="sm" asChild>
            <a href={withBase(`/api/v1/export?format=jsonl${filterQS ? `&${filterQS}` : ""}`)}><Download /> JSONL</a>
          </Button>
        </div>
      </div>

      <div className="flex items-center justify-between gap-2 px-4 py-2 text-[11.5px] text-muted-foreground">
        <span><span className="font-mono text-foreground">{fmtFull(count)}</span> events match</span>
        {active.length > 0 && (
          <button
            type="button"
            className="flex items-center gap-1 rounded px-1.5 py-0.5 hover:bg-hover hover:text-foreground"
            onClick={() => {
              setQ("");
              const p = new URLSearchParams();
              const r = params.get("range");
              if (r) p.set("range", r);
              startTransition(() => router.replace(`${pathname}${p.toString() ? `?${p}` : ""}`));
            }}
          >
            <X className="size-3" /> Clear {active.length} filter{active.length > 1 ? "s" : ""}
          </button>
        )}
      </div>

      <div className={cn("overflow-x-auto transition-opacity", pending && "opacity-60")}>
        <table className="w-full min-w-[880px] text-left text-[12.5px]">
          <thead className="sticky top-0 z-10 bg-panel">
            <tr className="border-y text-[11px] text-muted-foreground">
              <th className="w-40 px-4 py-2 font-medium">Time</th>
              <th className="w-44 px-2 py-2 font-medium">Event</th>
              <th className="px-2 py-2 font-medium">Subject</th>
              <th className="w-20 px-2 py-2 font-medium">Decision</th>
              <th className="w-32 px-2 py-2 font-medium">Agent</th>
              <th className="w-44 px-2 py-2 pr-4 font-medium">Device</th>
            </tr>
          </thead>
          <tbody>
            <AnimatePresence initial={false}>
              {rows.map((e) => (
                <motion.tr
                  key={e.seq}
                  layout="position"
                  initial={fresh.has(e.seq) ? { opacity: 0, y: -6, backgroundColor: "color-mix(in oklab, var(--brand) 16%, transparent)" } : false}
                  animate={{ opacity: 1, y: 0, backgroundColor: "rgba(0,0,0,0)" }}
                  transition={{ duration: 0.35, backgroundColor: { duration: 1.8 } }}
                  onClick={() => setSelected(e)}
                  onKeyDown={(k) => { if (k.key === "Enter") setSelected(e); }}
                  tabIndex={0}
                  className="cursor-pointer border-b border-border/60 outline-none transition-colors hover:bg-hover focus-visible:bg-hover"
                >
                  <td className="px-4 py-2 font-mono text-[11.5px] whitespace-nowrap text-muted-foreground"><LocalTime ms={e.time} format="time" /></td>
                  <td className="px-2 py-2"><EventKindBadge kind={e.kind} decision={e.decision} /></td>
                  <td className="max-w-0 px-2 py-2">
                    <div className="mono truncate">{e.subject}</div>
                    {e.reason && <div className="truncate text-[11.5px] text-muted-foreground">{e.reason}</div>}
                  </td>
                  <td className="px-2 py-2"><DecisionBadge decision={e.decision} /></td>
                  <td className="px-2 py-2 whitespace-nowrap text-muted-foreground">{hostLabel(e.host)}</td>
                  <td className="truncate px-2 py-2 pr-4 font-mono text-[11.5px]">{e.hostname}</td>
                </motion.tr>
              ))}
            </AnimatePresence>
          </tbody>
        </table>
        {rows.length === 0 && (
          <EmptyState icon={Search} title="No events match">Try a wider time range or clear filters.</EmptyState>
        )}
      </div>
      {rows.length > 0 && rows.length < count && (
        <div className="flex justify-center border-t p-3">
          <Button variant="ghost" size="sm" onClick={loadMore} disabled={loadingMore}>
            {loadingMore && <Loader2 className="animate-spin" />} Load older events
          </Button>
        </div>
      )}
      <EventInspector event={selected} onOpenChange={(o) => !o && setSelected(null)} />
    </div>
  );
}
