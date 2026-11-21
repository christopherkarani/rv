import Link from "next/link";
import { CircleDashed, Clock, Link2, Link2Off } from "lucide-react";
import { PageHeader } from "@/components/console/page-header";
import { EmptyState, Panel } from "@/components/console/panel";
import { KpiCard } from "@/components/console/kpi";
import { ChainBadge } from "@/components/console/badges";
import { Stagger } from "@/components/motion/primitives";
import { listDevices, recentChainBreaks } from "@/lib/server/queries";
import { fmtAgo, fmtFull, fmtTime, shortHash } from "@/lib/format";

export const metadata = { title: "Integrity" };

const ORDER = { broken: 0, behind: 1, unchained: 2, intact: 3 } as const;

export default async function IntegrityPage() {
  const devices = listDevices().sort((a, b) => ORDER[a.chainVerdict] - ORDER[b.chainVerdict] || b.chainEvents - a.chainEvents);
  const breaks = recentChainBreaks(30);
  const count = (v: keyof typeof ORDER) => devices.filter((d) => d.chainVerdict === v).length;
  const verified = devices.reduce((n, d) => n + d.chainEvents, 0);
  return (
    <>
      <PageHeader
        title="Integrity"
        description={<>rv hash-chains its audit log: each line carries the SHA-256 of the one before. The chain is unkeyed, so a machine alone cannot prove it was not rewritten. The console keeps the head off the machine and checks every forwarded event against it.</>}
      />
      <Stagger className="grid gap-3">
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <KpiCard label="Intact" value={count("intact")} icon={Link2} tone="good" footnote={`${fmtFull(verified)} events verified`} />
          <KpiCard label="Broken" value={count("broken")} icon={Link2Off} tone={count("broken") ? "critical" : undefined} footnote="edited, removed or reordered lines" />
          <KpiCard label="Behind" value={count("behind")} icon={Clock} tone={count("behind") ? "warning" : undefined} footnote="report names an unforwarded head" />
          <KpiCard label="No chain yet" value={count("unchained")} icon={CircleDashed} footnote="no chained events received" />
        </div>
        <div className="grid gap-3 xl:grid-cols-[minmax(0,1fr)_400px]">
          <Panel title="Devices" flush bodyClassName="pb-2">
            <div className="overflow-x-auto">
              <table className="w-full min-w-[760px] text-left text-[12.5px]">
                <thead>
                  <tr className="border-y text-[11px] text-muted-foreground">
                    <th className="py-2 pr-2 pl-4 font-medium">Device</th>
                    <th className="px-2 py-2 font-medium">Chain</th>
                    <th className="px-2 py-2 text-right font-medium">Chained events</th>
                    <th className="px-2 py-2 text-right font-medium">Breaks</th>
                    <th className="px-2 py-2 font-medium">Console head</th>
                    <th className="px-2 py-2 pr-4 font-medium">Last event</th>
                  </tr>
                </thead>
                <tbody>
                  {devices.map((d) => (
                    <tr key={d.id} className="group border-b border-border/60 hover:bg-hover">
                      <td className="py-2 pr-2 pl-4"><Link href={`/fleet/${encodeURIComponent(d.id)}`} className="mono group-hover:underline">{d.hostname}</Link></td>
                      <td className="px-2 py-2"><ChainBadge verdict={d.chainVerdict} /></td>
                      <td className="px-2 py-2 text-right font-mono tabular-nums">{fmtFull(d.chainEvents)}</td>
                      <td className="px-2 py-2 text-right font-mono tabular-nums">{d.chainBreaks}</td>
                      <td className="px-2 py-2 font-mono text-[11px] text-muted-foreground">{shortHash(d.chainHead, 16)}</td>
                      <td className="px-2 py-2 pr-4 text-[11.5px] text-muted-foreground">{fmtAgo(d.lastEventAt)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {devices.length === 0 && <EmptyState icon={Link2} title="No devices yet" />}
            </div>
          </Panel>
          <div className="grid content-start gap-3">
            <Panel title="Recent breaks" description="An event whose prev did not match the head the console held">
              {breaks.length === 0 ? <EmptyState icon={Link2} title="No breaks detected">Every chained event followed the one before it.</EmptyState> : (
                <ul className="grid gap-2">
                  {breaks.map((b) => (
                    <li key={`${b.deviceId}-${b.seq}`} className="rounded-lg border border-status-critical/30 bg-status-critical/6 p-3">
                      <div className="flex items-center justify-between gap-2">
                        <Link href={`/fleet/${encodeURIComponent(b.deviceId)}`} className="mono font-medium hover:underline">{b.hostname}</Link>
                        <span className="text-[11px] text-muted-foreground">{fmtTime(b.time)}</span>
                      </div>
                      <dl className="mt-2 grid grid-cols-[64px_minmax(0,1fr)] gap-x-2 gap-y-0.5 font-mono text-[11px]">
                        <dt className="text-muted-foreground">expected</dt><dd className="truncate">{b.expected}</dd>
                        <dt className="text-muted-foreground">got</dt><dd className="truncate">{b.got ?? "none"}</dd>
                      </dl>
                    </li>
                  ))}
                </ul>
              )}
            </Panel>
            <Panel title="What each verdict means">
              <dl className="grid gap-2.5 text-[12px]">
                <div><dt><ChainBadge verdict="intact" /></dt><dd className="mt-1 text-muted-foreground">Every chained event followed the head before it, and the latest report&apos;s head was received.</dd></div>
                <div><dt><ChainBadge verdict="broken" /></dt><dd className="mt-1 text-muted-foreground">A line was edited, removed, inserted or reordered on the machine, or its local <code className="font-mono">rv audit verify</code> fails. Investigate the device.</dd></div>
                <div><dt><ChainBadge verdict="behind" /></dt><dd className="mt-1 text-muted-foreground">The machine&apos;s report names a head the console never got: events wait to be forwarded, or the tail was cut.</dd></div>
                <div><dt><ChainBadge verdict="unchained" /></dt><dd className="mt-1 text-muted-foreground">Nothing chained received yet (only ledgers outside <code className="font-mono">audit.jsonl</code>, or no events).</dd></div>
              </dl>
            </Panel>
          </div>
        </div>
      </Stagger>
    </>
  );
}
