"use client";

import { fmtAgo, fmtClock, fmtTime } from "@/lib/format";
import { useNow } from "@/lib/use-now";

const FORMATS = { ago: fmtAgo, time: fmtTime, clock: fmtClock };

/**
 * Renders in UTC on the server and during hydration, then in the viewer's
 * timezone (relative times stay fresh), so there is no hydration mismatch.
 */
export function LocalTime({ ms, format = "ago", className }: { ms: number | null; format?: keyof typeof FORMATS; className?: string }) {
  const now = useNow();
  if (ms == null) return <span className={className}>—</span>;
  const iso = new Date(ms).toISOString();
  const text = now === 0
    ? (format === "clock" ? iso.slice(11, 19) : `${iso.slice(5, 10)} ${iso.slice(11, 16)} UTC`)
    : format === "ago" ? fmtAgo(ms) : FORMATS[format](ms);
  return <time dateTime={iso} title={iso} className={className}>{text}</time>;
}
