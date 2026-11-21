"use client";

import Link from "next/link";
import { Laptop, Link2, Link2Off, Radio, Zap } from "lucide-react";
import { LiveDot } from "@/components/motion/primitives";
import { LocalTime } from "@/components/console/local-time";
import { fmtNumber } from "@/lib/format";
import { useNow } from "@/lib/use-now";
import { cn } from "@/lib/utils";
import type { StatusSnapshot } from "./use-status";

function Item({ className, ...props }: React.ComponentProps<"div">) {
  return <div className={cn("flex h-full items-center gap-1.5 px-2 whitespace-nowrap", className)} {...props} />;
}

/** The editor-style footer: ingest liveness, fleet size, chain health. */
export function StatusBar({ status, version }: { status: StatusSnapshot; version: string }) {
  const now = useNow();
  const live = now !== 0 && status.lastReceived != null && now - status.lastReceived < 10 * 60_000;
  return (
    <footer className="flex h-6 shrink-0 items-center overflow-hidden border-t bg-chrome font-mono text-[11px] whitespace-nowrap text-muted-foreground">
      <Item className={cn(live ? "text-foreground" : "")}>
        <LiveDot live={live} />
        {live ? "Ingest live" : status.lastReceived ? "Ingest idle" : "Waiting for first event"}
      </Item>
      <Item className="hidden sm:flex"><Radio className="size-3" /> last event <LocalTime ms={status.lastReceived} /></Item>
      <Item className="hidden md:flex"><Zap className="size-3" /> {fmtNumber(status.lastHour)} events/h</Item>
      <Link href="/fleet" className="flex h-full items-center gap-1.5 px-2 hover:bg-hover hover:text-foreground">
        <Laptop className="size-3" /> {status.devices}<span className="hidden sm:inline"> devices</span>
      </Link>
      <Link
        href="/integrity"
        className={cn(
          "flex h-full items-center gap-1.5 px-2 hover:bg-hover",
          status.brokenChains > 0 ? "bg-status-critical/15 text-foreground" : "hover:text-foreground",
        )}
      >
        {status.brokenChains > 0 ? <Link2Off className="size-3 text-status-critical" /> : <Link2 className="size-3 text-status-good" />}
        <span className="hidden sm:inline">{status.brokenChains > 0 ? `${status.brokenChains} broken chain${status.brokenChains === 1 ? "" : "s"}` : "chains intact"}</span>
        {status.brokenChains > 0 && <span className="sm:hidden">{status.brokenChains}</span>}
      </Link>
      <div className="flex-1" />
      <Item className="hidden md:flex">⌘K commands</Item>
      <Item className="hidden sm:flex">rv console {version}</Item>
    </footer>
  );
}
