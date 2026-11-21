"use client";

import { usePathname, useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import { motion } from "motion/react";
import { EASE_OUT } from "@/components/motion/primitives";
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet";
import { CommandPalette } from "./command-palette";
import { EditorTabs } from "./editor-tabs";
import { Explorer } from "./explorer";
import { NAV_ITEMS } from "./nav";
import { StatusBar } from "./status-bar";
import { TitleBar } from "./title-bar";
import { useRange } from "./use-range";
import { useStatus, type StatusSnapshot } from "./use-status";
import type { ShellUser } from "./user-menu";

export const SIDEBAR_COOKIE = "rvc_sidebar";

export function AppShell({ user, organization, initialStatus, devices, version, initialCollapsed, children }: {
  user: ShellUser;
  organization: string | null;
  initialStatus: StatusSnapshot;
  devices: { id: string; hostname: string }[];
  version: string;
  /** From the sidebar cookie, so the server renders the right width. */
  initialCollapsed: boolean;
  children: React.ReactNode;
}) {
  const pathname = usePathname();
  const router = useRouter();
  const { withRange } = useRange();
  const [collapsed, setCollapsed] = useState(initialCollapsed);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [mobileNav, setMobileNav] = useState(false);
  const status = useStatus(initialStatus);
  const chord = useRef<number>(0);

  const toggleSidebar = useCallback(() => {
    setCollapsed((c) => {
      document.cookie = `${SIDEBAR_COOKIE}=${c ? "0" : "1"}; path=/; max-age=31536000; samesite=lax`;
      return !c;
    });
  }, []);

  // ⌘K palette, ⌘B sidebar, and "G then letter" page jumps.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const typing = target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable);
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); setPaletteOpen((o) => !o); return; }
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "b") { e.preventDefault(); toggleSidebar(); return; }
      if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key.toLowerCase() === "g") { chord.current = Date.now(); return; }
      if (Date.now() - chord.current < 900) {
        const item = NAV_ITEMS.find((i) => i.keys?.endsWith(` ${e.key.toUpperCase()}`));
        if (item) { e.preventDefault(); router.push(withRange(item.href)); }
        chord.current = 0;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [router, toggleSidebar, withRange]);

  const alerts: Record<string, number> = status.brokenChains > 0 ? { "/integrity": status.brokenChains } : {};

  return (
    <div className="flex h-dvh flex-col overflow-hidden bg-background">
      <TitleBar
        user={user}
        organization={organization}
        onToggleSidebar={() => (window.matchMedia("(min-width: 768px)").matches ? toggleSidebar() : setMobileNav(true))}
        onOpenPalette={() => setPaletteOpen(true)}
      />
      <Sheet open={mobileNav} onOpenChange={setMobileNav}>
        <SheetContent side="left" className="w-64 p-0">
          <SheetTitle className="sr-only">Navigation</SheetTitle>
          <Explorer collapsed={false} alerts={alerts} variant="sheet" onNavigate={() => setMobileNav(false)} />
        </SheetContent>
      </Sheet>
      <div className="flex min-h-0 flex-1">
        <Explorer collapsed={collapsed} alerts={alerts} />
        <div className="flex min-w-0 flex-1 flex-col">
          <EditorTabs />
          <main id="main" className="min-h-0 flex-1 overflow-y-auto">
            <motion.div
              key={pathname}
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.32, ease: EASE_OUT }}
              className="mx-auto w-full max-w-[1480px] px-4 py-5 sm:px-6 lg:px-8"
            >
              {children}
            </motion.div>
          </main>
        </div>
      </div>
      <StatusBar status={status} version={version} />
      <CommandPalette open={paletteOpen} onOpenChange={setPaletteOpen} devices={devices} />
    </div>
  );
}
