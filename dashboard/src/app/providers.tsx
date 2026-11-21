"use client";

import { ThemeProvider } from "next-themes";
import { MotionConfig } from "motion/react";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Toaster } from "@/components/ui/sonner";
import { BrandProvider } from "@/components/brand";
import type { Brand } from "@/lib/brand";

export function Providers({ brand, children }: { brand: Brand; children: React.ReactNode }) {
  return (
    <BrandProvider brand={brand}>
      <ThemeProvider attribute="class" defaultTheme={brand.defaultTheme} enableSystem disableTransitionOnChange>
        <MotionConfig reducedMotion="user">
          <TooltipProvider delayDuration={300}>
            {children}
            <Toaster position="bottom-right" />
          </TooltipProvider>
        </MotionConfig>
      </ThemeProvider>
    </BrandProvider>
  );
}
