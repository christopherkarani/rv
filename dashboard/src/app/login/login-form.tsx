"use client"

import { useActionState } from "react"
import { MailIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { sendMagicLink, signInWithGitHub, type LoginState } from "./actions"

function GitHubMark() {
  return (
    <svg viewBox="0 0 16 16" className="size-4" fill="currentColor" aria-hidden>
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  )
}

export function LoginForm({ next, github }: { next: string; github: boolean }) {
  const [state, action, pending] = useActionState<LoginState, FormData>(sendMagicLink, { status: "idle" })

  if (state.status === "sent") {
    return (
      <div className="space-y-2 text-center">
        <MailIcon className="mx-auto size-8 text-muted-foreground" />
        <p className="font-medium">Check your email</p>
        <p className="text-sm text-muted-foreground">
          We sent a sign-in link to <span className="text-foreground">{state.email}</span>. It expires in one hour.
        </p>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      {github && (
        <>
          <form action={signInWithGitHub}>
            <input type="hidden" name="next" value={next} />
            <Button type="submit" variant="outline" className="h-10 w-full">
              <GitHubMark />
              Continue with GitHub
            </Button>
          </form>
          <div className="flex items-center gap-3 text-xs text-muted-foreground">
            <span className="h-px flex-1 bg-border" />
            or
            <span className="h-px flex-1 bg-border" />
          </div>
        </>
      )}
      <form action={action} className="space-y-3">
        <input type="hidden" name="next" value={next} />
        <div className="space-y-1.5">
          <Label htmlFor="email">Work email</Label>
          <Input id="email" name="email" type="email" autoComplete="email" required placeholder="you@company.com" className="h-10" />
        </div>
        {state.status === "error" && <p className="text-sm text-destructive">{state.message}</p>}
        <Button type="submit" className="h-10 w-full" disabled={pending}>
          {pending ? "Sending…" : "Continue with email"}
        </Button>
      </form>
    </div>
  )
}
