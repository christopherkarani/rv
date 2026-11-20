"use client"

import { useEffect } from "react"
import { Button } from "@/components/ui/button"

export default function AppError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    console.error(error)
  }, [error])
  return (
    <div className="mx-auto flex max-w-md flex-col items-center gap-3 px-4 py-24 text-center">
      <h1 className="text-xl font-semibold">Something went wrong</h1>
      <p className="text-sm text-muted-foreground">
        {error.message.includes("permission") ? error.message : "This page could not load. Try again; if it keeps failing, contact support."}
      </p>
      {error.digest && <p className="font-mono text-xs text-muted-foreground">Reference {error.digest}</p>}
      <Button onClick={reset} variant="outline">
        Try again
      </Button>
    </div>
  )
}
