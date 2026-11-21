"use client";

import Link from "next/link";
import { useState } from "react";
import { Check, Copy, ExternalLink } from "lucide-react";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Button } from "@/components/ui/button";
import { hostLabel, kindMeta } from "@/lib/kinds";
import type { EventRow } from "@/lib/types";
import { DecisionBadge, EventKindBadge } from "./badges";
import { LocalTime } from "./local-time";

function CopyButton({ text, label = "Copy" }: { text: string; label?: string }) {
  const [done, setDone] = useState(false);
  return (
    <Button
      variant="ghost"
      size="xs"
      onClick={() => { void navigator.clipboard.writeText(text); setDone(true); setTimeout(() => setDone(false), 1200); }}
    >
      {done ? <Check /> : <Copy />} {done ? "Copied" : label}
    </Button>
  );
}

function Field({ label, children, mono }: { label: string; children: React.ReactNode; mono?: boolean }) {
  return (
    <div className="grid grid-cols-[112px_minmax(0,1fr)] gap-3 border-b border-dashed py-2 text-[12.5px] last:border-0">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className={mono ? "mono break-all" : "break-words"}>{children ?? <span className="text-muted-foreground">—</span>}</dd>
    </div>
  );
}

/** The right-hand inspector, like an editor's side panel. */
export function EventInspector({ event, onOpenChange }: { event: EventRow | null; onOpenChange: (open: boolean) => void }) {
  return (
    <Sheet open={!!event} onOpenChange={onOpenChange}>
      <SheetContent className="w-full gap-0 overflow-y-auto p-0 sm:max-w-lg">
        {event && (
          <>
            <SheetHeader className="border-b bg-chrome px-5 py-4">
              <div className="flex items-center gap-2">
                <EventKindBadge kind={event.kind} decision={event.decision} />
                <DecisionBadge decision={event.decision} />
              </div>
              <SheetTitle className="mono mt-1 text-[14px] break-all">{event.subject}</SheetTitle>
              <SheetDescription>{kindMeta(event.kind).group} · <LocalTime ms={event.time} format="time" /> · {event.hostname}</SheetDescription>
            </SheetHeader>
            <div className="px-5 py-3">
              <dl>
                <Field label="Device">
                  <Link href={`/fleet/${encodeURIComponent(event.deviceId)}`} className="inline-flex items-center gap-1 font-mono text-[12px] underline-offset-4 hover:underline">
                    {event.hostname} <ExternalLink className="size-3" />
                  </Link>
                </Field>
                <Field label="Agent host">{event.host ? `${hostLabel(event.host)} (${event.host})` : null}</Field>
                <Field label="Reason">{event.reason}</Field>
                <Field label="Reason code" mono>{event.reasonCode}</Field>
                <Field label="Workspace" mono>{event.workspace}</Field>
                <Field label="Runtime" mono>{event.runtime}</Field>
                <Field label="Source" mono>{event.source}</Field>
                <Field label="Received"><LocalTime ms={event.receivedAt} format="time" /> via {event.format === "ocsf" ? "OCSF 1.3.0" : "rv.audit.v1"}</Field>
              </dl>
              {Object.keys(event.detail).length > 0 && (
                <>
                  <h3 className="label-caps mt-5 mb-1">Detail</h3>
                  <dl>
                    {Object.entries(event.detail).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => (
                      <Field key={k} label={k} mono>{v}</Field>
                    ))}
                  </dl>
                </>
              )}
              <h3 className="label-caps mt-5 mb-1">Hash chain</h3>
              <dl>
                <Field label="prev" mono>{event.prev}</Field>
                <Field label="head" mono>{event.chainHead}</Field>
              </dl>
              <div className="mt-5 flex items-center justify-between">
                <h3 className="label-caps">Raw</h3>
                <CopyButton text={JSON.stringify(event, null, 2)} label="Copy JSON" />
              </div>
              <pre className="mono mt-2 max-h-80 overflow-auto rounded-lg border bg-chrome p-3 leading-5 text-muted-foreground">
                {JSON.stringify({ ...event, time: new Date(event.time).toISOString(), receivedAt: new Date(event.receivedAt).toISOString() }, null, 2)}
              </pre>
              <p className="mt-3 text-[11px] text-muted-foreground">
                rv never forwards command text, secret values, policy bodies or tool arguments; only rule ids, names, argument names and fingerprints.
              </p>
            </div>
          </>
        )}
      </SheetContent>
    </Sheet>
  );
}
