import Link from "next/link";
import { CircleAlert, Gauge, Hand, Plug, ShieldX } from "lucide-react";
import { PageHeader } from "@/components/console/page-header";
import { EmptyState, Panel } from "@/components/console/panel";
import { KpiCard } from "@/components/console/kpi";
import { BarList } from "@/components/console/bar-list";
import { EventList } from "@/components/console/event-list";
import { StatusPill } from "@/components/console/badges";
import { Stagger } from "@/components/motion/primitives";
import { mcpSignals, mcpTools } from "@/lib/server/queries";
import { parseRange, RANGES } from "@/lib/range";
import { fmtAgo, fmtFull, fmtMs } from "@/lib/format";

export const metadata = { title: "MCP gateway" };

export default async function MCPPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const range = parseRange((await searchParams).range);
  const rq = range === "7d" ? "" : `&range=${range}`;
  const tools = mcpTools(range);
  const signals = mcpSignals(range);
  const total = (k: "allowed" | "denied" | "pending" | "errors" | "asks") => tools.reduce((n, t) => n + t[k], 0);
  const calls = total("allowed") + total("denied") + total("pending");
  const timed = tools.filter((t) => t.avgMs != null);
  const avg = timed.length ? Math.round(timed.reduce((n, t) => n + (t.avgMs ?? 0) * t.allowed, 0) / Math.max(1, timed.reduce((n, t) => n + t.allowed, 0))) : 0;
  const servers = new Map<string, { allowed: number; denied: number; pending: number }>();
  for (const t of tools) {
    const s = servers.get(t.server) ?? { allowed: 0, denied: 0, pending: 0 };
    s.allowed += t.allowed; s.denied += t.denied; s.pending += t.pending;
    servers.set(t.server, s);
  }

  return (
    <>
      <PageHeader
        eyebrow={RANGES[range].label}
        title="MCP gateway"
        description={<>Tool calls through <code className="font-mono">rv mcp serve</code>: per-tool allow / ask / deny, human approvals, and how long servers take. Argument names are recorded, values never are.</>}
      />
      <Stagger className="grid gap-3">
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-5">
          <KpiCard label="Tool calls" value={calls} icon={Plug} tone="mcp" footnote={`${tools.length} tools`} />
          <KpiCard label="Denied" value={total("denied")} icon={ShieldX} tone="blocked" footnote="by policy or a person" />
          <KpiCard label="Needed approval" value={total("asks")} icon={Hand} footnote="ask policy" />
          <KpiCard label="Errored" value={total("errors")} icon={CircleAlert} tone={total("errors") ? "warning" : undefined} footnote="upstream errors" />
          <KpiCard label="Avg latency" value={avg} suffix="ms" icon={Gauge} footnote="allowed calls" />
        </div>
        <div className="grid gap-3 xl:grid-cols-[minmax(0,1fr)_360px]">
          <Panel title="Tools" description="Every server/tool agents called" flush bodyClassName="pb-2">
            {tools.length === 0 ? <EmptyState icon={Plug} title="No MCP calls in this range">Put servers behind the gateway with <code className="font-mono">rv mcp setup</code>.</EmptyState> : (
              <div className="overflow-x-auto">
                <table className="w-full min-w-[860px] text-left text-[12.5px]">
                  <thead>
                    <tr className="border-y text-[11px] text-muted-foreground">
                      <th className="py-2 pr-2 pl-4 font-medium">Tool</th>
                      <th className="px-2 py-2 font-medium">Policy</th>
                      <th className="px-2 py-2 text-right font-medium">Allowed</th>
                      <th className="px-2 py-2 text-right font-medium">Denied</th>
                      <th className="px-2 py-2 text-right font-medium">Errors</th>
                      <th className="px-2 py-2 text-right font-medium">Avg</th>
                      <th className="px-2 py-2 text-right font-medium">Max</th>
                      <th className="px-2 py-2 text-right font-medium">Devices</th>
                      <th className="px-2 py-2 pr-4 font-medium">Last call</th>
                    </tr>
                  </thead>
                  <tbody>
                    {tools.map((t) => {
                      const policy = t.allowed === 0 && t.denied > 0 && t.asks === 0 ? "deny" : t.asks > 0 ? "ask" : "allow";
                      return (
                        <tr key={t.subject} className="group border-b border-border/60 hover:bg-hover">
                          <td className="py-2 pr-2 pl-4">
                            <Link href={`/activity?kind=mcp.call&q=${encodeURIComponent(t.subject)}${rq}`} className="font-mono text-[12px] group-hover:underline">
                              <span className="text-muted-foreground">{t.server}/</span>{t.tool}
                            </Link>
                          </td>
                          <td className="px-2 py-2">
                            {policy === "deny" ? <StatusPill status="critical" label="deny" /> : policy === "ask" ? <StatusPill status="warning" label="ask" /> : <StatusPill status="good" label="allow" />}
                          </td>
                          <td className="px-2 py-2 text-right font-mono tabular-nums">{fmtFull(t.allowed)}</td>
                          <td className="px-2 py-2 text-right font-mono tabular-nums">{fmtFull(t.denied)}</td>
                          <td className="px-2 py-2 text-right font-mono tabular-nums text-muted-foreground">{fmtFull(t.errors)}</td>
                          <td className="px-2 py-2 text-right font-mono tabular-nums">{fmtMs(t.avgMs)}</td>
                          <td className="px-2 py-2 text-right font-mono tabular-nums text-muted-foreground">{fmtMs(t.maxMs)}</td>
                          <td className="px-2 py-2 text-right font-mono tabular-nums">{t.devices}</td>
                          <td className="px-2 py-2 pr-4 text-[11.5px] text-muted-foreground">{fmtAgo(t.lastSeen)}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </Panel>
          <div className="grid content-start gap-3">
            <Panel title="By server">
              <BarList items={[...servers.entries()].sort((a, b) => (b[1].allowed + b[1].denied) - (a[1].allowed + a[1].denied)).map(([name, s]) => ({
                key: name, label: <span className="font-mono">{name}</span>,
                segments: [
                  { tone: "mcp", value: s.allowed, label: "Allowed" },
                  { tone: "blocked", value: s.denied, label: "Denied" },
                ],
              }))} />
            </Panel>
            <Panel title="Gateway signals" description="Approvals, changed tool definitions, ungoverned hosts">
              <EventList events={signals.slice(0, 12)} empty="No approvals or tool changes" />
            </Panel>
          </div>
        </div>
      </Stagger>
    </>
  );
}
