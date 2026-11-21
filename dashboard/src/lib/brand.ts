/**
 * The console's look. "rv" is the default editor-style console. "rykan"
 * matches rykanv.com (white canvas, zinc neutrals, black CTAs, the Rykan V
 * logo) so the console can sit beside the marketing site and docs.
 *
 * Chosen at runtime with RV_CONSOLE_THEME=rykan. The palette lives in
 * globals.css under [data-brand="rykan"]; components read this for the logo.
 */
export type BrandName = "rv" | "rykan";

export type Brand = {
  name: BrandName;
  /** The marketing site the console belongs to, for header links. */
  siteUrl: string | null;
  /** Light or dark for first-time visitors; the toggle still works. */
  defaultTheme: "light" | "dark";
};

const BRANDS: Record<BrandName, Brand> = {
  rv: { name: "rv", siteUrl: null, defaultTheme: "dark" },
  rykan: { name: "rykan", siteUrl: "https://rykanv.com", defaultTheme: "light" },
};

export function brandFromEnv(value = process.env.RV_CONSOLE_THEME): Brand {
  const key = value?.trim().toLowerCase();
  return key === "rykan" ? BRANDS.rykan : BRANDS.rv;
}
