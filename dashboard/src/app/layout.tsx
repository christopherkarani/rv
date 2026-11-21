import type { Metadata, Viewport } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import { brandFromEnv } from "@/lib/brand";
import { withBase } from "@/lib/base-path";
import { Providers } from "./providers";
import "./globals.css";

export function generateMetadata(): Metadata {
  const rykan = brandFromEnv().name === "rykan";
  return {
    title: { default: "rv Console", template: "%s · rv Console" },
    description: "Fleet console for rv, the fail-closed policy gate for AI coding agents.",
    robots: { index: false, follow: false },
    // Same favicon as rykanv.com, so the console tab reads as part of the site.
    ...(rykan && { icons: { icon: withBase("/brand/rykan-favicon.svg"), apple: withBase("/brand/rykan-apple-touch-icon.png") } }),
  };
}

export function generateViewport(): Viewport {
  const rykan = brandFromEnv().name === "rykan";
  return {
    themeColor: rykan
      ? [{ media: "(prefers-color-scheme: dark)", color: "#09090b" }, { media: "(prefers-color-scheme: light)", color: "#ffffff" }]
      : [{ media: "(prefers-color-scheme: dark)", color: "#0a0a0b" }, { media: "(prefers-color-scheme: light)", color: "#efefed" }],
  };
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const brand = brandFromEnv();
  return (
    <html lang="en" suppressHydrationWarning data-brand={brand.name} className={`${GeistSans.variable} ${GeistMono.variable}`}>
      <body>
        <Providers brand={brand}>{children}</Providers>
      </body>
    </html>
  );
}
