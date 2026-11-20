import Link from "next/link"
import { Button } from "@/components/ui/button"

export default function NotFound() {
  return (
    <div className="mx-auto flex min-h-svh max-w-md flex-col items-center justify-center gap-3 px-4 text-center">
      <p className="font-mono text-sm text-muted-foreground">404</p>
      <h1 className="text-xl font-semibold">Not found</h1>
      <p className="text-sm text-muted-foreground">This page does not exist, or it belongs to an organization you are not in.</p>
      <Button variant="outline" render={<Link href="/" />}>
        Back to overview
      </Button>
    </div>
  )
}
