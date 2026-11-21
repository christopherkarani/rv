"use client";

import { createContext, useContext } from "react";
import type { Brand } from "@/lib/brand";
import { withBase } from "@/lib/base-path";
import { cn } from "@/lib/utils";

const BrandContext = createContext<Brand>({ name: "rv", siteUrl: null, defaultTheme: "dark" });

export function BrandProvider({ brand, children }: { brand: Brand; children: React.ReactNode }) {
  return <BrandContext.Provider value={brand}>{children}</BrandContext.Provider>;
}

export const useBrand = () => useContext(BrandContext);

/** rv's console mark: a gate bar across a rounded square. */
export function RvMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden className={cn("shrink-0", className)}>
      <defs>
        <linearGradient id="rv-mark" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="var(--brand)" />
          <stop offset="1" stopColor="var(--series-override)" />
        </linearGradient>
      </defs>
      <rect x="1.5" y="1.5" width="21" height="21" rx="6" fill="url(#rv-mark)" />
      <path d="M7 16.5V9.8c0-1 .8-1.8 1.8-1.8H11" stroke="#fff" strokeWidth="2" strokeLinecap="round" fill="none" />
      <path d="M12.5 8l2.6 8.5L17.7 8" stroke="#fff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" fill="none" />
    </svg>
  );
}

/**
 * The product name in the title bar and on the sign-in page: the rv mark and
 * "rv Console", or the rykanv.com lockup with "Console" beside it.
 * `size` is the lockup height in px; the rv mark scales to match.
 */
export function ConsoleLogo({ size = 20, className }: { size?: number; className?: string }) {
  const brand = useBrand();
  if (brand.name === "rykan") {
    return (
      <span className={cn("flex min-w-0 items-center gap-2", className)}>
        {/* Black artwork on transparent, same file the site's header uses; inverted for dark. */}
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={withBase("/brand/rykan-v-logo.png")} alt="Rykan V" draggable={false} className="w-auto shrink-0 object-contain dark:invert" style={{ height: size * 0.9 }} />
        <span className="h-4 w-px shrink-0 bg-border" aria-hidden />
        <span className="text-[14px] font-medium text-muted-foreground">Console</span>
      </span>
    );
  }
  return (
    <span className={cn("flex min-w-0 items-center gap-1.5", className)}>
      <RvMark className="shrink-0" />
      <span className="font-semibold tracking-tight">rv</span>
      <span className="hidden text-muted-foreground sm:inline">Console</span>
    </span>
  );
}
