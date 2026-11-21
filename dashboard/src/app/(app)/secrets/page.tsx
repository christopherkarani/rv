import { Fingerprint, KeyRound, ShieldAlert, ShieldX } from "lucide-react";
import { PageHeader } from "@/components/console/page-header";
import { EmptyState, Panel } from "@/components/console/panel";
import { KpiCard } from "@/components/console/kpi";
import { EventList } from "@/components/console/event-list";
import { StatusPill } from "@/components/console/badges";
import { Stagger } from "@/components/motion/primitives";
import { secretAlerts, secretStats } from "@/lib/server/queries";
import { parseRange, RANGES } from "@/lib/range";
import { fmtAgo, fmtFull } from "@/lib/format";

export const metadata = { title: "Secrets" };

export default async function SecretsPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const range = parseRange((await searchParams).range);
  const stats = secretStats(range);
  const alerts = secretAlerts(range);
  const total = (k: "uses" | "refused" | "misuse") => stats.reduce((n, s) => n + s[k], 0);
  return (
    <>
      <PageHeader
        eyebrow={RANGES[range].label}
        title="Secrets"
        description="How agents spend secrets through rv's gateway. Agents see placeholders; rv injects real values at the boundary and records names and keyed fingerprints, never values."
      />
      <Stagger className="grid gap-3">
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <KpiCard label="Secrets in use" value={stats.length} icon={KeyRound} footnote="distinct names" />
          <KpiCard label="Uses" value={total("uses")} icon={Fingerprint} footnote="staged and forwarded" />
          <KpiCard label="Refused" value={total("refused")} icon={ShieldX} tone="blocked" footnote="gateway refusals" />
          <KpiCard label="Misuse alerts" value={total("misuse")} icon={ShieldAlert} tone={total("misuse") ? "critical" : undefined} footnote="against the secret's policy" />
        </div>
        <div className="grid gap-3 xl:grid-cols-[minmax(0,1fr)_420px]">
          <Panel title="Secrets" flush bodyClassName="pb-2">
            {stats.length === 0 ? <EmptyState icon={KeyRound} title="No secret use in this range" /> : (
              <div className="overflow-x-auto">
                <table className="w-full min-w-[680px] text-left text-[12.5px]">
                  <thead>
                    <tr className="border-y text-[11px] text-muted-foreground">
                      <th className="py-2 pr-2 pl-4 font-medium">Name</th>
                      <th className="px-2 py-2 font-medium">Status</th>
                      <th className="px-2 py-2 text-right font-medium">Uses</th>
                      <th className="px-2 py-2 text-right font-medium">Refused</th>
                      <th className="px-2 py-2 text-right font-medium">Misuse</th>
                      <th className="px-2 py-2 text-right font-medium">Devices</th>
                      <th className="px-2 py-2 font-medium">Fingerprint</th>
                      <th className="px-2 py-2 pr-4 font-medium">Last</th>
                    </tr>
                  </thead>
                  <tbody>
                    {stats.map((s) => (
                      <tr key={s.name} className="border-b border-border/60 hover:bg-hover">
                        <td className="py-2 pr-2 pl-4 font-mono text-[12px]">{s.name}</td>
                        <td className="px-2 py-2">{s.misuse ? <StatusPill status="critical" label="Misuse" /> : s.refused ? <StatusPill status="warning" label="Refusals" /> : <StatusPill status="good" label="Clean" />}</td>
                        <td className="px-2 py-2 text-right font-mono tabular-nums">{fmtFull(s.uses)}</td>
                        <td className="px-2 py-2 text-right font-mono tabular-nums">{fmtFull(s.refused)}</td>
                        <td className="px-2 py-2 text-right font-mono tabular-nums">{fmtFull(s.misuse)}</td>
                        <td className="px-2 py-2 text-right font-mono tabular-nums">{s.devices}</td>
                        <td className="px-2 py-2 font-mono text-[11px] text-muted-foreground">{s.fingerprint ?? "—"}</td>
                        <td className="px-2 py-2 pr-4 text-[11.5px] text-muted-foreground">{fmtAgo(s.lastSeen)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Panel>
          <Panel title="Alerts" description="Misuse and refusals, newest first">
            <EventList events={alerts.slice(0, 20)} empty="No misuse or refusals" />
          </Panel>
        </div>
      </Stagger>
    </>
  );
}
