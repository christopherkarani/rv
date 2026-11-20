"use client";

import { useActionState, useState, useTransition } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Hash, Loader2, Plus, Send, Trash2, Webhook } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import {
  createDestinationAction, deleteDestinationAction, testDestinationAction, toggleDestinationAction, updateRuleAction,
} from "@/app/actions";
import type { RuleDef, Severity } from "@/lib/alerts/catalog";
import { cn } from "@/lib/utils";
import { SPRING } from "@/components/motion/primitives";
import { CodeBlock } from "./code-block";
import { LocalTime } from "./local-time";
import { StatusPill } from "./badges";

const SEVERITY_LABEL: Record<Severity, string> = { critical: "Critical only", high: "High and critical", medium: "All alerts" };

export function SeverityPill({ severity }: { severity: Severity }) {
  const status = severity === "critical" ? "critical" : severity === "high" ? "warning" : "neutral";
  return <StatusPill status={status} label={severity} className="capitalize" />;
}

export function DestinationCreator() {
  const [state, action, pending] = useActionState(createDestinationAction, undefined);
  const [kind, setKind] = useState<"slack" | "webhook">((state?.values?.kind as "slack" | "webhook") ?? "slack");
  const [minSeverity, setMinSeverity] = useState(state?.values?.minSeverity ?? "high");
  return (
    <div>
      <form action={action} className="grid gap-2.5">
        <div role="radiogroup" aria-label="Destination type" className="flex h-8 w-fit items-center rounded-md border bg-faint p-0.5">
          {(["slack", "webhook"] as const).map((k) => (
            <button key={k} type="button" role="radio" aria-checked={kind === k} onClick={() => setKind(k)}
              className={cn("relative flex h-full items-center gap-1.5 rounded px-3 text-[12.5px]", kind === k ? "text-foreground" : "text-muted-foreground hover:text-foreground")}>
              {kind === k && <motion.span layoutId="dest-kind" transition={SPRING} className="absolute inset-0 rounded bg-background shadow-sm ring-1 ring-border" />}
              <span className="relative flex items-center gap-1.5">{k === "slack" ? <Hash className="size-3.5" /> : <Webhook className="size-3.5" />}{k === "slack" ? "Slack" : "Webhook"}</span>
            </button>
          ))}
        </div>
        <input type="hidden" name="kind" value={kind} />
        <input type="hidden" name="minSeverity" value={minSeverity} />
        <div className="grid gap-2 sm:grid-cols-[1fr_1fr]">
          <Input name="name" defaultValue={state?.values?.name} placeholder={kind === "slack" ? "#security-alerts" : "PagerDuty bridge"} aria-label="Name" required maxLength={80} className="h-8 bg-faint text-[12.5px]" />
          <Select value={minSeverity} onValueChange={setMinSeverity}>
            <SelectTrigger size="sm" aria-label="Which alerts" className="h-8 w-full bg-faint text-[12.5px]"><SelectValue /></SelectTrigger>
            <SelectContent>
              {(Object.keys(SEVERITY_LABEL) as Severity[]).map((s) => <SelectItem key={s} value={s}>{SEVERITY_LABEL[s]}</SelectItem>)}
            </SelectContent>
          </Select>
        </div>
        <Input name="url" type="url" required aria-label="Webhook URL" autoComplete="off"
          placeholder={kind === "slack" ? "https://hooks.slack.com/services/T…/B…/…" : "https://alerts.example.com/rv-console"}
          className="h-8 bg-faint font-mono text-[12px]" />
        <div className="flex items-center gap-3">
          <Button type="submit" size="sm" disabled={pending}>{pending ? <Loader2 className="animate-spin" /> : <Plus />} Add destination</Button>
          <span className="text-[11.5px] text-muted-foreground">
            {kind === "slack" ? "Create an incoming webhook in Slack (Apps → Incoming Webhooks) for the channel." : "POSTs JSON (rv.console.alert.v1), signed with HMAC-SHA256."}
          </span>
        </div>
        {state?.error && <p className="text-xs text-status-critical">{state.error}</p>}
      </form>
      <AnimatePresence>
        {state?.signingSecret && (
          <motion.div initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: "auto" }} className="mt-3 overflow-hidden">
            <div className="grid gap-2 rounded-lg border border-brand/40 bg-brand/6 p-3">
              <p className="text-[12.5px] font-medium">Copy the signing secret now. It will not be shown again.</p>
              <CodeBlock code={state.signingSecret} label="signing secret" />
              <CodeBlock label="verify (Node.js)" code={`// header: X-RV-Console-Signature: t=<unix>,v1=<hex>
const [t, v1] = sig.split(",").map((p) => p.split("=")[1]);
const want = crypto.createHmac("sha256", SECRET).update(\`\${t}.\${rawBody}\`).digest();
const got = Buffer.from(v1 ?? "", "hex");
const ok = got.length === want.length && crypto.timingSafeEqual(got, want)
  && Math.abs(Date.now() / 1000 - Number(t)) < 300; // reject replays`} />
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

export function DestinationControls({ id, name, enabled, canEdit }: { id: string; name: string; enabled: boolean; canEdit: boolean }) {
  const [pending, start] = useTransition();
  const [testing, startTest] = useTransition();
  const [confirm, setConfirm] = useState(false);
  return (
    <div className="flex items-center gap-1.5">
      <Switch checked={enabled} disabled={!canEdit || pending} aria-label={enabled ? `Pause ${name}` : `Resume ${name}`}
        onCheckedChange={(v) => start(async () => { await toggleDestinationAction(id, v); })} />
      <Button variant="ghost" size="xs" disabled={!canEdit || testing}
        onClick={() => startTest(async () => {
          const r = await testDestinationAction(id);
          if (r.status === "sent") toast.success(`Test alert delivered to ${name}`);
          else toast.error(`${name}: ${r.error ?? "delivery failed"}`);
        })}>
        {testing ? <Loader2 className="animate-spin" /> : <Send />} Test
      </Button>
      {canEdit && (confirm ? (
        <>
          <Button variant="destructive" size="xs" disabled={pending} onClick={() => start(async () => { await deleteDestinationAction(id); toast.success(`Removed ${name}`); })}>Remove?</Button>
          <Button variant="ghost" size="xs" onClick={() => setConfirm(false)}>Cancel</Button>
        </>
      ) : (
        <Button variant="ghost" size="icon-xs" aria-label={`Remove ${name}`} onClick={() => setConfirm(true)}><Trash2 /></Button>
      ))}
    </div>
  );
}

export function RuleRow({ rule, enabled, threshold, canEdit }: { rule: RuleDef; enabled: boolean; threshold: number | null; canEdit: boolean }) {
  const [pending, start] = useTransition();
  const [value, setValue] = useState(String(threshold ?? ""));
  const dirty = rule.threshold && Number(value) !== threshold;
  return (
    <div className="grid grid-cols-[auto_minmax(0,1fr)] gap-3 border-b border-border/60 py-3 last:border-0">
      <Switch className="mt-0.5" checked={enabled} disabled={!canEdit || pending} aria-label={`${rule.title} alerts`}
        onCheckedChange={(v) => start(async () => { await updateRuleAction(rule.id, { enabled: v }); })} />
      <div className="min-w-0">
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-[13px] font-medium">{rule.title}</span>
          <SeverityPill severity={rule.severity} />
        </div>
        <p className="mt-0.5 text-[12px] text-muted-foreground">{rule.description}</p>
        {rule.threshold && (
          <form className="mt-2 flex items-center gap-2 text-[12px]" onSubmit={(e) => {
            e.preventDefault();
            start(async () => { await updateRuleAction(rule.id, { threshold: Number(value) }); toast.success(`${rule.title}: ${value} ${rule.threshold!.unit}`); });
          }}>
            <label htmlFor={`th-${rule.id}`} className="text-muted-foreground">{rule.threshold.label}</label>
            <Input id={`th-${rule.id}`} type="number" min={rule.threshold.min} max={rule.threshold.max} value={value} disabled={!canEdit}
              onChange={(e) => setValue(e.target.value)} className="h-7 w-20 bg-faint font-mono text-[12px]" />
            <span className="text-muted-foreground">{rule.threshold.unit}</span>
            {dirty && canEdit && <Button type="submit" size="xs" disabled={pending}>Save</Button>}
          </form>
        )}
      </div>
    </div>
  );
}

export function DeliveryStatus({ status, lastDeliveryAt }: { status: string | null; lastDeliveryAt: number | null }) {
  if (!lastDeliveryAt) return <StatusPill status="pending" label="Nothing sent yet" />;
  if (status === "sent") return <StatusPill status="good" label={<>Delivered <LocalTime ms={lastDeliveryAt} /></>} />;
  return <StatusPill status="critical" label={<>{status} · <LocalTime ms={lastDeliveryAt} /></>} />;
}
