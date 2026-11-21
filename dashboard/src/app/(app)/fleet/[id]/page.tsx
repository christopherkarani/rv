import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft, Eye, KeyRound, Plug, ShieldX } from "lucide-react";
import { PageHeader } from "@/components/console/page-header";
import { EmptyState, Panel } from "@/components/console/panel";
import { KpiCard } from "@/components/console/kpi";
import { TimelineChart } from "@/components/console/timeline-chart";
import { LiveFeed } from "@/components/console/live-feed";
import { ChainBadge, StatusPill } from "@/components/console/badges";
import { Stagger } from "@/components/motion/primitives";
import { getDevice, searchEvents, timeline } from "@/lib/server/queries";
import { complianceFindings, type RVReport } from "@/lib/ingest/report";
import { parseRange, RANGES } from "@/lib/range";
import { fmtAgo, fmtTime, shortHash } from "@/lib/format";
import { hostLabel } from "@/lib/kinds";

export const metadata = { title: "Device" };

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-[140px_minmax(0,1fr)] gap-3 border-b border-dashed py-2 text-[12.5px] last:border-0">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="min-w-0 break-words">{children}</dd>
    </div>
  );
}

export default async function DevicePage({ params, searchParams }: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  const { id } = await params;
  const range = parseRange((await searchParams).range);
  const data = getDevice(decodeURIComponent(id));
  if (!data) notFound();
  const { device, breaks } = data;
  const report = data.report as RVReport | null;
  const points = timeline(range, { deviceId: device.id });
  const sum = (k: "blocked" | "observed" | "mcp" | "overrides") => points.reduce((n, p) => n + p[k], 0);
  const misuse = searchEvents({ device: device.id, kind: "secret.misuse", range, limit: 1 }).total;
  const recent = searchEvents({ device: device.id, limit: 14 }).rows;
  const findings = report ? complianceFindings(report) : [];

  return (
    <>
      <Link href="/fleet" className="mb-3 inline-flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"><ArrowLeft className="size-3" /> Fleet</Link>
      <PageHeader
        eyebrow={`${device.platform ?? "unknown platform"} · ${device.osUser ?? "unknown user"}`}
        title={device.hostname}
        description={<>First seen {fmtAgo(device.firstSeen)}, last seen {fmtAgo(device.lastSeen)}{report ? <>, last report {fmtAgo(device.reportAt)}</> : null}.</>}
        actions={
          <div className="flex flex-wrap gap-1.5">
            {device.compliant == null ? <StatusPill status="pending" label="No report" /> : device.compliant ? <StatusPill status="good" label="Compliant" /> : <StatusPill status="critical" label="Not compliant" />}
            <ChainBadge verdict={device.chainVerdict} />
            {device.rvVersion && <StatusPill status="neutral" label={`rv ${device.rvVersion}`} />}
          </div>
        }
      />
      <Stagger className="grid gap-3">
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <KpiCard label="Blocked" value={sum("blocked")} icon={ShieldX} tone="blocked" spark={points.map((p) => p.blocked)} footnote={RANGES[range].label.toLowerCase()} />
          <KpiCard label="Would-be blocks" value={sum("observed")} icon={Eye} tone="observed" spark={points.map((p) => p.observed)} footnote={RANGES[range].label.toLowerCase()} />
          <KpiCard label="MCP calls" value={sum("mcp")} icon={Plug} tone="mcp" spark={points.map((p) => p.mcp)} footnote={RANGES[range].label.toLowerCase()} />
          <KpiCard label="Secret misuse" value={misuse} icon={KeyRound} tone={misuse ? "critical" : undefined} footnote={RANGES[range].label.toLowerCase()} />
        </div>

        {findings.length > 0 && (
          <Panel title="Why this device is not compliant" className="[&_.bg-panel]:border-status-critical/30">
            <ul className="grid gap-1.5">
              {findings.map((f) => (
                <li key={f} className="flex items-start gap-2 text-[12.5px]"><StatusPill status="critical" label="Finding" className="shrink-0" /> {f}</li>
              ))}
            </ul>
          </Panel>
        )}

        <div className="grid gap-3 xl:grid-cols-[minmax(0,1fr)_380px]">
          <div className="grid content-start gap-3">
            <Panel title="Gate decisions" description={`This device, ${RANGES[range].label.toLowerCase()}`}>
              <TimelineChart data={points} bucketMs={RANGES[range].bucketMs} height={220} />
            </Panel>
            <div className="grid gap-3 lg:grid-cols-2">
              <Panel title="Posture" description="From the latest rv report">
                {report ? (
                  <dl>
                    <Row label="rv">{report.rv.version} on {report.rv.platform}</Row>
                    <Row label="Org policy">
                      {report.managed.state === "active"
                        ? <>{report.managed.organization ?? "Organization"} · serial <span className="font-mono">{report.managed.serial}</span> · {report.managed.signed ? "signed" : "unsigned"}</>
                        : report.managed.state === "invalid" ? <StatusPill status="critical" label={report.managed.reason ?? "invalid"} /> : "None installed"}
                    </Row>
                    {report.managed.restrictions?.length ? <Row label="Restrictions"><span className="font-mono text-[11.5px]">{report.managed.restrictions.join(", ")}</span></Row> : null}
                    <Row label="MCP gateway">
                      {report.mcp.ok ? <StatusPill status="good" label={`${report.mcp.servers} servers behind rv`} /> : <StatusPill status="critical" label="Servers bypass the gateway" />}
                    </Row>
                    {report.mcp.failing.map((f) => (
                      <Row key={`${f.host}-${f.name}`} label="  bypass"><span className="font-mono text-[11.5px]">{f.name}</span> in {hostLabel(f.host)} ({f.status}) · <span className="font-mono text-[11px] text-muted-foreground">{f.config}</span></Row>
                    ))}
                    {report.mcp.plaintextCredentials > 0 && <Row label="Plaintext creds"><StatusPill status="warning" label={`${report.mcp.plaintextCredentials} in host configs`} /></Row>}
                    <Row label="Sandbox">{report.sandbox.mcpSandbox ? "MCP sandbox available" : "No MCP sandbox"}{report.sandbox.peerTrustInstalled ? " · peer trust installed" : ""}</Row>
                    <Row label="Local chain">{report.audit.chainIntact === false ? <StatusPill status="critical" label="Broken" /> : <span className="font-mono text-[11.5px]">{shortHash(report.audit.chainHead, 16)}</span>}</Row>
                  </dl>
                ) : (
                  <EmptyState title="No report from this device">Schedule <code className="font-mono">rv report --json</code> from your MDM to see its posture.</EmptyState>
                )}
              </Panel>
              <Panel title="Secrets" description="Definitions on this device (names only)">
                {report?.secrets.items.length ? (
                  <dl>
                    {report.secrets.items.map((s) => (
                      <Row key={s.name} label={s.name}>
                        <span className="text-muted-foreground">{s.source} → {s.delivery}</span>
                        {s.policyViolation && <div className="mt-1"><StatusPill status="critical" label={s.policyViolation} /></div>}
                      </Row>
                    ))}
                  </dl>
                ) : <EmptyState title="No secrets reported" />}
                {report && (
                  <>
                    <h3 className="label-caps mt-4 mb-1">Config files</h3>
                    <dl>
                      {report.config.map((c) => (
                        <Row key={c.file} label={c.file}>{c.present ? <span className="font-mono text-[11px] text-muted-foreground">{shortHash(c.sha256 ?? null, 16)}</span> : <span className="text-muted-foreground">absent</span>}</Row>
                      ))}
                    </dl>
                  </>
                )}
              </Panel>
            </div>
            {breaks.length > 0 && (
              <Panel title="Chain breaks" description="Forwarded events whose prev did not match the head before them">
                <dl>
                  {breaks.map((b) => (
                    <Row key={b.seq} label={fmtTime(b.time)}>
                      <span className="font-mono text-[11.5px]">expected {shortHash(b.expected, 12)} · got {shortHash(b.got, 12)}</span>
                    </Row>
                  ))}
                </dl>
              </Panel>
            )}
          </div>
          <Panel title="Recent activity" description="This device, streaming">
            <LiveFeed initial={recent} query={`&device=${encodeURIComponent(device.id)}`} />
          </Panel>
        </div>
      </Stagger>
    </>
  );
}
