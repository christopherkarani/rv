"use client";

import { useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Check, Copy } from "lucide-react";
import { cn } from "@/lib/utils";

export function CodeBlock({ code, label, className }: { code: string; label?: string; className?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className={cn("group/code overflow-hidden rounded-lg border bg-chrome", className)}>
      <div className="flex h-8 items-center justify-between border-b px-3">
        <span className="font-mono text-[11px] text-muted-foreground">{label ?? "shell"}</span>
        <button
          type="button"
          onClick={() => { void navigator.clipboard.writeText(code); setCopied(true); setTimeout(() => setCopied(false), 1400); }}
          className="relative flex h-6 items-center gap-1 rounded px-1.5 text-[11px] text-muted-foreground hover:bg-hover hover:text-foreground"
          aria-label="Copy to clipboard"
        >
          <AnimatePresence mode="wait" initial={false}>
            <motion.span key={copied ? "y" : "n"} initial={{ opacity: 0, y: 4 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -4 }} transition={{ duration: 0.15 }} className="flex items-center gap-1">
              {copied ? <Check className="size-3 text-status-good" /> : <Copy className="size-3" />} {copied ? "Copied" : "Copy"}
            </motion.span>
          </AnimatePresence>
        </button>
      </div>
      <pre className="overflow-x-auto p-3 font-mono text-[12px] leading-5 whitespace-pre text-foreground/90">{code}</pre>
    </div>
  );
}
