"use client";

import { useRouter } from "next/navigation";
import { useTheme } from "next-themes";
import { useState } from "react";
import { Clock, Copy, Download, LogOut, Monitor, Moon, Search, Sun } from "lucide-react";
import { toast } from "sonner";
import {
  Command, CommandDialog, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList, CommandSeparator, CommandShortcut,
} from "@/components/ui/command";
import { RANGES, type RangeKey } from "@/lib/range";
import { logoutAction } from "@/app/actions";
import { NAV_ITEMS } from "./nav";
import { useRange } from "./use-range";

export function CommandPalette({ open, onOpenChange, devices }: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  devices: { id: string; hostname: string }[];
}) {
  const router = useRouter();
  const { setTheme } = useTheme();
  const { setRange, withRange } = useRange();
  const [query, setQuery] = useState("");
  const run = (fn: () => void) => {
    onOpenChange(false);
    setQuery("");
    fn();
  };
  return (
    <CommandDialog open={open} onOpenChange={onOpenChange} title="Command palette" description="Jump to a page, a device, or search events" className="sm:max-w-xl">
      <Command loop>
      <CommandInput placeholder="Type a command or search…" value={query} onValueChange={setQuery} />
      <CommandList className="max-h-[min(60vh,420px)]">
        <CommandEmpty>No matches.</CommandEmpty>
        {query.trim().length > 1 && (
          <CommandGroup heading="Search">
            <CommandItem value={`search ${query}`} onSelect={() => run(() => router.push(withRange(`/activity?q=${encodeURIComponent(query.trim())}`)))}>
              <Search /> Search events for <span className="font-mono text-foreground">“{query.trim()}”</span>
              <CommandShortcut>↵</CommandShortcut>
            </CommandItem>
          </CommandGroup>
        )}
        <CommandGroup heading="Go to">
          {NAV_ITEMS.map((item) => (
            <CommandItem key={item.href} value={`go ${item.title} ${item.hint}`} onSelect={() => run(() => router.push(withRange(item.href)))}>
              <item.icon />
              <span>{item.title}</span>
              <span className="truncate text-xs text-muted-foreground">{item.hint}</span>
              {item.keys && <CommandShortcut>{item.keys}</CommandShortcut>}
            </CommandItem>
          ))}
        </CommandGroup>
        {devices.length > 0 && (
          <CommandGroup heading="Devices">
            {devices.slice(0, 50).map((d) => (
              <CommandItem key={d.id} value={`device ${d.hostname}`} onSelect={() => run(() => router.push(withRange(`/fleet/${encodeURIComponent(d.id)}`)))}>
                <Monitor /> <span className="font-mono">{d.hostname}</span>
              </CommandItem>
            ))}
          </CommandGroup>
        )}
        <CommandSeparator />
        <CommandGroup heading="Time range">
          {(Object.keys(RANGES) as RangeKey[]).map((key) => (
            <CommandItem key={key} value={`range ${RANGES[key].label}`} onSelect={() => run(() => setRange(key))}>
              <Clock /> {RANGES[key].label}
            </CommandItem>
          ))}
        </CommandGroup>
        <CommandGroup heading="Actions">
          <CommandItem value="export events csv" onSelect={() => run(() => {
            const a = document.createElement("a");
            a.href = "/api/v1/export?format=csv";
            a.download = "";
            a.click();
          })}>
            <Download /> Export events as CSV
          </CommandItem>
          <CommandItem value="copy ingest url" onSelect={() => run(() => {
            void navigator.clipboard.writeText(`${window.location.origin}/api/v1/ingest`);
            toast.success("Ingest URL copied");
          })}>
            <Copy /> Copy ingest URL
          </CommandItem>
          <CommandItem value="theme dark" onSelect={() => run(() => setTheme("dark"))}><Moon /> Dark theme</CommandItem>
          <CommandItem value="theme light" onSelect={() => run(() => setTheme("light"))}><Sun /> Light theme</CommandItem>
          <CommandItem value="theme system" onSelect={() => run(() => setTheme("system"))}><Monitor /> System theme</CommandItem>
          <CommandItem value="sign out logout" onSelect={() => run(() => { void logoutAction(); })}><LogOut /> Sign out</CommandItem>
        </CommandGroup>
      </CommandList>
      </Command>
    </CommandDialog>
  );
}
