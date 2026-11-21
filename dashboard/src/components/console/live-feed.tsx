"use client";

import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Pause, Play } from "lucide-react";
import { hostLabel } from "@/lib/kinds";
import type { EventRow } from "@/lib/types";
import { LiveDot, SPRING } from "@/components/motion/primitives";
import { EventKindBadge } from "./badges";
import { EventInspector } from "./event-inspector";
import { EmptyState } from "./panel";
import { Radio } from "lucide-react";
import { LocalTime } from "./local-time";

/** Newest events, streaming in. Polls only while visible and not paused. */
export function LiveFeed({ initial, limit = 14, query = "" }: { initial: EventRow[]; limit?: number; query?: string }) {
  const [events, setEvents] = useState(initial);
  const [paused, setPaused] = useState(false);
  const [selected, setSelected] = useState<EventRow | null>(null);
  const head = useRef(initial.reduce((m, r) => Math.max(m, r.seq), 0));

  useEffect(() => {
    if (paused) return;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout>;
    const tick = async () => {
      if (document.visibilityState === "visible") {
        try {
          const res = await fetch(`/api/v1/events?after=${head.current}&limit=${limit}${query}`, { cache: "no-store" });
          if (res.ok) {
            const { rows } = (await res.json()) as { rows: EventRow[] };
            if (rows.length && !stopped) {
              head.current = rows[0].seq;
              setEvents((prev) => [...rows, ...prev].slice(0, limit));
            }
          }
        } catch { /* keep polling */ }
      }
      if (!stopped) timer = setTimeout(tick, 3000);
    };
    timer = setTimeout(tick, 3000);
    return () => { stopped = true; clearTimeout(timer); };
  }, [paused, limit, query]);

  return (
    <div>
      <div className="mb-2 flex items-center justify-between px-1">
        <span className="flex items-center gap-2 text-[11.5px] text-muted-foreground">
          <LiveDot live={!paused} /> {paused ? "Paused" : "Streaming"}
        </span>
        <button type="button" onClick={() => setPaused((p) => !p)} className="flex h-6 items-center gap-1 rounded px-1.5 text-[11.5px] text-muted-foreground hover:bg-hover hover:text-foreground">
          {paused ? <Play className="size-3" /> : <Pause className="size-3" />} {paused ? "Resume" : "Pause"}
        </button>
      </div>
      {events.length === 0 ? (
        <EmptyState icon={Radio} title="No events yet">Events appear here seconds after a machine runs <code className="font-mono">rv audit forward</code>.</EmptyState>
      ) : (
        <ul className="relative flex flex-col">
          <AnimatePresence initial={false}>
            {events.map((e) => (
              <motion.li
                key={e.seq}
                layout
                initial={{ opacity: 0, height: 0, backgroundColor: "color-mix(in oklab, var(--brand) 14%, transparent)" }}
                animate={{ opacity: 1, height: "auto", backgroundColor: "rgba(0,0,0,0)" }}
                exit={{ opacity: 0, height: 0 }}
                transition={{ ...SPRING, backgroundColor: { duration: 1.6 } }}
                className="overflow-hidden rounded-md"
              >
                <button
                  type="button"
                  onClick={() => setSelected(e)}
                  className="grid w-full grid-cols-[52px_minmax(0,1fr)] items-start gap-2 rounded-md px-1.5 py-1.5 text-left transition-colors hover:bg-hover"
                >
                  <span className="mono pt-px text-muted-foreground"><LocalTime ms={e.time} format="clock" /></span>
                  <span className="min-w-0">
                    <span className="flex items-center justify-between gap-2">
                      <EventKindBadge kind={e.kind} decision={e.decision} className="text-[12px]" />
                      <span className="truncate text-[11px] text-muted-foreground">{e.hostname}</span>
                    </span>
                    <span className="mono mt-0.5 block truncate text-foreground/85">{e.subject}</span>
                    {e.host && <span className="text-[11px] text-muted-foreground">{hostLabel(e.host)}</span>}
                  </span>
                </button>
              </motion.li>
            ))}
          </AnimatePresence>
        </ul>
      )}
      <EventInspector event={selected} onOpenChange={(o) => !o && setSelected(null)} />
    </div>
  );
}
