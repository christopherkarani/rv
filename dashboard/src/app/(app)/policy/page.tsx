import { FileCog, Fingerprint, ShieldOff, TrendingDown } from "lucide-react";
import { PageHeader } from "@/components/console/page-header";
import { Panel } from "@/components/console/panel";
import { KpiCard } from "@/components/console/kpi";
import { BarList } from "@/components/console/bar-list";
import { EventList } from "@/components/console/event-list";
import { Stagger } from "@/components/motion/primitives";
import { ownerActions, policyChanges, policyRollout } from "@/lib/server/queries";
import { parseRange, RANGES } from "@/lib/range";

export const metadata = { title: "Policy & changes" };

export default async function PolicyPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const range = parseRange((await searchParams).range);
  const changes = policyChanges(range);
  const owner = ownerActions(range);
  const rollout = policyRollout();
  const loosening = changes.filter((c) => c.detail.direction === "loosening");
  const unauthorized = loosening.filter((c) => (c.detail.authorized_by ?? "none") === "none");
  const bySetting = new Map<string, { loosen: number; tighten: number }>();
  for (const c of changes) {
    const key = c.detail.setting ?? c.subject;
    const v = bySetting.get(key) ?? { loosen: 0, tighten: 0 };
    if (c.detail.direction === "loosening") v.loosen++; else v.tighten++;
    bySetting.set(key, v);
  }
  const topSerial = rollout.reduce((m, r) => Math.max(m, r.serial ?? 0), 0);
  return (
    <>
      <PageHeader
        eyebrow={RANGES[range].label}
        title="Policy & changes"
        description="Every change to rv's own rules is recorded before it applies, with its direction and the owner check that allowed it. Loosening without owner authentication deserves a look."
      />
      <Stagger className="grid gap-3">
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <KpiCard label="Rule changes" value={changes.length} icon={FileCog} footnote="config, policy, org bundle" />
          <KpiCard label="Loosening" value={loosening.length} icon={TrendingDown} tone={loosening.length ? "warning" : undefined} footnote="made the gate weaker" />
          <KpiCard label="Loosened without owner auth" value={unauthorized.length} icon={ShieldOff} tone={unauthorized.length ? "critical" : undefined} footnote="authorized_by: none" />
          <KpiCard label="Owner auth refused" value={owner.refused} icon={Fingerprint} tone={owner.refused ? "warning" : undefined} footnote={`of ${owner.total} attempts`} />
        </div>
        <div className="grid gap-3 xl:grid-cols-[minmax(0,1fr)_360px]">
          <Panel title="Change log" description="Newest first. Click a change for its full record.">
            <EventList events={changes.slice(0, 60)} detail="change" empty="No rule changes in this range" />
          </Panel>
          <div className="grid content-start gap-3">
            <Panel title="By setting">
              <BarList items={[...bySetting.entries()].sort((a, b) => (b[1].loosen + b[1].tighten) - (a[1].loosen + a[1].tighten)).map(([setting, v]) => ({
                key: setting, label: <span className="font-mono">{setting}</span>,
                segments: [
                  { tone: "blocked", value: v.loosen, label: "Loosening" },
                  { tone: "good", value: v.tighten, label: "Tightening" },
                ],
              }))} />
            </Panel>
            <Panel title="Org policy rollout" description={topSerial ? `Latest serial ${topSerial}` : "No organization policy reported"}>
              <BarList items={rollout.map((r) => ({
                key: `${r.state}-${r.serial}`,
                label: r.state === "active" ? `Serial ${r.serial}` : r.state === "invalid" ? "Invalid bundle" : "No org policy",
                sublabel: r.organization ?? undefined,
                segments: [{ tone: r.state === "active" && r.serial === topSerial ? "good" : r.state === "invalid" ? "critical" : "observed", value: r.count, label: "Devices" }],
              }))} />
              <p className="mt-3 text-[11.5px] text-muted-foreground">
                The organization bundle only restricts: required packs, strict safety, blocked MCP servers, allowed secret sources, and where <code className="font-mono">audit forward</code> sends events.
              </p>
            </Panel>
          </div>
        </div>
      </Stagger>
    </>
  );
}
