"use client";

import { usePathname } from "next/navigation";
import { AnimatePresence, motion } from "motion/react";
import { ChevronRight, PanelLeft, Search } from "lucide-react";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { RvMark } from "@/components/brand";
import { navFor } from "./nav";
import { RangePicker } from "./range-picker";
import { UserMenu, type ShellUser } from "./user-menu";
import { ThemeToggle } from "./theme-toggle";

export function TitleBar({ user, organization, onToggleSidebar, onOpenPalette }: {
  user: ShellUser;
  organization: string | null;
  onToggleSidebar: () => void;
  onOpenPalette: () => void;
}) {
  const pathname = usePathname();
  const page = navFor(pathname);
  const detail = pathname.split("/").filter(Boolean)[1];
  return (
    <header className="relative flex h-11 shrink-0 items-center gap-2 border-b bg-chrome px-2.5">
      <Tooltip>
        <TooltipTrigger asChild>
          <button type="button" onClick={onToggleSidebar} aria-label="Toggle sidebar" className="grid size-7 place-items-center rounded-md text-muted-foreground transition-colors hover:bg-hover hover:text-foreground">
            <PanelLeft className="size-4" strokeWidth={1.75} />
          </button>
        </TooltipTrigger>
        <TooltipContent>Toggle sidebar <span className="kbd ml-1">⌘B</span></TooltipContent>
      </Tooltip>
      <div className="flex min-w-0 items-center gap-1.5 text-[13px]">
        <RvMark className="size-5" />
        <span className="font-semibold tracking-tight">rv</span>
        <span className="hidden text-muted-foreground sm:inline">Console</span>
        {organization && (
          <span className="hidden items-center gap-1.5 sm:flex">
            <ChevronRight className="size-3.5 text-muted-foreground/60" />
            <span className="truncate text-muted-foreground">{organization}</span>
          </span>
        )}
        <ChevronRight className="size-3.5 text-muted-foreground/60" />
        <AnimatePresence mode="popLayout" initial={false}>
          <motion.span
            key={page?.href ?? pathname}
            initial={{ opacity: 0, y: 6 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -6 }}
            transition={{ duration: 0.18 }}
            className="truncate font-medium"
          >
            {page?.title ?? "Console"}
          </motion.span>
        </AnimatePresence>
        {detail && (
          <>
            <ChevronRight className="size-3.5 text-muted-foreground/60" />
            <span className="mono truncate text-muted-foreground">{decodeURIComponent(detail)}</span>
          </>
        )}
      </div>

      <button
        type="button"
        onClick={onOpenPalette}
        className="group/search absolute left-1/2 hidden h-7 w-[min(420px,34vw)] -translate-x-1/2 items-center gap-2 rounded-md border bg-faint px-2.5 text-[12.5px] text-muted-foreground transition-colors hover:border-foreground/15 hover:bg-hover lg:flex"
      >
        <Search className="size-3.5" />
        <span className="flex-1 text-left">Search events, devices, rules…</span>
        <span className="kbd">⌘K</span>
      </button>

      <div className="ml-auto flex items-center gap-2">
        <button type="button" onClick={onOpenPalette} aria-label="Search" className="grid size-7 place-items-center rounded-md text-muted-foreground hover:bg-hover lg:hidden">
          <Search className="size-4" />
        </button>
        <RangePicker className="hidden sm:flex" />
        <ThemeToggle />
        <UserMenu user={user} />
      </div>
    </header>
  );
}
