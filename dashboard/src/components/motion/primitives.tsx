"use client";

import * as React from "react";
import { animate, motion, useMotionTemplate, useMotionValue, useReducedMotion, type HTMLMotionProps } from "motion/react";
import { cn } from "@/lib/utils";

/** The console's one spring: quick, no bounce, editor-snappy. */
export const SPRING = { type: "spring", stiffness: 420, damping: 38, mass: 0.8 } as const;
export const EASE_OUT = [0.22, 1, 0.36, 1] as const;

/** Children fade and rise in sequence. */
export function Stagger({ className, children, delay = 0, ...props }: HTMLMotionProps<"div"> & { delay?: number }) {
  return (
    <motion.div
      className={className}
      initial="hidden"
      animate="show"
      variants={{ hidden: {}, show: { transition: { staggerChildren: 0.045, delayChildren: delay } } }}
      {...props}
    >
      {children}
    </motion.div>
  );
}

export function StaggerItem({ className, ...props }: HTMLMotionProps<"div">) {
  return (
    <motion.div
      className={className}
      variants={{
        hidden: { opacity: 0, y: 8, filter: "blur(4px)" },
        show: { opacity: 1, y: 0, filter: "blur(0px)", transition: { duration: 0.42, ease: EASE_OUT } },
      }}
      {...props}
    />
  );
}

/** A number that counts to its value and re-counts when it changes. */
const plain = (n: number) => Math.round(n).toLocaleString("en");
const compactFmt = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
const compact = (n: number) => (Math.abs(n) >= 10_000 ? compactFmt.format(Math.round(n)) : plain(n));

/** `compact` shortens 10,000+ to 10K; serializable so server components can pass it. */
export function CountUp({ value, compact: useCompact = false, className }: {
  value: number;
  compact?: boolean;
  className?: string;
}) {
  const format = useCompact ? compact : plain;
  const ref = React.useRef<HTMLSpanElement>(null);
  const from = React.useRef(0);
  const reduce = useReducedMotion();
  React.useEffect(() => {
    const node = ref.current;
    if (!node) return;
    if (reduce) {
      node.textContent = format(value);
      from.current = value;
      return;
    }
    const controls = animate(from.current, value, {
      duration: from.current === 0 ? 1.1 : 0.6,
      ease: EASE_OUT,
      onUpdate: (v) => { node.textContent = format(v); },
    });
    from.current = value;
    return () => controls.stop();
  }, [value, format, reduce]);
  return <span ref={ref} className={cn("tabular-nums", className)}>{format(0)}</span>;
}

/**
 * A panel with a soft light that follows the pointer, and a hairline that
 * brightens near it. The "cursor" feel of the console.
 */
export function SpotlightPanel({ className, children, ...props }: React.ComponentProps<"div">) {
  const x = useMotionValue(-400);
  const y = useMotionValue(-400);
  const background = useMotionTemplate`radial-gradient(420px circle at ${x}px ${y}px, var(--spotlight), transparent 70%)`;
  const border = useMotionTemplate`radial-gradient(260px circle at ${x}px ${y}px, color-mix(in oklab, var(--brand) 45%, transparent), transparent 75%)`;
  return (
    <div
      onPointerMove={(e) => {
        const rect = e.currentTarget.getBoundingClientRect();
        x.set(e.clientX - rect.left);
        y.set(e.clientY - rect.top);
      }}
      onPointerLeave={() => { x.set(-400); y.set(-400); }}
      className={cn("group/spot relative rounded-xl border bg-panel", className)}
      {...props}
    >
      <motion.div aria-hidden className="pointer-events-none absolute inset-0 rounded-[inherit] opacity-0 transition-opacity duration-300 group-hover/spot:opacity-100" style={{ background }} />
      <motion.div
        aria-hidden
        className="pointer-events-none absolute -inset-px rounded-[inherit] opacity-0 transition-opacity duration-300 group-hover/spot:opacity-100"
        style={{
          background: border,
          WebkitMask: "linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0)",
          WebkitMaskComposite: "xor",
          maskComposite: "exclude",
          padding: 1,
        }}
      />
      <div className="relative">{children}</div>
    </div>
  );
}

/** A blinking text caret, as in an editor. */
export function Caret({ className }: { className?: string }) {
  return <span aria-hidden className={cn("ml-0.5 inline-block h-[0.95em] w-[2px] translate-y-[0.12em] rounded-full bg-brand animate-caret", className)} />;
}

/** Text typed out once on mount, then a resting caret. */
export function TypeIn({ text, className, speed = 22 }: { text: string; className?: string; speed?: number }) {
  const reduce = useReducedMotion();
  const [typed, setShown] = React.useState(0);
  React.useEffect(() => {
    if (reduce) return;
    let i = 0;
    const id = setInterval(() => {
      i += 1;
      setShown(i);
      if (i >= text.length) clearInterval(id);
    }, speed);
    return () => clearInterval(id);
  }, [text, speed, reduce]);
  const shown = reduce ? text.length : typed;
  return (
    <span className={className}>
      <span className="sr-only">{text}</span>
      <span aria-hidden>{text.slice(0, shown)}</span>
      <Caret />
    </span>
  );
}

export function LiveDot({ live = true, className }: { live?: boolean; className?: string }) {
  return (
    <span
      className={cn(
        "inline-block size-1.5 rounded-full",
        live ? "bg-status-good animate-pulse-dot" : "bg-muted-foreground/50",
        className,
      )}
    />
  );
}
