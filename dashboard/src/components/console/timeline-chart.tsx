"use client";

import { useMemo, useState } from "react";
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { fmtFull, fmtNumber } from "@/lib/format";
import { TONE_VAR, type Tone } from "@/lib/kinds";
import type { TimelinePoint } from "@/lib/types";
import { cn } from "@/lib/utils";

/** Fixed series order, validated for CVD separation in both themes. */
const SERIES: { key: keyof Omit<TimelinePoint, "t">; label: string; tone: Tone }[] = [
  { key: "blocked", label: "Blocked", tone: "blocked" },
  { key: "overrides", label: "Overrides", tone: "override" },
  { key: "observed", label: "Would-be blocks", tone: "observed" },
  { key: "mcp", label: "MCP calls", tone: "mcp" },
];

function tickFormat(bucketMs: number) {
  return (t: number) => {
    const d = new Date(t);
    return bucketMs < 86_400_000
      ? d.toLocaleString("en", { weekday: bucketMs > 3_600_000 ? "short" : undefined, hour: "2-digit", hour12: false })
      : d.toLocaleDateString("en", { month: "short", day: "numeric" });
  };
}

/**
 * Stacked bars per time bucket. The legend carries each series' total and
 * toggles it; MCP starts hidden because its volume dwarfs blocks.
 */
export function TimelineChart({ data, bucketMs, height = 260, initialHidden = ["mcp"] }: {
  data: TimelinePoint[];
  bucketMs: number;
  height?: number;
  initialHidden?: string[];
}) {
  const [hidden, setHidden] = useState<Set<string>>(new Set(initialHidden));
  const totals = useMemo(() => Object.fromEntries(SERIES.map((s) => [s.key, data.reduce((n, p) => n + p[s.key], 0)])), [data]);
  const visible = SERIES.filter((s) => !hidden.has(s.key));
  const fmt = tickFormat(bucketMs);
  return (
    <div>
      <div className="mb-3 flex flex-wrap gap-1.5" role="group" aria-label="Series">
        {SERIES.map((s) => {
          const off = hidden.has(s.key);
          return (
            <button
              key={s.key}
              type="button"
              aria-pressed={!off}
              onClick={() => setHidden((h) => {
                const next = new Set(h);
                if (next.has(s.key)) next.delete(s.key); else next.add(s.key);
                return next;
              })}
              className={cn(
                "flex h-7 items-center gap-2 rounded-md border px-2 text-[12px] transition-all",
                off ? "border-dashed text-muted-foreground opacity-60 hover:opacity-100" : "bg-faint hover:bg-hover",
              )}
            >
              <span className="size-2 rounded-[3px]" style={{ background: off ? "transparent" : TONE_VAR[s.tone], outline: off ? `1px solid ${TONE_VAR[s.tone]}` : undefined }} />
              {s.label}
              <span className="font-mono text-[11px] text-muted-foreground tabular-nums">{fmtNumber(totals[s.key])}</span>
            </button>
          );
        })}
      </div>
      <div style={{ height }} className="-ml-2">
        <ResponsiveContainer width="100%" height="100%">
          <BarChart data={data} barCategoryGap="18%" margin={{ top: 4, right: 4, bottom: 0, left: 0 }}>
            <CartesianGrid vertical={false} stroke="var(--grid)" strokeDasharray="0" />
            <XAxis
              dataKey="t"
              tickFormatter={fmt}
              tickLine={false}
              axisLine={{ stroke: "var(--axis)" }}
              tick={{ fill: "var(--muted-foreground)", fontSize: 11 }}
              minTickGap={28}
            />
            <YAxis
              width={40}
              tickLine={false}
              axisLine={false}
              allowDecimals={false}
              tickFormatter={(v: number) => fmtNumber(v)}
              tick={{ fill: "var(--muted-foreground)", fontSize: 11 }}
            />
            <Tooltip
              cursor={{ fill: "var(--hover)" }}
              animationDuration={120}
              content={({ active, payload, label }) => {
                if (!active || !payload?.length) return null;
                const point = payload[0].payload as TimelinePoint;
                return (
                  <div className="min-w-44 rounded-lg border bg-popover/95 px-3 py-2 text-xs shadow-xl backdrop-blur">
                    <div className="mb-1.5 font-mono text-[11px] text-muted-foreground">
                      {new Date(Number(label)).toLocaleString("en", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false })}
                    </div>
                    {visible.map((s) => (
                      <div key={s.key} className="flex items-center justify-between gap-4 py-0.5">
                        <span className="flex items-center gap-1.5"><span className="size-2 rounded-[3px]" style={{ background: TONE_VAR[s.tone] }} />{s.label}</span>
                        <span className="font-mono tabular-nums">{fmtFull(point[s.key])}</span>
                      </div>
                    ))}
                  </div>
                );
              }}
            />
            {visible.map((s, i) => (
              <Bar
                key={s.key}
                dataKey={s.key}
                stackId="a"
                fill={TONE_VAR[s.tone]}
                stroke="var(--panel)"
                strokeWidth={1}
                radius={i === visible.length - 1 ? [3, 3, 0, 0] : [0, 0, 0, 0]}
                animationDuration={700}
                animationEasing="ease-out"
                isAnimationActive
              />
            ))}
          </BarChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}
