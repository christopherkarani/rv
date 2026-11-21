import { cn } from "@/lib/utils";

/** rv's console mark: a gate bar across a rounded square. */
export function RvMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden className={cn("shrink-0", className)}>
      <defs>
        <linearGradient id="rv-mark" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="var(--brand)" />
          <stop offset="1" stopColor="var(--series-override)" />
        </linearGradient>
      </defs>
      <rect x="1.5" y="1.5" width="21" height="21" rx="6" fill="url(#rv-mark)" />
      <path d="M7 16.5V9.8c0-1 .8-1.8 1.8-1.8H11" stroke="#fff" strokeWidth="2" strokeLinecap="round" fill="none" />
      <path d="M12.5 8l2.6 8.5L17.7 8" stroke="#fff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" fill="none" />
    </svg>
  );
}
