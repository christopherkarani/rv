"use client";

import Link from "next/link";
import { motion } from "motion/react";
import { fmtNumber } from "@/lib/format";
import { TONE_VAR, type Tone } from "@/lib/kinds";
import { EASE_OUT } from "@/components/motion/primitives";

export interface BarListItem {
  key: string;
  label: React.ReactNode;
  sublabel?: React.ReactNode;
  /** Stacked segments in fixed order; each carries its tone. */
  segments: { tone: Tone; value: number; label: string }[];
  href?: string;
}

/**
 * Horizontal ranked bars. Values are direct-labeled at the end, so color is
 * never the only carrier; segments keep a 2px gap.
 */
export function BarList({ items, max }: { items: BarListItem[]; max?: number }) {
  const top = max ?? Math.max(1, ...items.map((i) => i.segments.reduce((s, x) => s + x.value, 0)));
  return (
    <ul className="flex flex-col gap-1">
      {items.map((item, index) => {
        const total = item.segments.reduce((s, x) => s + x.value, 0);
        const row = (
          <div className="group/row relative grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 rounded-md px-2 py-1.5 transition-colors hover:bg-hover">
            <div className="min-w-0">
              <div className="flex items-baseline gap-2">
                <span className="truncate text-[12.5px]">{item.label}</span>
                {item.sublabel && <span className="truncate text-[11px] text-muted-foreground">{item.sublabel}</span>}
              </div>
              <div className="mt-1 flex h-1.5 gap-[2px] overflow-hidden rounded-full bg-faint">
                {item.segments.filter((s) => s.value > 0).map((s, i) => (
                  <motion.div
                    key={s.label}
                    title={`${s.label}: ${s.value}`}
                    initial={{ width: 0 }}
                    animate={{ width: `${(s.value / top) * 100}%` }}
                    transition={{ duration: 0.7, delay: 0.05 * index + 0.04 * i, ease: EASE_OUT }}
                    className="h-full rounded-full"
                    style={{ background: TONE_VAR[s.tone] }}
                  />
                ))}
              </div>
            </div>
            <span className="font-mono text-[12px] tabular-nums">{fmtNumber(total)}</span>
          </div>
        );
        return <li key={item.key}>{item.href ? <Link href={item.href} className="block outline-none focus-visible:ring-2 focus-visible:ring-ring rounded-md">{row}</Link> : row}</li>;
      })}
    </ul>
  );
}
