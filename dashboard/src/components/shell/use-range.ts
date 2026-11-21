"use client";

import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useCallback } from "react";
import { DEFAULT_RANGE, parseRange, type RangeKey } from "@/lib/range";

/** The page's time range lives in `?range=`, so links and reloads keep it. */
export function useRange() {
  const params = useSearchParams();
  const router = useRouter();
  const pathname = usePathname();
  const range = parseRange(params.get("range") ?? undefined);
  const setRange = useCallback((next: RangeKey) => {
    const p = new URLSearchParams(params.toString());
    if (next === DEFAULT_RANGE) p.delete("range"); else p.set("range", next);
    const qs = p.toString();
    router.replace(qs ? `${pathname}?${qs}` : pathname, { scroll: false });
  }, [params, pathname, router]);
  const withRange = useCallback((href: string) => (range === DEFAULT_RANGE ? href : `${href}${href.includes("?") ? "&" : "?"}range=${range}`), [range]);
  return { range, setRange, withRange };
}
