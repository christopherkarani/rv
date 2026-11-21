"use client";

import { useState } from "react";
import { hostLabel } from "@/lib/kinds";
import type { EventRow } from "@/lib/types";
import { DecisionBadge, EventKindBadge } from "./badges";
import { EventInspector } from "./event-inspector";
import { EmptyState } from "./panel";
import { LocalTime } from "./local-time";

/** A compact, clickable list of events with the inspector. `render` adds a per-row line. */
export function EventList({ events, empty = "Nothing in this range", detail }: {
  events: EventRow[];
  empty?: string;
  detail?: "change" | "reason";
}) {
  const [selected, setSelected] = useState<EventRow | null>(null);
  if (!events.length) return <EmptyState title={empty} />;
  return (
    <>
      <ul className="flex flex-col">
        {events.map((e) => {
          const loosening = e.detail.direction === "loosening";
          const unauthorized = loosening && (e.detail.authorized_by ?? "none") === "none";
          return (
            <li key={e.seq}>
              <button type="button" onClick={() => setSelected(e)} className="grid w-full grid-cols-[minmax(0,1fr)_auto] gap-3 rounded-md px-2 py-2 text-left transition-colors hover:bg-hover">
                <span className="min-w-0">
                  <span className="flex flex-wrap items-center gap-2">
                    <EventKindBadge kind={e.kind} decision={e.decision} />
                    <span className="mono truncate text-foreground/85">{e.subject}</span>
                    {detail === "change" && e.detail.direction && (
                      <span className={`rounded px-1.5 text-[10.5px] ring-1 ring-inset ${loosening ? "bg-status-serious/12 ring-status-serious/40" : "bg-status-good/10 ring-status-good/30"}`}>
                        {loosening ? "↓ loosening" : "↑ tightening"}
                      </span>
                    )}
                    {unauthorized && <span className="rounded bg-status-critical/14 px-1.5 text-[10.5px] ring-1 ring-status-critical/40 ring-inset">no owner auth</span>}
                  </span>
                  <span className="mt-0.5 block truncate text-[11.5px] text-muted-foreground">
                    {detail === "change" && (e.detail.prior || e.detail.new)
                      ? <><span className="font-mono">{e.detail.prior ?? "—"}</span> → <span className="font-mono">{e.detail.new ?? "—"}</span>{e.detail.authorized_by ? ` · by ${e.detail.authorized_by}` : ""}</>
                      : e.reason ?? (e.host ? hostLabel(e.host) : e.source)}
                  </span>
                </span>
                <span className="flex flex-col items-end gap-1">
                  <DecisionBadge decision={e.decision} />
                  <span className="text-[11px] whitespace-nowrap text-muted-foreground">{e.hostname} · <LocalTime ms={e.time} /></span>
                </span>
              </button>
            </li>
          );
        })}
      </ul>
      <EventInspector event={selected} onOpenChange={(o) => !o && setSelected(null)} />
    </>
  );
}
