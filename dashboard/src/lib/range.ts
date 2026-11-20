/** Time ranges the console offers, with the chart bucket each one uses. */
export const RANGES = {
  "24h": { label: "Last 24 hours", short: "24h", ms: 86_400_000, bucketMs: 3_600_000 },
  "7d": { label: "Last 7 days", short: "7d", ms: 7 * 86_400_000, bucketMs: 4 * 3_600_000 },
  "30d": { label: "Last 30 days", short: "30d", ms: 30 * 86_400_000, bucketMs: 86_400_000 },
  "90d": { label: "Last 90 days", short: "90d", ms: 90 * 86_400_000, bucketMs: 86_400_000 },
} as const;

export type RangeKey = keyof typeof RANGES;
export const DEFAULT_RANGE: RangeKey = "7d";

export function parseRange(value: string | string[] | undefined): RangeKey {
  const v = Array.isArray(value) ? value[0] : value;
  return v && v in RANGES ? (v as RangeKey) : DEFAULT_RANGE;
}
