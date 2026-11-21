"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useSyncExternalStore } from "react";
import { AnimatePresence, motion } from "motion/react";
import { X } from "lucide-react";
import { cn } from "@/lib/utils";
import { SPRING } from "@/components/motion/primitives";
import { NAV_ITEMS, navFor } from "./nav";
import { useRange } from "./use-range";

import { tabsStore } from "./tabs-store";

/** Open pages as editor tabs: visiting a page opens its tab, ⌘W-style close. */
export function EditorTabs() {
  const pathname = usePathname();
  const router = useRouter();
  const { withRange } = useRange();
  const current = navFor(pathname);
  const stored = useSyncExternalStore(tabsStore.subscribe, tabsStore.getSnapshot, tabsStore.getServerSnapshot);
  const tabs = stored.filter((h) => NAV_ITEMS.some((i) => i.href === h));

  // Visiting a page opens its tab (a write to the external store, not React state).
  useEffect(() => {
    if (current) tabsStore.open(current.href);
  }, [current]);

  const close = (href: string) => {
    const index = tabs.indexOf(href);
    tabsStore.close(href);
    const next = tabs.filter((t) => t !== href);
    if (current?.href === href) router.push(withRange(next[Math.max(0, index - 1)] ?? "/"));
  };

  return (
    <div role="tablist" aria-label="Open pages" className="flex h-9 shrink-0 items-stretch overflow-x-auto border-b bg-chrome [scrollbar-width:none]">
      <AnimatePresence initial={false}>
        {tabs.map((href) => {
          const item = NAV_ITEMS.find((i) => i.href === href)!;
          const active = current?.href === href;
          return (
            <motion.div
              key={href}
              layout
              initial={{ opacity: 0, width: 0 }}
              animate={{ opacity: 1, width: "auto" }}
              exit={{ opacity: 0, width: 0 }}
              transition={SPRING}
              className={cn(
                "group/tab relative flex shrink-0 items-center border-r",
                active ? "bg-background text-foreground" : "text-muted-foreground hover:bg-hover hover:text-foreground",
              )}
            >
              {active && <motion.span layoutId="tab-active" transition={SPRING} className="absolute inset-x-0 top-0 h-px bg-brand" />}
              {active && <span className="absolute inset-x-0 -bottom-px h-px bg-background" />}
              <Link role="tab" aria-selected={active} href={withRange(href)} className="flex h-full items-center gap-2 pr-1 pl-3 text-[12.5px] whitespace-nowrap outline-none focus-visible:underline">
                <item.icon className={cn("size-3.5", active ? "text-brand" : "")} strokeWidth={1.75} />
                {item.title}
              </Link>
              <button
                type="button"
                aria-label={`Close ${item.title}`}
                onClick={() => close(href)}
                className={cn(
                  "mr-1.5 grid size-5 place-items-center rounded transition-opacity hover:bg-hover",
                  active ? "opacity-70 hover:opacity-100" : "opacity-0 group-hover/tab:opacity-70",
                )}
              >
                <X className="size-3" />
              </button>
            </motion.div>
          );
        })}
      </AnimatePresence>
      <div className="flex-1" />
    </div>
  );
}
