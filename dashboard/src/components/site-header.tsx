"use client"

import { useTransition } from "react"
import Link from "next/link"
import { usePathname } from "next/navigation"
import { useTheme } from "next-themes"
import { CheckIcon, ChevronsUpDownIcon, MonitorIcon, MoonIcon, PlusIcon, SunIcon } from "lucide-react"
import { cn } from "@/lib/utils"
import { Avatar, AvatarFallback } from "@/components/ui/avatar"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { switchOrg } from "@/app/actions"
import { signOut } from "@/app/login/actions"

const NAV = [
  { href: "/", label: "Overview" },
  { href: "/machines", label: "Machines" },
  { href: "/activity", label: "Activity" },
  { href: "/rollout", label: "Rollout" },
  { href: "/policy", label: "Policy" },
  { href: "/audit", label: "Audit" },
  { href: "/settings", label: "Settings" },
]

type Org = { orgId: string; name: string; plan: string; role: string }

const initials = (s: string) =>
  s
    .split(/[\s@._-]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase())
    .join("") || "?"

function Slash() {
  return (
    <svg viewBox="0 0 24 24" className="size-5 shrink-0 text-muted-foreground/40" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden>
      <path d="M16.88 3.549L7.12 20.451" />
    </svg>
  )
}

function OrgSwitcher({ orgs, current }: { orgs: Org[]; current: Org }) {
  const [pending, start] = useTransition()
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button variant="ghost" size="sm" className="min-w-0 gap-2 px-2 font-medium" disabled={pending}>
            <span className="flex size-5 shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-emerald-400 to-sky-500 text-[10px] font-semibold text-white">
              {initials(current.name).slice(0, 1)}
            </span>
            <span className="truncate">{current.name}</span>
            <Badge variant="outline" className="hidden h-4 px-1.5 text-[10px] font-normal capitalize text-muted-foreground sm:inline-flex">
              {current.plan}
            </Badge>
            <ChevronsUpDownIcon className="size-3.5 shrink-0 text-muted-foreground" />
          </Button>
        }
      />
      <DropdownMenuContent align="start" className="w-64">
        <DropdownMenuGroup>
          <DropdownMenuLabel>Organizations</DropdownMenuLabel>
          {orgs.map((o) => (
            <DropdownMenuItem key={o.orgId} onClick={() => o.orgId !== current.orgId && start(() => switchOrg(o.orgId))}>
              <span className="truncate">{o.name}</span>
              <span className="ml-auto text-xs capitalize text-muted-foreground">{o.role}</span>
              {o.orgId === current.orgId && <CheckIcon />}
            </DropdownMenuItem>
          ))}
        </DropdownMenuGroup>
        <DropdownMenuSeparator />
        <DropdownMenuItem render={<Link href="/onboarding" />}>
          <PlusIcon />
          Create organization
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

function UserMenu({ email, role }: { email: string; role: string }) {
  const { theme, setTheme } = useTheme()
  const themes = [
    { id: "system", icon: MonitorIcon },
    { id: "light", icon: SunIcon },
    { id: "dark", icon: MoonIcon },
  ]
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button variant="ghost" size="icon" className="rounded-full" aria-label="Account menu">
            <Avatar className="size-7">
              <AvatarFallback className="bg-gradient-to-br from-violet-500 to-fuchsia-500 text-[11px] font-medium text-white">
                {initials(email)}
              </AvatarFallback>
            </Avatar>
          </Button>
        }
      />
      <DropdownMenuContent align="end" className="w-64">
        <DropdownMenuGroup>
          <DropdownMenuLabel className="font-normal">
            <div className="truncate text-sm font-medium text-foreground">{email}</div>
            <div className="text-xs capitalize text-muted-foreground">{role}</div>
          </DropdownMenuLabel>
        </DropdownMenuGroup>
        <DropdownMenuSeparator />
        <div className="flex items-center justify-between px-2 py-1.5 text-sm">
          Theme
          <div className="flex rounded-full border p-0.5">
            {themes.map(({ id, icon: Icon }) => (
              <button
                key={id}
                type="button"
                aria-label={`${id} theme`}
                onClick={() => setTheme(id)}
                className={cn(
                  "flex size-6 items-center justify-center rounded-full text-muted-foreground transition-colors hover:text-foreground",
                  theme === id && "bg-muted text-foreground",
                )}
              >
                <Icon className="size-3.5" />
              </button>
            ))}
          </div>
        </div>
        <DropdownMenuSeparator />
        <DropdownMenuItem onClick={() => signOut()}>Log out</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

export function HeaderBar({ orgs, current, email }: { orgs: Org[]; current: Org; email: string }) {
  return (
    <>
      <Slash />
      <OrgSwitcher orgs={orgs} current={current} />
      <div className="ml-auto flex items-center gap-1.5">
        <Button
          variant="ghost"
          size="sm"
          className="hidden text-muted-foreground sm:inline-flex"
          render={<a href="https://github.com/christopherkarani/rv/tree/main/dashboard#readme" target="_blank" rel="noreferrer" />}
        >
          Docs
        </Button>
        <UserMenu email={email} role={current.role} />
      </div>
    </>
  )
}

export function HeaderNav() {
  const pathname = usePathname()
  const isActive = (href: string) => (href === "/" ? pathname === "/" : pathname.startsWith(href))
  return (
    <nav className="-mb-px flex gap-1 overflow-x-auto px-2 sm:px-4 [scrollbar-width:none]">
      {NAV.map((item) => (
        <Link
          key={item.href}
          href={item.href}
          className={cn(
            "relative shrink-0 px-3 pb-3 pt-1 text-sm text-muted-foreground transition-colors hover:text-foreground",
            "after:absolute after:inset-x-2 after:bottom-0 after:h-0.5 after:rounded-full",
            isActive(item.href) && "text-foreground after:bg-foreground",
          )}
        >
          {item.label}
        </Link>
      ))}
    </nav>
  )
}
