import { CircleCheck, CircleDashed, CircleX, Clock, Link2, Link2Off, TriangleAlert } from "lucide-react";
import { eventTone, kindMeta, TONE_VAR, type Tone } from "@/lib/kinds";
import { cn } from "@/lib/utils";
import type { ChainVerdict } from "@/lib/types";

export function ToneDot({ tone, className }: { tone: Tone; className?: string }) {
  return <span aria-hidden className={cn("inline-block size-2 shrink-0 rounded-[3px]", className)} style={{ background: TONE_VAR[tone] }} />;
}

/** Kind + decision: the colored mark carries identity, the text stays ink. */
export function EventKindBadge({ kind, decision, className }: { kind: string; decision: string; className?: string }) {
  const tone = eventTone(kind, decision);
  return (
    <span className={cn("inline-flex items-center gap-1.5 text-[12.5px] whitespace-nowrap", className)}>
      <ToneDot tone={tone} />
      {kindMeta(kind).label}
    </span>
  );
}

export function DecisionBadge({ decision }: { decision: string }) {
  const styles: Record<string, string> = {
    denied: "bg-series-blocked/12 ring-series-blocked/35",
    allowed: "bg-status-good/10 ring-status-good/30",
    pending: "bg-status-warning/12 ring-status-warning/35",
    failed: "bg-status-critical/12 ring-status-critical/35",
    info: "bg-faint ring-border",
  };
  return (
    <span className={cn("inline-flex h-5 items-center rounded px-1.5 font-mono text-[10.5px] ring-1 ring-inset", styles[decision] ?? styles.info)}>
      {decision}
    </span>
  );
}

const SEVERITY_STYLE: Record<string, string> = {
  critical: "bg-status-critical/14 ring-status-critical/40",
  high: "bg-status-serious/14 ring-status-serious/40",
  medium: "bg-status-warning/12 ring-status-warning/35",
  low: "bg-faint ring-border",
};

export function SeverityBadge({ severity }: { severity: string | null }) {
  if (!severity) return <span className="text-xs text-muted-foreground">—</span>;
  return <span className={cn("inline-flex h-5 items-center rounded px-1.5 text-[11px] capitalize ring-1 ring-inset", SEVERITY_STYLE[severity] ?? SEVERITY_STYLE.low)}>{severity}</span>;
}

/** Status always ships icon + label, never color alone. */
export function StatusPill({ status, label, className }: {
  status: "good" | "warning" | "critical" | "neutral" | "pending";
  label: React.ReactNode;
  className?: string;
}) {
  const map = {
    good: { icon: CircleCheck, color: "text-status-good", ring: "ring-status-good/30 bg-status-good/8" },
    warning: { icon: TriangleAlert, color: "text-status-warning", ring: "ring-status-warning/35 bg-status-warning/8" },
    critical: { icon: CircleX, color: "text-status-critical", ring: "ring-status-critical/35 bg-status-critical/10" },
    pending: { icon: Clock, color: "text-muted-foreground", ring: "ring-border bg-faint" },
    neutral: { icon: CircleDashed, color: "text-muted-foreground", ring: "ring-border bg-faint" },
  }[status];
  const Icon = map.icon;
  return (
    <span className={cn("inline-flex h-5 items-center gap-1 rounded-full px-2 text-[11.5px] whitespace-nowrap ring-1 ring-inset", map.ring, className)}>
      <Icon className={cn("size-3", map.color)} />
      {label}
    </span>
  );
}

export function ChainBadge({ verdict }: { verdict: ChainVerdict }) {
  const map: Record<ChainVerdict, { label: string; icon: typeof Link2; cls: string; color: string }> = {
    intact: { label: "Intact", icon: Link2, cls: "ring-status-good/30 bg-status-good/8", color: "text-status-good" },
    broken: { label: "Broken", icon: Link2Off, cls: "ring-status-critical/40 bg-status-critical/12", color: "text-status-critical" },
    behind: { label: "Behind", icon: Clock, cls: "ring-status-warning/35 bg-status-warning/8", color: "text-status-warning" },
    unchained: { label: "No chain", icon: CircleDashed, cls: "ring-border bg-faint", color: "text-muted-foreground" },
  };
  const m = map[verdict];
  return (
    <span className={cn("inline-flex h-5 items-center gap-1 rounded-full px-2 text-[11.5px] ring-1 ring-inset", m.cls)}>
      <m.icon className={cn("size-3", m.color)} /> {m.label}
    </span>
  );
}

export function HostChip({ host }: { host: string }) {
  return <span className="inline-flex h-5 items-center rounded border bg-faint px-1.5 font-mono text-[10.5px] text-muted-foreground">{host}</span>;
}
