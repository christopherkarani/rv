"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { motion } from "motion/react";
import { Search } from "lucide-react";
import { ConsoleLogo, useBrand } from "@/components/brand";
import { LiveDot, SPRING } from "@/components/motion/primitives";
import { LocalTime } from "@/components/console/local-time";
import { fmtNumber } from "@/lib/format";
import { useNow } from "@/lib/use-now";
import { cn } from "@/lib/utils";
import { NAV_ITEMS, navFor } from "./nav";
import { RangePicker } from "./range-picker";
import { ThemeToggle } from "./theme-toggle";
import { useRange } from "./use-range";
import { UserMenu, type ShellUser } from "./user-menu";
import type { StatusSnapshot } from "./use-status";

/** Same column as rykanv.com's header (max-w-[1200px], px-6/px-10), so the console lines up with the site. */
const COLUMN = "mx-auto w-full max-w-[1200px] px-4 sm:px-10";

/**
 * The rykanv.com layout: the site's header with the console's sections as a
 * row of tabs under it, the page scrolling as one document, and the ingest
 * status as a quiet line at the foot. Used when RV_CONSOLE_THEME=rykan.
 */
export function SiteShell({ user, organization, status, version, alerts, onOpenPalette, children }: {
  user: ShellUser;
  organization: string | null;
  status: StatusSnapshot;
  version: string;
  alerts: Record<string, number>;
  onOpenPalette: () => void;
  children: React.ReactNode;
}) {
  const brand = useBrand();
  const pathname = usePathname();
  const active = navFor(pathname)?.href;
  const { withRange } = useRange();

  return (
    <div className="flex min-h-dvh flex-col bg-background">
      <a href="#main" className="sr-only focus:not-sr-only focus:absolute focus:top-3 focus:left-3 focus:z-50 focus:rounded-md focus:bg-background focus:px-3 focus:py-2 focus:ring-2 focus:ring-ring">
        Skip to content
      </a>
      <header className="sticky top-0 z-40 border-b bg-background">
        <div className={cn(COLUMN, "flex h-14 items-center gap-3")}>
          <Link href={withRange("/")} aria-label="Console overview" className="flex min-w-0 items-center rounded-md outline-none focus-visible:ring-2 focus-visible:ring-ring">
            <ConsoleLogo size={22} />
          </Link>
          {organization && (
            <>
              <svg viewBox="0 0 16 16" aria-hidden className="hidden size-4 shrink-0 text-border sm:block"><path d="M10.5 2 5.5 14" stroke="currentColor" strokeWidth="1.25" /></svg>
              <span className="hidden truncate text-[13.5px] font-medium sm:inline">{organization}</span>
            </>
          )}
          <div className="ml-auto flex items-center gap-1.5 sm:gap-3">
            <button
              type="button"
              onClick={onOpenPalette}
              className="hidden h-8 w-56 items-center gap-2 rounded-md border px-2.5 text-[13px] text-muted-foreground transition-colors hover:border-foreground/20 hover:text-foreground md:flex"
            >
              <Search className="size-3.5" />
              <span className="flex-1 text-left">Search…</span>
              <span className="kbd">⌘K</span>
            </button>
            <button type="button" onClick={onOpenPalette} aria-label="Search" className="grid size-8 place-items-center rounded-md text-muted-foreground hover:bg-hover hover:text-foreground md:hidden">
              <Search className="size-4" />
            </button>
            {brand.siteUrl && (
              <a href={`${brand.siteUrl}/docs/introduction`} target="_blank" rel="noopener noreferrer" className="hidden text-[14px] font-medium text-muted-foreground transition-colors hover:text-foreground sm:inline">
                Docs
              </a>
            )}
            <ThemeToggle />
            <UserMenu user={user} />
          </div>
        </div>
        <div className={cn(COLUMN, "flex items-center gap-4")}>
          <nav aria-label="Console" className="-mb-px flex min-w-0 flex-1 overflow-x-auto -ml-3 [scrollbar-width:none]">
            {NAV_ITEMS.map((item) => {
              const isActive = active === item.href;
              const badge = alerts[item.href] ?? 0;
              return (
                <Link
                  key={item.href}
                  href={withRange(item.href)}
                  aria-current={isActive ? "page" : undefined}
                  className={cn(
                    "relative flex h-11 shrink-0 items-center gap-1.5 px-3 text-[13.5px] whitespace-nowrap outline-none transition-colors",
                    "focus-visible:text-foreground focus-visible:underline",
                    isActive ? "text-foreground" : "text-muted-foreground hover:text-foreground",
                  )}
                >
                  {item.title}
                  {badge > 0 && (
                    <span className="grid h-[18px] min-w-[18px] place-items-center rounded-full bg-status-critical/12 px-1 font-mono text-[10.5px] text-status-critical" aria-label={`${badge} need attention`}>
                      {badge}
                    </span>
                  )}
                  {isActive && <motion.span layoutId="site-tab" transition={SPRING} className="absolute inset-x-3 bottom-0 h-[2px] rounded-full bg-foreground" />}
                </Link>
              );
            })}
          </nav>
          <RangePicker className="hidden shrink-0 md:flex" />
        </div>
      </header>

      <main id="main" className={cn(COLUMN, "flex-1 py-8 sm:py-10")}>
        <RangePicker className="mb-6 w-fit md:hidden" />
        {children}
      </main>

      <SiteFooter status={status} version={version} />
    </div>
  );
}

/** Ingest health in one line, where the editor theme had its status bar. */
function SiteFooter({ status, version }: { status: StatusSnapshot; version: string }) {
  const now = useNow();
  const live = now !== 0 && status.lastReceived != null && now - status.lastReceived < 10 * 60_000;
  return (
    <footer className="border-t">
      <div className={cn(COLUMN, "flex flex-wrap items-center gap-x-5 gap-y-1 py-4 text-[12.5px] text-muted-foreground")}>
        <span className={cn("flex items-center gap-2", live && "text-foreground")}>
          <LiveDot live={live} />
          {live ? "Ingest live" : status.lastReceived ? "Ingest idle" : "Waiting for first event"}
        </span>
        <span className="hidden sm:inline">Last event <LocalTime ms={status.lastReceived} /></span>
        <span className="hidden sm:inline">{fmtNumber(status.lastHour)} events in the last hour</span>
        <Link href="/fleet" className="hover:text-foreground">{status.devices} devices</Link>
        <Link href="/integrity" className={cn("hover:text-foreground", status.brokenChains > 0 && "text-status-critical")}>
          {status.brokenChains > 0 ? `${status.brokenChains} broken audit chain${status.brokenChains === 1 ? "" : "s"}` : "Audit chains intact"}
        </Link>
        <span className="ml-auto font-mono text-[11.5px]">rv console {version}</span>
      </div>
    </footer>
  );
}
