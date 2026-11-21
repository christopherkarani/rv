import Link from "next/link";
import { Bell, BellRing, Hash, Send, TriangleAlert, Webhook } from "lucide-react";
import { PageHeader } from "@/components/console/page-header";
import { EmptyState, Panel } from "@/components/console/panel";
import { KpiCard } from "@/components/console/kpi";
import { LocalTime } from "@/components/console/local-time";
import { DeliveryStatus, DestinationControls, DestinationCreator, RuleRow, SeverityPill } from "@/components/console/alerts-ui";
import { Stagger } from "@/components/motion/primitives";
import { requireUser } from "@/lib/server/auth";
import { alertStats, listDestinations, recentAlerts, ruleStates } from "@/lib/server/alerts";
import { RULES } from "@/lib/alerts/catalog";

export const metadata = { title: "Alerts" };

const MIN_LABEL = { critical: "critical only", high: "high and critical", medium: "all alerts" } as const;

export default async function AlertsPage() {
  const user = await requireUser();
  const canEdit = user.role === "admin";
  const destinations = listDestinations();
  const states = ruleStates();
  const stats = alertStats();
  const recent = recentAlerts(30);
  return (
    <>
      <PageHeader
        title="Alerts"
        description="Send the events that need a person to Slack or any webhook (PagerDuty, Opsgenie, a SIEM, your own bot). Each rule fires once per machine and cooldown, never for old events a backfill brings in, and chain breaks always fire."
      />
      <Stagger className="grid gap-3">
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <KpiCard label="Alerts, 7 days" value={stats.alerts} icon={Bell} footnote="raised by rules" />
          <KpiCard label="Critical" value={stats.critical} icon={BellRing} tone={stats.critical ? "critical" : undefined} footnote="chain, secrets, forged approvals" />
          <KpiCard label="Delivered" value={stats.sent} icon={Send} tone="good" footnote="to destinations" />
          <KpiCard label="Failed deliveries" value={stats.failed} icon={TriangleAlert} tone={stats.failed ? "warning" : undefined} footnote="after retries" />
        </div>
        <div className="grid gap-3 xl:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)]">
          <Panel title="Destinations" description="Where alerts go. URLs are encrypted at rest and never shown again.">
            {destinations.length === 0 ? (
              <EmptyState icon={Webhook} title="No destinations yet">Add a Slack channel or a webhook below. Alerts are still recorded here meanwhile.</EmptyState>
            ) : (
              <ul className="divide-y divide-border/60">
                {destinations.map((d) => (
                  <li key={d.id} className="flex flex-wrap items-center justify-between gap-3 py-2.5">
                    <div className="flex min-w-0 items-center gap-2.5">
                      <span className="grid size-8 shrink-0 place-items-center rounded-md border bg-faint">
                        {d.kind === "slack" ? <Hash className="size-4" /> : <Webhook className="size-4" />}
                      </span>
                      <span className="min-w-0">
                        <span className="block truncate text-[13px] font-medium">{d.name}</span>
                        <span className="block truncate font-mono text-[11px] text-muted-foreground">{d.urlHint} · {MIN_LABEL[d.minSeverity]}{d.hasSecret ? " · signed" : ""}</span>
                      </span>
                    </div>
                    <div className="flex flex-wrap items-center gap-2">
                      <DeliveryStatus status={d.lastStatus} lastDeliveryAt={d.lastDeliveryAt} />
                      <DestinationControls id={d.id} name={d.name} enabled={d.enabled} canEdit={canEdit} />
                    </div>
                  </li>
                ))}
              </ul>
            )}
            {canEdit ? (
              <div className="mt-4 border-t pt-4"><DestinationCreator /></div>
            ) : (
              <p className="mt-3 text-xs text-muted-foreground">Admins add and change destinations.</p>
            )}
          </Panel>
          <Panel title="Rules" description="What raises an alert. Severity decides which destinations get it.">
            {RULES.map((rule) => {
              const s = states.find((x) => x.id === rule.id)!;
              return <RuleRow key={rule.id} rule={rule} enabled={s.enabled} threshold={s.threshold} canEdit={canEdit} />;
            })}
          </Panel>
        </div>
        <Panel title="Recent alerts" description="Newest first, with where each one was delivered">
          {recent.length === 0 ? (
            <EmptyState icon={Bell} title="No alerts yet">When a rule fires, it shows up here and in your destinations.</EmptyState>
          ) : (
            <ul className="divide-y divide-border/60">
              {recent.map((a) => (
                <li key={a.id} className="grid gap-1 py-2.5 sm:grid-cols-[minmax(0,1fr)_auto] sm:gap-4">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <SeverityPill severity={a.severity} />
                      <span className="text-[13px] font-medium">{a.title}</span>
                    </div>
                    <p className="mt-0.5 text-[12px] text-muted-foreground">{a.summary}</p>
                    <div className="mt-1 flex flex-wrap gap-1.5">
                      {a.deliveries.length === 0 && <span className="text-[11px] text-muted-foreground">Not routed: no destination takes this severity.</span>}
                      {a.deliveries.map((d, i) => (
                        <span key={i} title={d.error ?? undefined} className={`rounded px-1.5 font-mono text-[10.5px] ring-1 ring-inset ${d.status === "sent" ? "bg-status-good/10 ring-status-good/30" : "bg-status-critical/10 ring-status-critical/35"}`}>
                          {d.status === "sent" ? "✓" : "✕"} {d.destination}
                        </span>
                      ))}
                    </div>
                  </div>
                  <div className="text-[11.5px] whitespace-nowrap text-muted-foreground sm:text-right">
                    <LocalTime ms={a.createdAt} />
                    {a.deviceId && <div><Link href={`/fleet/${encodeURIComponent(a.deviceId)}`} className="font-mono hover:text-foreground hover:underline">{a.deviceId}</Link></div>}
                  </div>
                </li>
              ))}
            </ul>
          )}
        </Panel>
      </Stagger>
    </>
  );
}
