import {
  Activity, KeyRound, Laptop, LayoutDashboard, Link2, Plug, Scale, Settings, ShieldAlert, type LucideIcon,
} from "lucide-react";

export interface NavItem {
  href: string;
  title: string;
  icon: LucideIcon;
  hint: string;
  keys?: string;
}

export const NAV: { section: string; items: NavItem[] }[] = [
  {
    section: "Monitor",
    items: [
      { href: "/", title: "Overview", icon: LayoutDashboard, hint: "Fleet posture at a glance", keys: "G O" },
      { href: "/activity", title: "Activity", icon: Activity, hint: "Every audit event, searchable", keys: "G A" },
      { href: "/detections", title: "Detections", icon: ShieldAlert, hint: "Rules that fire, by agent", keys: "G D" },
    ],
  },
  {
    section: "Govern",
    items: [
      { href: "/fleet", title: "Fleet", icon: Laptop, hint: "Machines, versions, compliance", keys: "G F" },
      { href: "/mcp", title: "MCP gateway", icon: Plug, hint: "Servers, tools, approvals", keys: "G M" },
      { href: "/secrets", title: "Secrets", icon: KeyRound, hint: "Use and misuse, never values", keys: "G S" },
      { href: "/policy", title: "Policy & changes", icon: Scale, hint: "Who changed the gate", keys: "G P" },
      { href: "/integrity", title: "Integrity", icon: Link2, hint: "Tamper-evident audit chains", keys: "G I" },
    ],
  },
  {
    section: "Console",
    items: [{ href: "/settings", title: "Settings", icon: Settings, hint: "Ingest tokens, users, onboarding" }],
  },
];

export const NAV_ITEMS = NAV.flatMap((s) => s.items);

export function navFor(pathname: string): NavItem | undefined {
  if (pathname === "/") return NAV_ITEMS[0];
  return NAV_ITEMS.filter((i) => i.href !== "/").find((i) => pathname === i.href || pathname.startsWith(i.href + "/"));
}
