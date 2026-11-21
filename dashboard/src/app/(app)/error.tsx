"use client";

import { RefreshCw, TriangleAlert } from "lucide-react";
import { Button } from "@/components/ui/button";

export default function ConsoleError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="mx-auto mt-24 flex max-w-md flex-col items-center gap-3 text-center">
      <div className="grid size-11 place-items-center rounded-xl border border-status-critical/30 bg-status-critical/10">
        <TriangleAlert className="size-5 text-status-critical" />
      </div>
      <h1 className="text-lg font-semibold">This view failed to load</h1>
      <p className="text-sm text-muted-foreground">The console logged the error{error.digest ? <> (ref <span className="font-mono">{error.digest}</span>)</> : null}. Your data is unaffected.</p>
      <Button variant="outline" size="sm" onClick={reset}><RefreshCw /> Try again</Button>
    </div>
  );
}
