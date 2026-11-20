import { Suspense } from "react"
import Link from "next/link"
import { Logo } from "@/components/logo"
import { HeaderBar, HeaderNav } from "@/components/site-header"
import { getSession } from "@/lib/session"

async function SessionBar() {
  const s = await getSession()
  return <HeaderBar orgs={s.orgs} current={s.org} email={s.email ?? "signed in"} />
}

export default function AppLayout({ children }: LayoutProps<"/">) {
  return (
    <>
      <header className="sticky top-0 z-40 border-b bg-background/80 backdrop-blur supports-[backdrop-filter]:bg-background/70">
        <div className="flex h-14 items-center gap-1 px-4 sm:px-6">
          <Link href="/" aria-label="rv Cloud home" className="mr-1">
            <Logo />
          </Link>
          <Suspense fallback={<div className="h-8 w-40 animate-pulse rounded-md bg-muted" />}>
            <SessionBar />
          </Suspense>
        </div>
        <Suspense fallback={<div className="h-9" />}>
          <HeaderNav />
        </Suspense>
      </header>
      <main className="flex-1">{children}</main>
    </>
  )
}
