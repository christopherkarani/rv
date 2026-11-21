import Link from "next/link";
import { Button } from "@/components/ui/button";

export default function NotFound() {
  return (
    <div className="mx-auto mt-24 flex max-w-md flex-col items-center gap-3 text-center">
      <p className="font-mono text-sm text-muted-foreground">404</p>
      <h1 className="text-lg font-semibold">Nothing here</h1>
      <p className="text-sm text-muted-foreground">That device or page does not exist, or it aged out of retention.</p>
      <Button variant="outline" size="sm" asChild><Link href="/">Back to overview</Link></Button>
    </div>
  );
}
