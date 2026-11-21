/** Alert payloads for Slack and generic webhooks. Pure, so tests cover them. */
import type { RuleId, Severity } from "./catalog";

export interface Alert {
  id: string;
  rule: RuleId | "test";
  severity: Severity;
  title: string;
  summary: string;
  occurredAt: number;
  deviceId: string | null;
  hostname: string | null;
  fields: { label: string; value: string }[];
  /** Console path to open, e.g. `/fleet/eng-mbp-0226`. */
  path: string;
}

const SLACK_MARK: Record<Severity, string> = { critical: ":red_circle:", high: ":large_orange_circle:", medium: ":large_yellow_circle:" };

/** Slack's mrkdwn treats &, < and > as control characters. */
const slackEscape = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

export function slackPayload(alert: Alert, consoleUrl: string | null) {
  const link = consoleUrl ? `${consoleUrl}${alert.path}` : null;
  const blocks: Record<string, unknown>[] = [
    { type: "header", text: { type: "plain_text", text: `${alert.title}`.slice(0, 150), emoji: true } },
    {
      type: "section",
      text: { type: "mrkdwn", text: `${SLACK_MARK[alert.severity]} *${alert.severity.toUpperCase()}*  ${slackEscape(alert.summary)}`.slice(0, 3000) },
    },
  ];
  if (alert.fields.length) {
    blocks.push({
      type: "section",
      fields: alert.fields.slice(0, 10).map((f) => ({ type: "mrkdwn", text: `*${slackEscape(f.label)}*\n${slackEscape(f.value)}`.slice(0, 2000) })),
    });
  }
  blocks.push({
    type: "context",
    elements: [{ type: "mrkdwn", text: `rv Console · <!date^${Math.floor(alert.occurredAt / 1000)}^{date_short_pretty} {time}|${new Date(alert.occurredAt).toISOString()}>` }],
  });
  if (link) {
    blocks.push({ type: "actions", elements: [{ type: "button", text: { type: "plain_text", text: "Open in rv Console" }, url: link }] });
  }
  return { text: `[${alert.severity}] ${alert.title}: ${alert.summary}`.slice(0, 3000), blocks };
}

export function webhookPayload(alert: Alert, consoleUrl: string | null) {
  return {
    schema: "rv.console.alert.v1",
    id: alert.id,
    rule: alert.rule,
    severity: alert.severity,
    title: alert.title,
    summary: alert.summary,
    occurredAt: new Date(alert.occurredAt).toISOString(),
    device: alert.deviceId ? { id: alert.deviceId, hostname: alert.hostname } : null,
    fields: Object.fromEntries(alert.fields.map((f) => [f.label, f.value])),
    url: consoleUrl ? `${consoleUrl}${alert.path}` : null,
  };
}

const SLACK_HOOK = /^https:\/\/hooks\.slack\.com\/(services|workflows|triggers)\/[A-Za-z0-9/_-]+$/;

/** Why a destination URL is refused, or null when it is fine. */
export function destinationProblem(kind: "slack" | "webhook", url: string, allowHttp = false): string | null {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return "Enter a full URL.";
  }
  if (kind === "slack") return SLACK_HOOK.test(url) ? null : "Use a Slack incoming webhook URL (https://hooks.slack.com/services/…).";
  if (parsed.username || parsed.password) return "Put credentials in the signing secret, not in the URL.";
  if (parsed.protocol === "https:") return null;
  if (parsed.protocol === "http:" && allowHttp) return null;
  return "Webhooks must use https.";
}

/** Shown in the UI instead of the URL, which is itself a credential for Slack. */
export function urlHint(url: string): string {
  try {
    const u = new URL(url);
    const tail = u.pathname.length > 6 ? `…${u.pathname.slice(-4)}` : u.pathname;
    return `${u.host}${tail}`;
  } catch {
    return "invalid URL";
  }
}
