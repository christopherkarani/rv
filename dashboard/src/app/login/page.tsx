import { Suspense } from "react"
import type { Metadata } from "next"
import { Logo } from "@/components/logo"
import { safeNext } from "@/lib/safe-next"
import { LoginForm } from "./login-form"

export const metadata: Metadata = { title: "Sign in" }

async function Form({ searchParams }: { searchParams: PageProps<"/login">["searchParams"] }) {
  const params = await searchParams
  const next = safeNext(typeof params.next === "string" ? params.next : null)
  const error = typeof params.error === "string" ? params.error : null
  return (
    <>
      {error && (
        <p className="mb-4 rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">
          {error === "link" ? "That sign-in link is invalid or has expired. Request a new one." : "Sign-in failed. Try again."}
        </p>
      )}
      <LoginForm next={next} github={process.env.NEXT_PUBLIC_AUTH_GITHUB === "true"} />
    </>
  )
}

export default function LoginPage({ searchParams }: PageProps<"/login">) {
  return (
    <div className="flex min-h-svh flex-col items-center justify-center bg-muted/30 px-4">
      <div className="w-full max-w-sm">
        <div className="mb-8 flex flex-col items-center gap-3 text-center">
          <Logo className="size-10 text-base" />
          <h1 className="text-2xl font-semibold tracking-tight">Sign in to rv Cloud</h1>
          <p className="text-sm text-muted-foreground">See what coding agents do on every machine.</p>
        </div>
        <div className="rounded-xl border bg-card p-6 shadow-sm">
          <Suspense fallback={<div className="h-40" />}>
            <Form searchParams={searchParams} />
          </Suspense>
        </div>
        <p className="mt-6 text-center text-xs text-muted-foreground">
          rv Cloud never receives commands, prompts, file contents or secret values.
        </p>
      </div>
    </div>
  )
}
