import { Laptop, Link2Off, PackageCheck, ShieldCheck, TimerOff } from "lucide-react";
import { PageHeader } from "@/components/console/page-header";
import { Panel } from "@/components/console/panel";
import { KpiCard } from "@/components/console/kpi";
import { BarList } from "@/components/console/bar-list";
import { DevicesTable } from "@/components/console/devices-table";
import { Stagger } from "@/components/motion/primitives";
import { listDevices, policyRollout, versionDistribution } from "@/lib/server/queries";
import { parseRange } from "@/lib/range";

export const metadata = { title: "Fleet" };

/** Highest semver among reported versions. */
function latest(versions: string[]): string | null {
  const parsed = versions.filter((v) => /^\d+\.\d+\.\d+/.test(v));
  if (!parsed.length) return null;
  return parsed.sort((a, b) => {
    const pa = a.split(".").map((n) => parseInt(n, 10));
    const pb = b.split(".").map((n) => parseInt(n, 10));
    for (let i = 0; i < 3; i++) if (pa[i] !== pb[i]) return pb[i] - pa[i];
    return 0;
  })[0];
}

export default async function FleetPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const range = parseRange((await searchParams).range);
  const rq = range === "7d" ? "" : `?range=${range}`;
  const devices = listDevices();
  const versions = versionDistribution();
  const newest = latest(versions.map((v) => v.version));
  const rollout = policyRollout();
  const reporting = devices.filter((d) => d.compliant != null);
  const compliant = reporting.filter((d) => d.compliant).length;
  const stale = devices.filter((d) => d.stale).length;
  const current = devices.filter((d) => d.rvVersion === newest).length;
  const chainIssues = devices.filter((d) => d.chainVerdict === "broken" || d.chainVerdict === "behind").length;
  const topSerial = rollout.filter((r) => r.state === "active").reduce((m, r) => Math.max(m, r.serial ?? 0), 0);

  return (
    <>
      <PageHeader
        title="Fleet"
        description={<>Every machine that forwards events or posts an <code className="font-mono">rv report</code>. Compliance uses rv&apos;s own rule: valid org policy, MCP gateway check passing, no secret policy violations, intact local audit chain.</>}
      />
      <Stagger className="grid gap-3">
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-5">
          <KpiCard label="Enrolled devices" value={devices.length} icon={Laptop} footnote={`${reporting.length} posting reports`} />
          <KpiCard label="Compliant" value={reporting.length ? Math.round((compliant / reporting.length) * 100) : 0} suffix="%" icon={ShieldCheck} tone={compliant === reporting.length ? "good" : "warning"} footnote={`${compliant} of ${reporting.length}`} />
          <KpiCard label={`On rv ${newest ?? "latest"}`} value={current} icon={PackageCheck} footnote={`${devices.filter((d) => d.rvVersion && d.rvVersion !== newest).length} need an update`} />
          <KpiCard label="Chain issues" value={chainIssues} icon={Link2Off} tone={chainIssues ? "critical" : undefined} footnote="broken or behind" href="/integrity" />
          <KpiCard label="Stale" value={stale} icon={TimerOff} tone={stale ? "warning" : undefined} footnote="silent for 24h+" />
        </div>
        <div className="grid gap-3 xl:grid-cols-[minmax(0,1fr)_320px]">
          <Panel title="Devices" flush bodyClassName="pb-2">
            <DevicesTable devices={devices} latestVersion={newest} rangeQuery={rq} />
          </Panel>
          <div className="grid content-start gap-3">
            <Panel title="rv versions">
              <BarList items={versions.map((v) => ({
                key: v.version, label: <span className="font-mono">{v.version}</span>, sublabel: v.version === newest ? "latest" : undefined,
                segments: [{ tone: v.version === newest ? "good" : "observed", value: v.count, label: "Devices" }],
              }))} />
            </Panel>
            <Panel title="Org policy rollout" description={topSerial ? `Latest serial ${topSerial}` : "No organization policy reported"}>
              <BarList items={rollout.map((r) => ({
                key: `${r.state}-${r.serial}`,
                label: r.state === "active" ? `Serial ${r.serial}` : r.state === "invalid" ? "Invalid bundle" : "No org policy",
                sublabel: r.organization ?? undefined,
                segments: [{ tone: r.state === "active" && r.serial === topSerial ? "good" : r.state === "invalid" ? "critical" : "observed", value: r.count, label: "Devices" }],
              }))} />
            </Panel>
          </div>
        </div>
      </Stagger>
    </>
  );
}
