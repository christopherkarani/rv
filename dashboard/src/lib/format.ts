import { formatDistanceToNowStrict } from "date-fns";

const compact = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
const full = new Intl.NumberFormat("en");

export const fmtNumber = (n: number) => (Math.abs(n) >= 10_000 ? compact.format(n) : full.format(n));
export const fmtFull = (n: number) => full.format(n);

export function fmtAgo(ms: number | null | undefined): string {
  if (!ms) return "never";
  const diff = Date.now() - ms;
  if (diff < 45_000) return "just now";
  return `${formatDistanceToNowStrict(ms)} ago`;
}

export function fmtTime(ms: number): string {
  return new Date(ms).toLocaleString("en", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
}

export function fmtClock(ms: number): string {
  return new Date(ms).toLocaleTimeString("en", { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
}

export function fmtDelta(value: number, previous: number): { text: string; direction: "up" | "down" | "flat" } {
  if (previous === 0) return value === 0 ? { text: "—", direction: "flat" } : { text: "new", direction: "up" };
  const pct = ((value - previous) / previous) * 100;
  if (Math.abs(pct) < 0.5) return { text: "0%", direction: "flat" };
  if (Math.abs(pct) >= 1000) return { text: pct > 0 ? ">10×" : "<-90%", direction: pct > 0 ? "up" : "down" };
  return { text: `${pct > 0 ? "+" : ""}${pct.toFixed(Math.abs(pct) < 10 ? 1 : 0)}%`, direction: pct > 0 ? "up" : "down" };
}

export const shortHash = (h: string | null | undefined, n = 10) => (h ? `${h.slice(0, n)}…` : "—");

export function fmtMs(ms: number | null): string {
  if (ms == null) return "—";
  return ms >= 1000 ? `${(ms / 1000).toFixed(ms >= 10_000 ? 0 : 1)}s` : `${ms}ms`;
}
