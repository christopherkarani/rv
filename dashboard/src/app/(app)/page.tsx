import Link from "next/link";
import { ArrowUpRight, Eye, KeyRound, Laptop, Plug, ShieldX, Undo2 } from "lucide-react";
import { PageHeader } from "@/components/console/page-header";
import { Panel } from "@/components/console/panel";
import { KpiCard } from "@/components/console/kpi";
import { TimelineChart } from "@/components/console/timeline-chart";
import { BarList } from "@/components/console/bar-list";
import { LiveFeed } from "@/components/console/live-feed";
import { Ring } from "@/components/console/ring";
import { SeverityBadge, StatusPill } from "@/components/console/badges";
import { Stagger } from "@/components/motion/primitives";
import { byAgentHost, overviewKpis, recentEvents, timeline, topRules } from "@/lib/server/queries";
import { parseRange, RANGES } from "@/lib/range";
import { hostLabel } from "@/lib/kinds";
import { fmtNumber } from "@/lib/format";

export const metadata = { title: "Overview" };

export default async function OverviewPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const range = parseRange((await searchParams).range);
  const rq = range === "7d" ? "" : `?range=${range}`;
  const kpis = overviewKpis(range);
  const points = timeline(range);
  const rules = topRules(range, 8);
  const hosts = byAgentHost(range);
  const feed = recentEvents(14);
  const spark = (key: "blocked" | "observed" | "overrides" | "mcp") => points.map((p) => p[key]);
  const compliancePct = kpis.reportingDevices ? kpis.compliantDevices / kpis.reportingDevices : 0;

  return (
    <>
      <PageHeader
        eyebrow={RANGES[range].label}
        title="Overview"
        description="What rv stopped across your fleet, what it would have stopped in observe mode, and whether every machine's audit trail is intact."
      />
      <Stagger className="grid gap-3">
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-3 2xl:grid-cols-6">
          <KpiCard label="Blocked" value={kpis.blocked.value} previous={kpis.blocked.previous} icon={ShieldX} tone="blocked" spark={spark("blocked")} href={`/activity?decision=denied${rq.replace("?", "&")}`} />
          <KpiCard label="Would-be blocks" value={kpis.observed.value} previous={kpis.observed.previous} icon={Eye} tone="observed" spark={spark("observed")} href={`/activity?kind=command.observed${rq.replace("?", "&")}`} goodWhen="down" />
          <KpiCard label="Overrides" value={kpis.overrides.value} previous={kpis.overrides.previous} icon={Undo2} tone="override" spark={spark("overrides")} href={`/activity?kind=command.override${rq.replace("?", "&")}`} goodWhen="down" />
          <KpiCard label="MCP calls" value={kpis.mcpCalls.value} previous={kpis.mcpCalls.previous} icon={Plug} tone="mcp" spark={spark("mcp")} href={`/mcp${rq}`} />
          <KpiCard label="Secret misuse" value={kpis.secretMisuse.value} previous={kpis.secretMisuse.previous} icon={KeyRound} tone={kpis.secretMisuse.value ? "critical" : undefined} href={`/secrets${rq}`} goodWhen="down" />
          <KpiCard label="Active devices" value={kpis.activeDevices.value} previous={kpis.activeDevices.previous} icon={Laptop} href={`/fleet${rq}`} footnote={<span>of {kpis.totalDevices} enrolled</span>} />
        </div>

        <div className="grid gap-3 xl:grid-cols-[minmax(0,1fr)_380px]">
          <Panel title="Gate decisions" description={`Per ${RANGES[range].bucketMs >= 86_400_000 ? "day" : RANGES[range].bucketMs > 3_600_000 ? `${RANGES[range].bucketMs / 3_600_000} hours` : "hour"}, all devices. Click a series to show or hide it.`}>
            <TimelineChart data={points} bucketMs={RANGES[range].bucketMs} height={300} />
          </Panel>
          <Panel title="Live activity" description="Newest events as machines forward them" className="xl:row-span-2">
            <LiveFeed initial={feed} />
          </Panel>
          <div className="grid gap-3 lg:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
            <Panel
              title="Top rules"
              description="Blocked and would-be blocked, by rule"
              action={<Link href={`/detections${rq}`} className="flex items-center gap-0.5 text-xs text-muted-foreground hover:text-foreground">All <ArrowUpRight className="size-3" /></Link>}
            >
              <BarList
                items={rules.map((r) => ({
                  key: r.rule,
                  href: `/activity?q=${encodeURIComponent(r.rule)}${rq.replace("?", "&")}`,
                  label: <span className="mono">{r.rule}</span>,
                  sublabel: <SeverityBadge severity={r.severity} />,
                  segments: [
                    { tone: "blocked", value: r.blocked, label: "Blocked" },
                    { tone: "observed", value: r.observed, label: "Would-be" },
                  ],
                }))}
              />
            </Panel>
            <div className="grid gap-3">
              <Panel title="Fleet compliance" description="From the latest rv report per machine">
                <div className="flex items-center gap-5">
                  <Ring value={kpis.compliantDevices} total={kpis.reportingDevices} label="compliant" color={compliancePct >= 0.9 ? "var(--status-good)" : compliancePct >= 0.7 ? "var(--status-warning)" : "var(--status-critical)"} />
                  <div className="grid gap-2 text-[12.5px]">
                    <div className="flex items-center gap-2"><StatusPill status="good" label={`${kpis.compliantDevices} compliant`} /></div>
                    <div className="flex items-center gap-2"><StatusPill status={kpis.reportingDevices - kpis.compliantDevices ? "critical" : "neutral"} label={`${kpis.reportingDevices - kpis.compliantDevices} not compliant`} /></div>
                    <div className="flex items-center gap-2"><StatusPill status={kpis.brokenChains ? "critical" : "good"} label={kpis.brokenChains ? `${kpis.brokenChains} broken chains` : "All chains intact"} /></div>
                    <Link href="/fleet" className="text-xs text-muted-foreground hover:text-foreground">{kpis.totalDevices - kpis.reportingDevices} without a report →</Link>
                  </div>
                </div>
              </Panel>
              <Panel title="By agent" description="Blocks per agent host">
                <BarList
                  items={hosts.slice(0, 6).map((h) => ({
                    key: h.host,
                    href: `/activity?host=${encodeURIComponent(h.host)}${rq.replace("?", "&")}`,
                    label: hostLabel(h.host),
                    sublabel: `${h.devices} device${h.devices === 1 ? "" : "s"}`,
                    segments: [
                      { tone: "blocked", value: h.blocked, label: "Blocked" },
                      { tone: "override", value: h.overrides, label: "Overrides" },
                      { tone: "observed", value: h.observed, label: "Would-be" },
                    ],
                  }))}
                />
              </Panel>
            </div>
          </div>
        </div>
        <p className="px-1 text-[11px] text-muted-foreground">
          {fmtNumber(kpis.totalEvents)} events in range. Plain allows are not logged by rv, so blocks are counted against what agents tried, not against every command.
        </p>
      </Stagger>
    </>
  );
}
