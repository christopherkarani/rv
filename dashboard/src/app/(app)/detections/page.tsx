import { Brain, Eye, FileKey, ListChecks, ShieldX } from "lucide-react";
import { PageHeader } from "@/components/console/page-header";
import { Panel } from "@/components/console/panel";
import { KpiCard } from "@/components/console/kpi";
import { BarList } from "@/components/console/bar-list";
import { RulesTable } from "@/components/console/rules-table";
import { Stagger } from "@/components/motion/primitives";
import { byPackCategory, byReasonCode, topRules } from "@/lib/server/queries";
import { parseRange, RANGES } from "@/lib/range";

export const metadata = { title: "Detections" };

const CODE_LABEL: Record<string, string> = {
  "rv.command.denied-rule": "Pack rule", "rv.command.denied-secret-path": "Secret path", "rv.command.denied-judge": "Laya judge",
  "rv.command.denied-indeterminate": "Could not evaluate",
  "rv.command.observed-deny": "Observed: would deny", "rv.command.observed-ask": "Observed: would ask",
};

export default async function DetectionsPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const range = parseRange((await searchParams).range);
  const rq = range === "7d" ? "" : `&range=${range}`;
  const rules = topRules(range, 200);
  const packs = byPackCategory(range);
  const codes = byReasonCode(range, 10);
  const sum = (f: (r: (typeof rules)[number]) => number) => rules.reduce((n, r) => n + f(r), 0);
  const judge = sum((r) => (r.pack === "core.judge" ? r.blocked + r.observed : 0));
  const secretPaths = sum((r) => (r.pack === "core.secrets" ? r.blocked : 0));

  return (
    <>
      <PageHeader
        eyebrow={RANGES[range].label}
        title="Detections"
        description="Which of rv's 95 rule packs, secret-path rules and on-device judge verdicts fire across the fleet. Would-be blocks come from hosts in observe mode: tune there before you enforce."
      />
      <Stagger className="grid gap-3">
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-5">
          <KpiCard label="Rules fired" value={rules.length} icon={ListChecks} footnote="distinct rule ids" />
          <KpiCard label="Blocked commands" value={sum((r) => r.blocked)} icon={ShieldX} tone="blocked" footnote="hook denies" />
          <KpiCard label="Would-be blocks" value={sum((r) => r.observed)} icon={Eye} tone="observed" footnote="observe mode" />
          <KpiCard label="Secret-path blocks" value={secretPaths} icon={FileKey} footnote=".env, keys, cloud creds" />
          <KpiCard label="Judge verdicts" value={judge} icon={Brain} footnote="Laya, on-device" />
        </div>
        <div className="grid gap-3 xl:grid-cols-[minmax(0,1fr)_340px]">
          <Panel title="Rules" description="Sorted by blocks. Click a rule to see its events." flush bodyClassName="pb-2">
            <RulesTable rules={rules} rangeQuery={rq} />
          </Panel>
          <div className="grid content-start gap-3">
            <Panel title="By pack" description="Blocked + would-be, per rule pack">
              <BarList items={packs.slice(0, 10).map((p) => ({
                key: p.pack, label: p.name, sublabel: <span className="font-mono">{p.pack}</span>,
                segments: [{ tone: "blocked", value: p.count, label: "Detections" }],
              }))} />
            </Panel>
            <Panel title="Reason codes" description="Stable OCSF status codes for SIEM rules">
              <BarList items={codes.map((c) => ({
                key: c.code, label: CODE_LABEL[c.code] ?? c.code.replace(/^rv\./, ""), sublabel: <span className="font-mono">{c.code}</span>,
                segments: [{ tone: c.code.includes("observed") ? "observed" : c.code.startsWith("rv.mcp") ? "mcp" : "blocked", value: c.count, label: "Events" }],
              }))} />
            </Panel>
          </div>
        </div>
      </Stagger>
    </>
  );
}
