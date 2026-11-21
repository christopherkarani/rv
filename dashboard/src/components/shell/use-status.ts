"use client";

import { withBase } from "@/lib/base-path";
import { useEffect, useState } from "react";

export interface StatusSnapshot {
  devices: number;
  lastReceived: number | null;
  headSeq: number;
  lastHour: number;
  brokenChains: number;
}

/** Polls the console's status every few seconds while the tab is visible. */
export function useStatus(initial: StatusSnapshot, intervalMs = 5000) {
  const [status, setStatus] = useState(initial);
  useEffect(() => {
    let stopped = false;
    let timer: ReturnType<typeof setTimeout>;
    const tick = async () => {
      if (document.visibilityState === "visible") {
        try {
          const res = await fetch(withBase("/api/v1/status"), { cache: "no-store" });
          if (res.ok && !stopped) setStatus(await res.json());
        } catch { /* offline: keep the last snapshot */ }
      }
      if (!stopped) timer = setTimeout(tick, intervalMs);
    };
    timer = setTimeout(tick, intervalMs);
    return () => { stopped = true; clearTimeout(timer); };
  }, [intervalMs]);
  return status;
}
