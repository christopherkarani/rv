import { cn } from "@/lib/utils"

export function Logo({ className }: { className?: string }) {
  return (
    <span
      className={cn(
        "flex size-6 shrink-0 items-center justify-center rounded-md bg-foreground font-mono text-[11px] font-bold tracking-tight text-background",
        className,
      )}
    >
      rv
    </span>
  )
}
