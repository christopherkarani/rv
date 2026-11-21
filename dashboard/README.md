# rv Console

The fleet dashboard for rv. Machines push their audit trail to it with
`rv audit forward`, and their posture with `rv report`. The console shows,
across every machine:

- what rv blocked
- what observe mode would have blocked
- who overrode a block or loosened the gate
- MCP tool calls and secret use
- whether each machine's audit log is still intact

| Page | What it answers |
| --- | --- |
| **Overview** | Blocks, would-be blocks, overrides, MCP calls, secret misuse and active devices, each compared with the previous period. Also: a decision timeline, top rules, a per-agent breakdown, fleet compliance and a live feed |
| **Activity** | Every `rv.audit.v1` event. Search and filter by kind, decision, agent or device. Live tail, an event inspector (detail and hash chain), CSV and JSON Lines export |
| **Detections** | Rules ranked by blocks, with pack, severity and description (from rv's own pack files), plus would-be blocks, overrides, agents, trend, reason codes and per-pack totals |
| **Fleet** | Every machine: rv version, org-policy serial, compliance (rv's own rule), chain state, blocks and staleness. Each machine has its own page with its report findings |
| **MCP gateway** | Per tool: calls, policy, denials, approvals, errors, average and max latency. Plus approvals and changed tool definitions |
| **Secrets** | Use, refusals and misuse per secret name, with fingerprints. rv never forwards values |
| **Policy & changes** | Every `config.changed` / `policy.*` record: direction (loosening or tightening) and who authorized it. Loosening with no owner check is called out. Also: org-policy rollout by serial |
| **Integrity** | Off-machine hash-chain verification per device: intact, broken, behind (the report names a head the console never got) or no chain yet |
| **Alerts** | Slack and signed-webhook destinations, rules with severity and thresholds, a log of what was sent where |
| **Settings** | Onboarding snippets, ingest tokens, single sign-on status, users (admin or viewer), the console's own audit log |

The UI follows an editor's layout: page tabs, a collapsible explorer, a ⌘K
command palette, `G` then a letter to jump between pages, `/` to search, and a
status bar showing ingest, fleet and chain health. It opens in the dark
theme; the sun/moon button in the title bar switches to light, and the
account menu also offers the system setting. Motion is built with `motion` and turns off when the OS asks for
reduced motion. Charts use a palette checked for color-vision deficiency.
Status is always shown with an icon and a label, never color alone.

## Run it

```sh
cd dashboard
npm ci
RV_CONSOLE_DEMO=1 npm run dev          # synthetic 22-machine fleet that streams live events
```

On first start it asks you to create an admin. Alternatively, set
`RV_CONSOLE_ADMIN_EMAIL` and `RV_CONSOLE_ADMIN_PASSWORD`.

Production (Docker):

```sh
docker build -t rv-console dashboard/
docker run -p 3000:3000 -v rv-console:/data \
  -e RV_CONSOLE_SECRET="$(openssl rand -base64 48)" \
  -e RV_CONSOLE_PUBLIC_URL=https://rv-console.example.com rv-console
```

The same setup is in `docker-compose.yml`. Put TLS in front of the console:
rv forwards over https only, except to localhost.

| Variable | Meaning |
| --- | --- |
| `RV_CONSOLE_SECRET` | Session HMAC key, 32+ characters. **Required in production** |
| `RV_CONSOLE_DATA_DIR` | SQLite directory (`/data` in the image). Back it up |
| `RV_CONSOLE_RETENTION_DAYS` | Days of events to keep (default 90) |
| `RV_CONSOLE_PUBLIC_URL` | Base URL used in onboarding snippets, including any base path (`https://rykanv.com/console`) |
| `RV_CONSOLE_ADMIN_EMAIL`, `RV_CONSOLE_ADMIN_PASSWORD` | Seed the first admin |
| `RV_CONSOLE_DEMO` | `1` seeds and streams a demo fleet (never in production) |
| `RV_CONSOLE_INSECURE_COOKIES` | `1` allows session cookies over plain http (lab only) |
| `RV_CONSOLE_OIDC_*`, `RV_CONSOLE_SSO_ENFORCE` | Single sign-on; see below |
| `RV_CONSOLE_ALLOW_HTTP_WEBHOOKS` | `1` allows alert webhooks over plain http (lab only) |
| `RV_CONSOLE_THEME` | `rykan` matches rykanv.com: the site's white and zinc palette, the Rykan V logo, a site-style header with tab navigation, light by default |
| `RV_CONSOLE_BASE_PATH` | Serve under a path, such as `/console`, so a site can proxy `/console/*` to the console. **Build time**: set it for `npm run build` / `docker build` |

## Connect machines

Create an ingest token under **Settings → Ingest tokens**. Then use one of
these:

```sh
# One machine (store the token in rv's secret store, then schedule)
rv secrets set RV_CONSOLE_TOKEN --environment
rv audit forward --to https://console.example.com/api/v1/ingest \
  --header 'Authorization=Bearer ${secret:RV_CONSOLE_TOKEN}' --install
```

```json
// Whole fleet: the signed organization policy
{ "audit": { "forward": {
    "url": "https://console.example.com/api/v1/ingest",
    "headers": { "Authorization": "Bearer ${secret:RV_CONSOLE_TOKEN}" } } } }
```

```sh
# Posture, from your MDM
rv report --json | curl -fsS -X POST -H "Authorization: Bearer $RV_CONSOLE_TOKEN" \
  -H "Content-Type: application/json" --data-binary @- https://console.example.com/api/v1/reports
```

### API

| Endpoint | Auth | Body |
| --- | --- | --- |
| `POST /api/v1/ingest` | Bearer ingest token | A JSON array of OCSF events (`rv audit forward` default) or of `rv.audit.v1` events (`--format rv`). JSON Lines also works (`Content-Type: application/x-ndjson`). `X-RV-Device` names the host for rv-format events, which carry no host name. Up to 5,000 events or 16 MiB per request |
| `POST /api/v1/reports` | Bearer ingest token | One `rv report --json` document. The answer includes `compliant` and `findings` |
| `GET /api/v1/events` | Session | Search and paging (`q`, `kind`, `decision`, `device`, `host`, `range`, `before=time:seq`, `after=seq`) |
| `GET /api/v1/export` | Session | Same filters plus `format=csv\|jsonl`, up to 50,000 rows |
| `GET /api/health` | None | `{"status":"ok"}` when the database answers |

Ingest returns 2xx only after the batch is committed. rv moves its forward
cursor only on a 2xx, so if the console is down rv sends the batch again
later; events are not lost. Resent events are dropped by uid (OCSF
`metadata.uid`).

## Single sign-on

The console signs people in with OpenID Connect. That covers Okta,
Microsoft Entra ID, Google Workspace, Auth0, OneLogin, Ping and Keycloak.

1. Register a web application with your identity provider. Use the
   authorization code flow and set the redirect URI to
   `https://<console>/api/auth/sso/callback`.
2. Set these variables on the console and restart it:

| Variable | Meaning |
| --- | --- |
| `RV_CONSOLE_PUBLIC_URL` | Required for SSO in production. The redirect URI is built from it, never from the request's Host header |
| `RV_CONSOLE_OIDC_ISSUER` | The issuer URL (https), e.g. `https://your-org.okta.com` or `https://login.microsoftonline.com/<tenant>/v2.0` |
| `RV_CONSOLE_OIDC_CLIENT_ID`, `RV_CONSOLE_OIDC_CLIENT_SECRET` | The application's credentials |
| `RV_CONSOLE_OIDC_NAME` | Button label, e.g. `Okta` (default `SSO`) |
| `RV_CONSOLE_OIDC_SCOPES` | Default `openid email profile`. Add `groups` if your IdP needs it to send group claims |
| `RV_CONSOLE_OIDC_ALLOWED_DOMAINS` | Comma-separated email domains allowed to sign in (default any) |
| `RV_CONSOLE_OIDC_GROUPS_CLAIM` | ID token claim with groups (default `groups`) |
| `RV_CONSOLE_OIDC_ADMIN_GROUPS` | Members become admins. With any group mapping set, roles follow the IdP on every sign-in |
| `RV_CONSOLE_OIDC_VIEWER_GROUPS` | Members become viewers. When set, people in neither list are refused |
| `RV_CONSOLE_OIDC_AUTO_PROVISION` | `0` means only people an admin already added can sign in (default `1`, create on first sign-in) |
| `RV_CONSOLE_OIDC_DEFAULT_ROLE` | Role for new users when no group mapping applies (default `viewer`) |
| `RV_CONSOLE_SSO_ENFORCE` | `1` turns off password sign-in, except for local admins at `/login?local=1` (break-glass) |

How a sign-in works:

- The flow uses PKCE, `state` and `nonce`. The ID token is checked by
  `openid-client`.
- The flow's secrets travel in an encrypted cookie that lasts 10 minutes.
- An account is matched first by its IdP subject, then by verified email.
  An email match links an existing account to the IdP.
- If the IdP explicitly says an email is unverified, sign-in is refused.
- On Entra ID, the email can come from `preferred_username` or `upn`.
- On a console with no accounts yet, the first person to sign in becomes an
  admin.
- SSO-only accounts have no password and can never sign in with one.
- Every sign-in and every refusal is recorded in the console audit log on
  the Settings page.

## Alerts

Alerts go to Slack (an incoming webhook) or to any https webhook, such as
PagerDuty, Opsgenie, a SIEM or your own bot. Add destinations on the Alerts
page. Each destination receives the alerts at or above its minimum severity.

| Rule | Severity | Fires when |
| --- | --- | --- |
| Audit chain broken | critical | A forwarded event does not follow the chain head the console holds |
| Secret misuse | critical | `secret.misuse`: a placeholder was used against its policy or from the wrong process |
| Forged MCP approval | critical | The gateway rejected an approval grant that rv did not sign |
| Gate loosened without owner authentication | high | `config.changed` / `policy.changed` loosening with `authorized_by: none` |
| Device fell out of compliance | high | A machine's `rv report` goes from compliant (or new) to not compliant |
| Block spike | medium | One machine has more than N blocks in 10 minutes (default 25) |
| Device stopped forwarding | medium | A machine that forwarded events goes silent for more than N hours (default 24) |

How alerts behave:

- **Repeats:** each rule fires once per subject (a device, a secret or a
  setting) per cooldown.
- **Backfills:** events more than an hour old never fire alerts. Chain
  breaks always do.
- **Floods:** at most 60 alerts are raised per 10 minutes.
- **Retries:** a delivery is retried twice on 5xx, 429 or a network error.
  4xx answers are not retried.
- **Storage:** destination URLs and signing secrets are encrypted at rest
  with a key derived from `RV_CONSOLE_SECRET`. Rotating that secret means
  re-adding the destinations.

Webhook body (`Content-Type: application/json`):

```json
{
  "schema": "rv.console.alert.v1",
  "id": "alr_…",
  "rule": "secret.misuse",
  "severity": "critical",
  "title": "Secret misuse: STRIPE_SECRET_KEY on eng-mbp-0193",
  "summary": "placeholder used from the wrong process",
  "occurredAt": "2026-11-20T23:31:02.000Z",
  "device": { "id": "eng-mbp-0193", "hostname": "eng-mbp-0193" },
  "fields": { "Secret": "STRIPE_SECRET_KEY", "Refusal": "foreignPlaceholder" },
  "url": "https://console.example.com/secrets"
}
```

Each webhook request is signed with the destination's secret, which is shown
once when you create it:
`X-RV-Console-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">`.
Check it with a constant-time compare and reject timestamps older than five
minutes. `X-RV-Console-Delivery` carries the alert id, so you can drop
duplicates.

## How the integrity check works

Each `audit.jsonl` event carries `prev`, the SHA-256 of the line before it,
and `rv_chain_head`, its own SHA-256. For each device, the console stores the
last head it received. Each newly forwarded chained event must name that head
as its `prev`. If it doesn't, the console records a chain break.

A break means one of these happened on the machine:

- a line was edited, removed, inserted or reordered
- forwarding skipped events (for example, a reset cursor)

`rv report` also carries the machine's own chain head. If the console never
received that head, the device shows as **behind**.

rv's chain has no key, so a machine cannot prove its own log is intact. A
head kept somewhere the agent cannot reach, like the console, is the
off-machine check rv's audit guide recommends.

## Security notes

- Passwords are hashed with scrypt.
- Sessions are HMAC-signed, httpOnly, SameSite=Lax cookies, verified on every request.
- Removing a user ends their sessions immediately.
- Sign-in is rate limited per IP and email.
- Single sign-on is OIDC with PKCE, state and nonce. Domain and group policy is checked on every sign-in.
- Alert URLs and signing secrets are encrypted at rest (AES-256-GCM). Webhook requests are HMAC-signed and do not follow redirects.
- Ingest tokens are 256-bit random values. Only their SHA-256 is stored, and they can be revoked.
- Event text in CSV exports is protected against formula injection.
- Every response sends `X-Frame-Options: DENY`, `nosniff`, HSTS, a referrer policy and a permissions policy.
- The image runs as the non-root `node` user, and `/data` has mode 700.
- The console stores only what rv forwards. That never includes command text, secret values, policy bodies or tool arguments.

## Develop

```sh
npm run dev         # Next.js 16 dev server
npm run lint        # ESLint (Next + React Compiler rules)
npm run typecheck
npm test            # vitest: ingest, chain, reports, SSO against a mock IdP, alert rules and delivery
npm run catalog     # regenerate src/lib/catalog.generated.json from Sources/RVPacks
RV_CONSOLE_TOKEN=rvc_… npm run seed -- --url http://localhost:3000   # demo fleet over HTTP
```

Stack: Next.js 16 (App Router, standalone output), React 19, Tailwind 4,
shadcn/ui (Radix), motion, recharts, cmdk, zod, openid-client, and SQLite through Node's
built-in `node:sqlite`, so there are no native modules to compile. The design
plan is in [PLAN.md](PLAN.md).
