"use client";

/** Open editor tabs, persisted per browser. An external store, so React reads it without effects. */
const STORAGE_KEY = "rvc.tabs.v1";
const MAX_TABS = 8;
const EMPTY: string[] = [];

let tabs: string[] | null = null;
const listeners = new Set<() => void>();

function load(): string[] {
  if (tabs) return tabs;
  try {
    const raw = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "[]");
    tabs = Array.isArray(raw) ? raw.filter((h): h is string => typeof h === "string") : [];
  } catch {
    tabs = [];
  }
  return tabs;
}

function save(next: string[]) {
  tabs = next;
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(next)); } catch { /* private mode */ }
  listeners.forEach((l) => l());
}

export const tabsStore = {
  subscribe(listener: () => void) {
    listeners.add(listener);
    return () => { listeners.delete(listener); };
  },
  getSnapshot: () => load(),
  getServerSnapshot: () => EMPTY,
  open(href: string) {
    const current = load();
    if (!current.includes(href)) save([...current, href].slice(-MAX_TABS));
  },
  close(href: string) {
    save(load().filter((t) => t !== href));
  },
};
