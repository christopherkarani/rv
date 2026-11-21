"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { motion } from "motion/react";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import { SPRING } from "@/components/motion/primitives";
import { NAV, navFor } from "./nav";
import { useRange } from "./use-range";

export function Explorer({ collapsed, alerts, variant = "rail", onNavigate }: {
  collapsed: boolean;
  alerts: Record<string, number>;
  /** "sheet" renders full width inside the mobile drawer. */
  variant?: "rail" | "sheet";
  onNavigate?: () => void;
}) {
  const pathname = usePathname();
  const active = navFor(pathname)?.href;
  const { withRange } = useRange();
  return (
    <motion.nav
      aria-label="Console"
      initial={false}
      animate={variant === "sheet" ? undefined : { width: collapsed ? 52 : 228 }}
      transition={SPRING}
      className={cn(
        "relative shrink-0 flex-col overflow-hidden bg-sidebar",
        variant === "sheet" ? "flex h-full w-full" : "hidden border-r md:flex",
      )}
    >
      <div className="flex flex-1 flex-col gap-4 overflow-y-auto overflow-x-hidden px-2 py-3">
        {NAV.map((section) => (
          <div key={section.section} className="flex flex-col gap-0.5">
            <motion.div
              initial={false}
              animate={{ opacity: collapsed ? 0 : 1, height: collapsed ? 0 : "auto" }}
              className="label-caps overflow-hidden px-2 pb-1.5 whitespace-nowrap"
            >
              {section.section}
            </motion.div>
            {section.items.map((item) => {
              const isActive = active === item.href;
              const badge = alerts[item.href] ?? 0;
              const link = (
                <Link
                  href={withRange(item.href)}
                  onClick={onNavigate}
                  aria-current={isActive ? "page" : undefined}
                  className={cn(
                    "group/nav relative flex h-8 items-center gap-2.5 rounded-md px-2 text-[13px] whitespace-nowrap outline-none transition-colors",
                    "focus-visible:ring-2 focus-visible:ring-ring/60",
                    isActive ? "text-foreground" : "text-muted-foreground hover:bg-hover hover:text-foreground",
                  )}
                >
                  {isActive && (
                    <motion.span
                      layoutId={variant === "sheet" ? "nav-active-sheet" : "nav-active"}
                      transition={SPRING}
                      className="absolute inset-0 rounded-md bg-sidebar-accent ring-1 ring-border"
                    >
                      <span className="absolute top-1.5 bottom-1.5 left-0 w-[2px] rounded-full bg-brand" />
                    </motion.span>
                  )}
                  <item.icon className="relative size-4 shrink-0" strokeWidth={1.75} />
                  <motion.span initial={false} animate={{ opacity: collapsed ? 0 : 1 }} className="relative flex-1 truncate">
                    {item.title}
                  </motion.span>
                  {badge > 0 && (
                    <span
                      className={cn(
                        "relative rounded-full bg-status-critical/15 px-1.5 font-mono text-[10.5px] leading-4 text-foreground ring-1 ring-status-critical/40",
                        collapsed && "absolute top-1 right-1 size-2 p-0 text-[0px] ring-0 bg-status-critical",
                      )}
                    >
                      {badge}
                    </span>
                  )}
                </Link>
              );
              return collapsed ? (
                <Tooltip key={item.href} delayDuration={0}>
                  <TooltipTrigger asChild>{link}</TooltipTrigger>
                  <TooltipContent side="right" className="flex items-center gap-2">
                    {item.title}
                    {item.keys && <span className="kbd">{item.keys}</span>}
                  </TooltipContent>
                </Tooltip>
              ) : (
                <div key={item.href}>{link}</div>
              );
            })}
          </div>
        ))}
      </div>
    </motion.nav>
  );
}
