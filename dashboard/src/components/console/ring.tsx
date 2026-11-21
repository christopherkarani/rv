"use client";

import { motion } from "motion/react";
import { CountUp, EASE_OUT } from "@/components/motion/primitives";

/** A single-value ring gauge (part of whole), with the number in the middle. */
export function Ring({ value, total, label, color = "var(--status-good)", size = 112 }: {
  value: number;
  total: number;
  label: string;
  color?: string;
  size?: number;
}) {
  const pct = total > 0 ? value / total : 0;
  const r = 42;
  const c = 2 * Math.PI * r;
  return (
    <div className="relative grid place-items-center" style={{ width: size, height: size }}>
      <svg viewBox="0 0 100 100" className="-rotate-90" width={size} height={size} aria-hidden>
        <circle cx="50" cy="50" r={r} fill="none" stroke="var(--faint)" strokeWidth="9" />
        <circle cx="50" cy="50" r={r} fill="none" stroke="var(--border)" strokeWidth="9" opacity="0.6" />
        <motion.circle
          cx="50" cy="50" r={r} fill="none" stroke={color} strokeWidth="9" strokeLinecap="round"
          strokeDasharray={c}
          initial={{ strokeDashoffset: c }}
          animate={{ strokeDashoffset: c * (1 - pct) }}
          transition={{ duration: 1.1, ease: EASE_OUT, delay: 0.15 }}
        />
      </svg>
      <div className="absolute inset-0 flex flex-col items-center justify-center">
        <span className="text-xl font-semibold tracking-tight">
          <CountUp value={Math.round(pct * 100)} />%
        </span>
        <span className="text-[10.5px] text-muted-foreground">{label}</span>
      </div>
    </div>
  );
}
