"use client";

import { motion } from "motion/react";
import { useEffect, useState } from "react";
import { RvMark } from "@/components/brand";
import { Caret, EASE_OUT } from "@/components/motion/primitives";

const SCRIPT: { prompt?: string; out?: string; tone?: "deny" | "allow" | "dim" }[] = [
  { prompt: "rv test 'git reset --hard'" },
  { out: '{"decision":"deny","rule_id":"core.git:reset-hard"}', tone: "deny" },
  { prompt: "rv test 'cat .env'" },
  { out: '{"decision":"deny","rule_id":"core.secrets:env"}', tone: "deny" },
  { prompt: "rv test 'git status'" },
  { out: '{"decision":"allow"}', tone: "allow" },
  { prompt: "rv audit forward --to https://console/api/v1/ingest" },
  { out: "forwarded 1,284 events in 3 batches", tone: "dim" },
];

/** A terminal that types rv denying things, behind the sign-in form. */
function TypedTerminal() {
  const [line, setLine] = useState(0);
  const [chars, setChars] = useState(0);
  useEffect(() => {
    const current = SCRIPT[line % SCRIPT.length];
    const text = current.prompt ?? current.out ?? "";
    if (chars < text.length && current.prompt) {
      const id = setTimeout(() => setChars((c) => c + 1), 34 + Math.random() * 40);
      return () => clearTimeout(id);
    }
    const id = setTimeout(() => { setLine((l) => l + 1); setChars(0); }, current.prompt ? 380 : 900);
    return () => clearTimeout(id);
  }, [line, chars]);
  const start = Math.max(0, line - 9);
  const visible = Array.from({ length: line - start + 1 }, (_, i) => start + i);
  return (
    <div className="font-mono text-[12.5px] leading-6">
      {visible.map((n) => {
        const entry = SCRIPT[n % SCRIPT.length];
        const isCurrent = n === line;
        if (entry.prompt) {
          const text = isCurrent ? entry.prompt.slice(0, chars) : entry.prompt;
          return (
            <div key={n} className="truncate text-foreground/90">
              <span className="text-brand">❯</span> {text}
              {isCurrent && <Caret />}
            </div>
          );
        }
        if (isCurrent) return null;
        const color = entry.tone === "deny" ? "text-series-blocked" : entry.tone === "allow" ? "text-status-good" : "text-muted-foreground";
        return <div key={n} className={`truncate ${color}`}>{entry.out}</div>;
      })}
    </div>
  );
}

export function AuthFrame({ title, subtitle, children }: { title: string; subtitle: string; children: React.ReactNode }) {
  return (
    <div className="relative grid min-h-dvh lg:grid-cols-[minmax(420px,1fr)_1.15fr]">
      <div className="relative z-10 flex flex-col justify-between px-6 py-8 sm:px-12">
        <div className="flex items-center gap-2 text-sm">
          <RvMark className="size-6" />
          <span className="font-semibold tracking-tight">rv</span>
          <span className="text-muted-foreground">Console</span>
        </div>
        <motion.div
          initial={{ opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, ease: EASE_OUT }}
          className="mx-auto w-full max-w-sm py-12"
        >
          <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
          <p className="mt-1.5 text-sm text-muted-foreground">{subtitle}</p>
          <div className="mt-8">{children}</div>
        </motion.div>
        <p className="text-xs text-muted-foreground">The fleet view for rv, the fail-closed gate for AI coding agents.</p>
      </div>
      <div className="relative hidden overflow-hidden border-l bg-chrome lg:block">
        <div
          aria-hidden
          className="absolute inset-0 opacity-60"
          style={{
            backgroundImage: "linear-gradient(var(--border) 1px, transparent 1px), linear-gradient(90deg, var(--border) 1px, transparent 1px)",
            backgroundSize: "32px 32px",
            maskImage: "radial-gradient(ellipse at 60% 40%, black 20%, transparent 75%)",
          }}
        />
        <motion.div
          aria-hidden
          className="absolute -top-40 right-0 size-[520px] rounded-full blur-3xl"
          style={{ background: "radial-gradient(circle, color-mix(in oklab, var(--brand) 22%, transparent), transparent 65%)" }}
          animate={{ x: [0, -40, 0], y: [0, 30, 0] }}
          transition={{ duration: 16, repeat: Infinity, ease: "easeInOut" }}
        />
        <motion.div
          initial={{ opacity: 0, y: 24, scale: 0.98 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          transition={{ duration: 0.7, delay: 0.15, ease: EASE_OUT }}
          className="absolute top-1/2 left-1/2 w-[min(560px,80%)] -translate-x-1/2 -translate-y-1/2 overflow-hidden rounded-xl border bg-panel shadow-2xl shadow-black/30"
        >
          <div className="flex h-9 items-center gap-1.5 border-b bg-chrome px-3">
            <span className="size-2.5 rounded-full bg-foreground/15" />
            <span className="size-2.5 rounded-full bg-foreground/15" />
            <span className="size-2.5 rounded-full bg-foreground/15" />
            <span className="ml-3 font-mono text-[11px] text-muted-foreground">zsh — agent session</span>
          </div>
          <div className="h-[268px] overflow-hidden p-4">
            <TypedTerminal />
          </div>
        </motion.div>
      </div>
    </div>
  );
}
