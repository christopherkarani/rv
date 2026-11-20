import type { Metadata } from "next"
import { Logo } from "@/components/logo"
import { CreateOrgForm } from "./create-org-form"

export const metadata: Metadata = { title: "Create your organization" }

export default function OnboardingPage() {
  return (
    <div className="flex min-h-svh flex-col items-center justify-center bg-muted/30 px-4">
      <div className="w-full max-w-md">
        <div className="mb-8 flex flex-col items-center gap-3 text-center">
          <Logo className="size-10 text-base" />
          <h1 className="text-2xl font-semibold tracking-tight">Create your organization</h1>
          <p className="text-sm text-muted-foreground">
            Your machines enroll into an organization. Teammates join it by invitation.
          </p>
        </div>
        <div className="rounded-xl border bg-card p-6 shadow-sm">
          <CreateOrgForm />
        </div>
      </div>
    </div>
  )
}
