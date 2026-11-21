"use client";

import { motion } from "motion/react";
import { RANGES, type RangeKey } from "@/lib/range";
import { cn } from "@/lib/utils";
import { SPRING } from "@/components/motion/primitives";
import { useRange } from "./use-range";

/** Segmented range control with a sliding thumb. */
export function RangePicker({ className }: { className?: string }) {
  const { range, setRange } = useRange();
  return (
    <div role="radiogroup" aria-label="Time range" className={cn("flex h-7 items-center rounded-md border bg-faint p-0.5", className)}>
      {(Object.keys(RANGES) as RangeKey[]).map((key) => {
        const active = key === range;
        return (
          <button
            key={key}
            type="button"
            role="radio"
            aria-checked={active}
            title={RANGES[key].label}
            onClick={() => setRange(key)}
            className={cn(
              "relative h-full rounded px-2 font-mono text-[11px] outline-none transition-colors focus-visible:ring-2 focus-visible:ring-ring/60",
              active ? "text-foreground" : "text-muted-foreground hover:text-foreground",
            )}
          >
            {active && <motion.span layoutId="range-thumb" transition={SPRING} className="absolute inset-0 rounded bg-background shadow-sm ring-1 ring-border" />}
            <span className="relative">{RANGES[key].short}</span>
          </button>
        );
      })}
    </div>
  );
}
