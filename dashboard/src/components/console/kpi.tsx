import Link from "next/link";
import { ArrowDownRight, ArrowUpRight, Minus } from "lucide-react";
import { CountUp, SpotlightPanel, StaggerItem } from "@/components/motion/primitives";
import { fmtDelta } from "@/lib/format";
import { TONE_VAR, type Tone } from "@/lib/kinds";
import { cn } from "@/lib/utils";
import { Sparkline } from "./sparkline";

/**
 * A stat tile. `goodWhen` says which direction is good for this metric, so a
 * rise in blocks is not painted as success.
 */
export function KpiCard({ label, value, previous, icon: Icon, tone, spark, href, goodWhen = "neutral", suffix, footnote }: {
  label: string;
  value: number;
  previous?: number;
  icon: React.ComponentType<{ className?: string; strokeWidth?: number }>;
  tone?: Tone;
  spark?: number[];
  href?: string;
  goodWhen?: "up" | "down" | "neutral";
  suffix?: string;
  footnote?: React.ReactNode;
}) {
  const delta = previous === undefined ? null : fmtDelta(value, previous);
  const deltaGood = delta && delta.direction !== "flat" && goodWhen !== "neutral" ? (delta.direction === goodWhen) : null;
  const body = (
    <SpotlightPanel className="h-full p-4 transition-colors hover:border-foreground/15">
      <div className="flex items-center justify-between">
        <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
          {tone && <span className="size-2 rounded-[3px]" style={{ background: TONE_VAR[tone] }} />}
          {label}
        </span>
        <Icon className="kpi-icon size-3.5 text-muted-foreground" strokeWidth={1.75} />
      </div>
      <div className="mt-2.5 flex items-end justify-between gap-2">
        <div className="text-[28px] leading-none font-semibold tracking-tight">
          <CountUp value={value} compact />
          {suffix && <span className="ml-0.5 text-base font-normal text-muted-foreground">{suffix}</span>}
        </div>
        {spark && spark.length > 1 && <Sparkline values={spark} tone={tone ?? "neutral"} className="h-8 w-24" />}
      </div>
      <div className="mt-2 flex items-center gap-1.5 text-[11.5px] text-muted-foreground">
        {delta && (
          <span className={cn("inline-flex items-center gap-0.5 rounded px-1 font-mono",
            deltaGood === true && "bg-status-good/10 text-foreground",
            deltaGood === false && "bg-status-critical/10 text-foreground")}
          >
            {delta.direction === "up" ? <ArrowUpRight className="size-3" /> : delta.direction === "down" ? <ArrowDownRight className="size-3" /> : <Minus className="size-3" />}
            {delta.text}
          </span>
        )}
        {footnote ?? (delta ? <span className="truncate">vs prev<span className="hidden sm:inline">ious period</span></span> : null)}
      </div>
    </SpotlightPanel>
  );
  return (
    <StaggerItem className="min-w-0">
      {href ? <Link href={href} className="block h-full rounded-xl outline-none focus-visible:ring-2 focus-visible:ring-ring">{body}</Link> : body}
    </StaggerItem>
  );
}
