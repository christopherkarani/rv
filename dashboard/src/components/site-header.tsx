"use client"

import Link from "next/link"
import { usePathname } from "next/navigation"
import { useTheme } from "next-themes"
import { BellIcon, CheckIcon, ChevronsUpDownIcon, MonitorIcon, MoonIcon, PlusIcon, SunIcon } from "lucide-react"
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

const NAV = [
  { href: "/", label: "Overview" },
  { href: "/machines", label: "Machines" },
  { href: "/activity", label: "Activity" },
  { href: "/rollout", label: "Rollout" },
  { href: "/policy", label: "Policy" },
  { href: "/audit", label: "Audit" },
  { href: "/settings", label: "Settings" },
]

export function Logo() {
  return (
    <span className="flex size-6 items-center justify-center rounded-md bg-foreground font-mono text-[11px] font-bold tracking-tight text-background">
      rv
    </span>
  )
}

function Slash() {
  return (
    <svg viewBox="0 0 24 24" className="size-5 text-muted-foreground/40" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden>
      <path d="M16.88 3.549L7.12 20.451" />
    </svg>
  )
}

function OrgSwitcher() {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button variant="ghost" size="sm" className="gap-2 px-2 font-medium">
            <span className="flex size-5 items-center justify-center rounded-full bg-gradient-to-br from-emerald-400 to-sky-500 text-[10px] font-semibold text-white">
              A
            </span>
            Acme Engineering
            <Badge variant="outline" className="h-4 px-1.5 text-[10px] font-normal text-muted-foreground">
              Business
            </Badge>
            <ChevronsUpDownIcon className="size-3.5 text-muted-foreground" />
          </Button>
        }
      />
      <DropdownMenuContent align="start" className="w-60">
        <DropdownMenuGroup>
          <DropdownMenuLabel>Organizations</DropdownMenuLabel>
          <DropdownMenuItem>
            Acme Engineering
            <CheckIcon className="ml-auto" />
          </DropdownMenuItem>
          <DropdownMenuItem>Acme Contractors</DropdownMenuItem>
        </DropdownMenuGroup>
        <DropdownMenuSeparator />
        <DropdownMenuItem>
          <PlusIcon />
          Create organization
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

function UserMenu() {
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
          <Button variant="ghost" size="icon" className="rounded-full">
            <Avatar className="size-7">
              <AvatarFallback className="bg-gradient-to-br from-violet-500 to-fuchsia-500 text-[11px] font-medium text-white">
                RK
              </AvatarFallback>
            </Avatar>
          </Button>
        }
      />
      <DropdownMenuContent align="end" className="w-60">
        <DropdownMenuGroup>
          <DropdownMenuLabel className="font-normal">
            <div className="text-sm font-medium text-foreground">Ravi K.</div>
            <div className="text-xs text-muted-foreground">Owner · Acme Engineering</div>
          </DropdownMenuLabel>
        </DropdownMenuGroup>
        <DropdownMenuSeparator />
        <DropdownMenuItem>Account settings</DropdownMenuItem>
        <DropdownMenuItem>Billing</DropdownMenuItem>
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
        <DropdownMenuItem>Log out</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

export function SiteHeader() {
  const pathname = usePathname()
  const isActive = (href: string) => (href === "/" ? pathname === "/" : pathname.startsWith(href))
  return (
    <header className="sticky top-0 z-40 border-b bg-background/80 backdrop-blur supports-[backdrop-filter]:bg-background/70">
      <div className="flex h-14 items-center gap-1 px-4 sm:px-6">
        <Link href="/" aria-label="rv Cloud home" className="mr-1">
          <Logo />
        </Link>
        <Slash />
        <OrgSwitcher />
        <div className="ml-auto flex items-center gap-1.5">
          <Button variant="outline" size="sm" className="hidden text-muted-foreground sm:inline-flex">
            Feedback
          </Button>
          <Button
            variant="ghost"
            size="sm"
            className="hidden text-muted-foreground sm:inline-flex"
            render={<a href="https://github.com/christopherkarani/rv" target="_blank" rel="noreferrer" />}
          >
            Docs
          </Button>
          <Button variant="ghost" size="icon" aria-label="Notifications" className="relative rounded-full text-muted-foreground">
            <BellIcon className="size-4" />
            <span className="absolute right-1.5 top-1.5 size-1.5 rounded-full bg-info" />
          </Button>
          <UserMenu />
        </div>
      </div>
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
            <span className="rounded-md px-0 py-1">{item.label}</span>
          </Link>
        ))}
      </nav>
    </header>
  )
}
