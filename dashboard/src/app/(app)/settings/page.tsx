import { headers } from "next/headers";
import { BASE_PATH } from "@/lib/base-path";
import { Sparkles } from "lucide-react";
import { PageHeader } from "@/components/console/page-header";
import { Panel } from "@/components/console/panel";
import { CodeBlock } from "@/components/console/code-block";
import { RemoveUserButton, RevokeButton, TokenCreator, TokenStatus, UserCreator } from "@/components/console/settings-forms";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Stagger } from "@/components/motion/primitives";
import { listUsers, requireUser } from "@/lib/server/auth";
import { listTokens } from "@/lib/server/tokens";
import { consoleLog } from "@/lib/server/queries";
import { config } from "@/lib/server/config";
import { redirectUri, ssoSettings } from "@/lib/server/sso";
import { StatusPill } from "@/components/console/badges";
import { fmtAgo, fmtTime } from "@/lib/format";

export const metadata = { title: "Settings" };

export default async function SettingsPage({ searchParams }: { searchParams: Promise<{ welcome?: string }> }) {
  const user = await requireUser();
  const isAdmin = user.role === "admin";
  const { welcome } = await searchParams;
  const h = await headers();
  const origin = config.publicUrl ?? `${h.get("x-forwarded-proto") ?? "http"}://${h.get("x-forwarded-host") ?? h.get("host") ?? "localhost:3000"}${BASE_PATH}`;
  const tokens = listTokens();
  const users = isAdmin ? listUsers() : [];
  const log = isAdmin ? consoleLog(30) : [];
  const ingest = `${origin}/api/v1/ingest`;

  const machine = `# 1. Store the ingest token in rv's secret store (never in a plist or crontab)
rv secrets set RV_CONSOLE_TOKEN --environment

# 2. Send history once, then every 5 minutes (macOS LaunchAgent)
rv audit forward --to ${ingest} \\
  --header 'Authorization=Bearer \${secret:RV_CONSOLE_TOKEN}'
rv audit forward --to ${ingest} \\
  --header 'Authorization=Bearer \${secret:RV_CONSOLE_TOKEN}' --install`;

  const orgPolicy = `{
  "organization": "Your Org",
  "serial": 43,
  "audit": {
    "forward": {
      "url": "${ingest}",
      "headers": { "Authorization": "Bearer \${secret:RV_CONSOLE_TOKEN}" }
    }
  }
}`;

  const mdm = `#!/bin/sh
# Run from your MDM every hour as the signed-in user.
rv report --json | curl -fsS -X POST \\
  -H "Authorization: Bearer $RV_CONSOLE_TOKEN" \\
  -H "Content-Type: application/json" \\
  --data-binary @- ${origin}/api/v1/reports`;

  const backfill = `# Import an export from a machine (JSON Lines, rv format)
rv audit export --since 30d | curl -fsS -X POST \\
  -H "Authorization: Bearer $RV_CONSOLE_TOKEN" \\
  -H "Content-Type: application/x-ndjson" \\
  -H "X-RV-Device: $(hostname)" \\
  --data-binary @- ${ingest}`;

  return (
    <>
      <PageHeader title="Settings" description="Connect machines, manage ingest tokens and who can see this console." />
      <Stagger className="grid gap-3">
        {welcome && (
          <Panel>
            <div className="flex items-start gap-3">
              <div className="grid size-9 shrink-0 place-items-center rounded-lg bg-brand/15 ring-1 ring-brand/30"><Sparkles className="size-4 text-brand" /></div>
              <div>
                <p className="text-sm font-medium">Welcome to rv Console</p>
                <p className="mt-0.5 text-[12.5px] text-muted-foreground">Create an ingest token below, then point one machine at the console. Events show up on the Overview within seconds of the first forward.</p>
              </div>
            </div>
          </Panel>
        )}
        <Panel title="Connect machines" description={<>Machines push to the console with <code className="font-mono">rv audit forward</code> (OCSF by default; the console also takes <code className="font-mono">--format rv</code>). It answers 2xx only once a batch is stored, so rv&apos;s cursor never skips events.</>}>
          <Tabs defaultValue="machine">
            <TabsList className="mb-3">
              <TabsTrigger value="machine">One machine</TabsTrigger>
              <TabsTrigger value="org">Whole fleet (org policy)</TabsTrigger>
              <TabsTrigger value="mdm">Posture (MDM)</TabsTrigger>
              <TabsTrigger value="backfill">Backfill</TabsTrigger>
            </TabsList>
            <TabsContent value="machine" className="grid gap-2">
              <CodeBlock code={machine} />
              <p className="text-[11.5px] text-muted-foreground">On Linux, <code className="font-mono">--install</code> prints the crontab line to add. Headers in a scheduled command must use <code className="font-mono">{"${secret:NAME}"}</code>; rv refuses plaintext ones.</p>
            </TabsContent>
            <TabsContent value="org" className="grid gap-2">
              <CodeBlock code={orgPolicy} label="managed policy (excerpt)" />
              <p className="text-[11.5px] text-muted-foreground">With <code className="font-mono">audit.forward</code> in the signed organization policy, <code className="font-mono">rv audit forward</code> needs no <code className="font-mono">--to</code>: every machine sends here. Each OCSF event names its host, so one token can serve the fleet.</p>
            </TabsContent>
            <TabsContent value="mdm" className="grid gap-2">
              <CodeBlock code={mdm} />
              <p className="text-[11.5px] text-muted-foreground"><code className="font-mono">rv report</code> never reads secret values or touches the network; it feeds the Fleet page&apos;s compliance, versions, org-policy serials and the Integrity page&apos;s head comparison.</p>
            </TabsContent>
            <TabsContent value="backfill" className="grid gap-2">
              <CodeBlock code={backfill} />
            </TabsContent>
          </Tabs>
        </Panel>

        <Panel title="Ingest tokens" description="Bearer tokens for /api/v1/ingest and /api/v1/reports. Only a hash is stored.">
          <TokenCreator canEdit={isAdmin} />
          <div className="mt-4 overflow-x-auto">
            <table className="w-full min-w-[620px] text-left text-[12.5px]">
              <thead>
                <tr className="border-y text-[11px] text-muted-foreground">
                  <th className="py-2 pr-2 font-medium">Name</th>
                  <th className="px-2 py-2 font-medium">Token</th>
                  <th className="px-2 py-2 font-medium">Status</th>
                  <th className="px-2 py-2 font-medium">Created</th>
                  <th className="py-2 pl-2 text-right font-medium" />
                </tr>
              </thead>
              <tbody>
                {tokens.map((t) => (
                  <tr key={t.id} className="border-b border-border/60">
                    <td className="py-2 pr-2">{t.name}</td>
                    <td className="px-2 py-2 font-mono text-[11.5px] text-muted-foreground">{t.prefix}…</td>
                    <td className="px-2 py-2"><TokenStatus revokedAt={t.revokedAt} lastUsedAt={t.lastUsedAt} /></td>
                    <td className="px-2 py-2 text-[11.5px] text-muted-foreground">{fmtAgo(t.createdAt)}{t.createdBy ? ` by ${t.createdBy}` : ""}</td>
                    <td className="py-2 pl-2 text-right">{isAdmin && !t.revokedAt && <RevokeButton id={t.id} name={t.name} />}</td>
                  </tr>
                ))}
                {tokens.length === 0 && <tr><td colSpan={5} className="py-6 text-center text-xs text-muted-foreground">No tokens yet.</td></tr>}
              </tbody>
            </table>
          </div>
        </Panel>

        <Panel title="Single sign-on" description="OpenID Connect: Okta, Microsoft Entra ID, Google Workspace, Auth0, OneLogin, Ping, Keycloak.">
          {ssoSettings ? (
            <div className="grid gap-4 lg:grid-cols-2">
              <dl className="grid gap-0 text-[12.5px]">
                {[
                  ["Status", <StatusPill key="s" status="good" label={`${ssoSettings.name} enabled`} />],
                  ["Issuer", <span key="i" className="font-mono text-[11.5px] break-all">{ssoSettings.issuer}</span>],
                  ["Client ID", <span key="c" className="font-mono text-[11.5px] break-all">{ssoSettings.clientId}</span>],
                  ["Password sign-in", ssoSettings.enforce ? "Local admins only (break-glass)" : "Allowed alongside SSO"],
                  ["New users", ssoSettings.policy.autoProvision ? `Created on first sign-in as ${ssoSettings.policy.defaultRole}` : "Must be added by an admin first"],
                  ["Email domains", ssoSettings.policy.allowedDomains.join(", ") || "Any"],
                  ["Admin groups", ssoSettings.policy.adminGroups.join(", ") || "None (roles set in the console)"],
                  ["Viewer groups", ssoSettings.policy.viewerGroups.join(", ") || (ssoSettings.policy.adminGroups.length ? "Everyone else" : "None (roles set in the console)")],
                ].map(([k, v]) => (
                  <div key={String(k)} className="grid grid-cols-[132px_minmax(0,1fr)] gap-3 border-b border-dashed py-2 last:border-0">
                    <dt className="text-muted-foreground">{k}</dt><dd className="min-w-0">{v}</dd>
                  </div>
                ))}
              </dl>
              <div className="grid content-start gap-2">
                <CodeBlock code={redirectUri(origin)} label="redirect URI to register with your IdP" />
                <p className="text-[11.5px] text-muted-foreground">Register a web application using the authorization code flow (the console sends PKCE). With group mapping, roles follow the IdP on every sign-in. These settings come from <code className="font-mono">RV_CONSOLE_OIDC_*</code> environment variables.</p>
              </div>
            </div>
          ) : (
            <div className="grid gap-2">
              <p className="text-[12.5px] text-muted-foreground">Not configured. Set these on the console and restart it; the sign-in page then offers your provider. The redirect URI to register is <code className="font-mono">{redirectUri(origin)}</code>.</p>
              <CodeBlock label="environment" code={`RV_CONSOLE_PUBLIC_URL=${origin}
RV_CONSOLE_OIDC_ISSUER=https://your-org.okta.com
RV_CONSOLE_OIDC_CLIENT_ID=<client id>
RV_CONSOLE_OIDC_CLIENT_SECRET=<client secret>
RV_CONSOLE_OIDC_NAME=Okta
RV_CONSOLE_OIDC_ALLOWED_DOMAINS=your-org.com
RV_CONSOLE_OIDC_ADMIN_GROUPS=rv-admins        # optional group-to-role mapping
RV_CONSOLE_OIDC_VIEWER_GROUPS=engineering      # optional; anyone in neither is refused
RV_CONSOLE_SSO_ENFORCE=1                       # optional; passwords for local admins only`} />
            </div>
          )}
        </Panel>

        {isAdmin && (
          <div className="grid gap-3 xl:grid-cols-2">
            <Panel title="Users" description="Admins manage tokens and users; viewers see everything else.">
              <UserCreator />
              <ul className="mt-3 divide-y divide-border/60">
                {users.map((u) => (
                  <li key={u.id} className="flex items-center justify-between gap-3 py-2 text-[12.5px]">
                    <span className="min-w-0">
                      <span className="block truncate">{u.name} <span className="text-muted-foreground">· {u.email}</span></span>
                      <span className="text-[11px] text-muted-foreground">{u.role} · {u.provider === "oidc" ? (ssoSettings?.name ?? "SSO") : "password"} · last sign-in {fmtAgo(u.lastLoginAt)}</span>
                    </span>
                    {u.id !== user.id && <RemoveUserButton id={u.id} email={u.email} />}
                  </li>
                ))}
              </ul>
            </Panel>
            <Panel title="Console audit log" description={`Sign-ins, tokens and users. Events are kept ${config.retentionDays} days.`}>
              <ul className="divide-y divide-border/60">
                {log.map((l, i) => (
                  <li key={i} className="grid grid-cols-[132px_minmax(0,1fr)] gap-2 py-1.5 text-[12px]">
                    <span className="font-mono text-[11px] text-muted-foreground">{fmtTime(l.time)}</span>
                    <span className="truncate"><span className="font-mono text-[11.5px]">{l.action}</span> {l.target && <span className="text-muted-foreground">{l.target}</span>} {l.actor && <span className="text-muted-foreground">· {l.actor}</span>}</span>
                  </li>
                ))}
              </ul>
            </Panel>
          </div>
        )}
      </Stagger>
    </>
  );
}
