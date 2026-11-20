import { cn } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import { hostLabel, type HostMode } from "@/lib/vocab"

export function PageHeader({
  title,
  description,
  actions,
}: {
  title: string
  description?: React.ReactNode
  actions?: React.ReactNode
}) {
  return (
    <div className="border-b bg-muted/30">
      <div className="mx-auto flex max-w-6xl flex-col gap-4 px-4 py-8 sm:flex-row sm:items-end sm:justify-between sm:px-6 sm:py-10">
        <div className="min-w-0">
          <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">{title}</h1>
          {description && <p className="mt-1.5 max-w-2xl text-sm text-muted-foreground">{description}</p>}
        </div>
        {actions && <div className="flex shrink-0 flex-wrap gap-2">{actions}</div>}
      </div>
    </div>
  )
}

export function PageBody({ children, className }: { children: React.ReactNode; className?: string }) {
  return <div className={cn("mx-auto max-w-6xl px-4 py-8 sm:px-6", className)}>{children}</div>
}

export type Tone = "success" | "warning" | "error" | "neutral" | "info"
const DOT: Record<Tone, string> = {
  success: "bg-success",
  warning: "bg-warning",
  error: "bg-destructive",
  neutral: "bg-muted-foreground/40",
  info: "bg-info",
}

export function StatusDot({ tone, pulse }: { tone: Tone; pulse?: boolean }) {
  return (
    <span className="relative inline-flex size-2.5 shrink-0">
      {pulse && <span className={cn("absolute inset-0 animate-ping rounded-full opacity-60", DOT[tone])} />}
      <span className={cn("relative inline-flex size-2.5 rounded-full", DOT[tone])} />
    </span>
  )
}

export function Status({ tone, children, pulse }: { tone: Tone; children: React.ReactNode; pulse?: boolean }) {
  return (
    <span className="inline-flex items-center gap-2 text-sm">
      <StatusDot tone={tone} pulse={pulse} />
      {children}
    </span>
  )
}

const MODE_STYLE: Record<HostMode, string> = {
  block: "border-success/30 bg-success/10 text-success",
  observe: "border-warning/30 bg-warning/10 text-warning",
  off: "border-destructive/30 bg-destructive/10 text-destructive",
}

export function HostModeBadge({ host, mode, compact }: { host: string; mode: HostMode; compact?: boolean }) {
  return (
    <Badge variant="outline" className={cn("gap-1 font-normal", MODE_STYLE[mode])}>
      {compact ? host : hostLabel(host)}
      <span className="opacity-70">· {mode}</span>
    </Badge>
  )
}

export function SeverityBadge({ severity }: { severity: string }) {
  return (
    <Badge
      variant="outline"
      className={cn(
        "font-normal capitalize",
        severity === "critical" ? "border-destructive/30 text-destructive" : "border-warning/30 text-warning",
      )}
    >
      {severity}
    </Badge>
  )
}

export function Mono({ children, className }: { children: React.ReactNode; className?: string }) {
  return <code className={cn("font-mono text-[0.8rem]", className)}>{children}</code>
}

export function Stat({
  label,
  value,
  sub,
  tone,
}: {
  label: string
  value: React.ReactNode
  sub?: React.ReactNode
  tone?: Tone
}) {
  return (
    <div className="flex flex-col gap-1 bg-card p-5">
      <div className="flex items-center gap-2 text-sm text-muted-foreground">
        {tone && <StatusDot tone={tone} />}
        {label}
      </div>
      <div className="text-3xl font-semibold tabular-nums tracking-tight">{value}</div>
      {sub && <div className="text-xs text-muted-foreground">{sub}</div>}
    </div>
  )
}

export function StatGrid({ children }: { children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-1 gap-px overflow-hidden rounded-xl border bg-border sm:grid-cols-2 lg:grid-cols-4">
      {children}
    </div>
  )
}

export function Section({
  title,
  description,
  action,
  children,
  className,
}: {
  title: string
  description?: React.ReactNode
  action?: React.ReactNode
  children: React.ReactNode
  className?: string
}) {
  return (
    <section className={cn("min-w-0 space-y-3", className)}>
      <div className="flex items-end justify-between gap-4">
        <div>
          <h2 className="text-base font-semibold tracking-tight">{title}</h2>
          {description && <p className="text-sm text-muted-foreground">{description}</p>}
        </div>
        {action}
      </div>
      {children}
    </section>
  )
}

export function Skeleton({ className }: { className?: string }) {
  return <div className={cn("animate-pulse rounded-md bg-muted", className)} />
}

export function TableSkeleton({ rows = 6 }: { rows?: number }) {
  return (
    <div className="space-y-px overflow-hidden rounded-xl border">
      {Array.from({ length: rows }, (_, i) => (
        <div key={i} className="flex items-center gap-4 bg-card p-4">
          <Skeleton className="h-4 w-40" />
          <Skeleton className="h-4 flex-1" />
          <Skeleton className="h-4 w-16" />
        </div>
      ))}
    </div>
  )
}

export function EmptyState({ title, children, action }: { title: string; children?: React.ReactNode; action?: React.ReactNode }) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed px-6 py-14 text-center">
      <div className="font-medium">{title}</div>
      {children && <div className="max-w-md text-sm text-muted-foreground">{children}</div>}
      {action && <div className="mt-2">{action}</div>}
    </div>
  )
}

export function ErrorNote({ children }: { children: React.ReactNode }) {
  return <p className="rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">{children}</p>
}
