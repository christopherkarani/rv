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
| **Settings** | Onboarding snippets, ingest tokens, users (admin or viewer), the console's own audit log |

The UI follows an editor's layout: page tabs, a collapsible explorer, a ⌘K
command palette, `G` then a letter to jump between pages, `/` to search, and a
status bar showing ingest, fleet and chain health. It has dark and light
themes. Motion is built with `motion` and turns off when the OS asks for
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
| `RV_CONSOLE_PUBLIC_URL` | Base URL used in onboarding snippets |
| `RV_CONSOLE_ADMIN_EMAIL`, `RV_CONSOLE_ADMIN_PASSWORD` | Seed the first admin |
| `RV_CONSOLE_DEMO` | `1` seeds and streams a demo fleet (never in production) |
| `RV_CONSOLE_INSECURE_COOKIES` | `1` allows session cookies over plain http (lab only) |

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
npm test            # vitest: parser, chain, reason codes, ingest route + SQLite integration
npm run catalog     # regenerate src/lib/catalog.generated.json from Sources/RVPacks
RV_CONSOLE_TOKEN=rvc_… npm run seed -- --url http://localhost:3000   # demo fleet over HTTP
```

Stack: Next.js 16 (App Router, standalone output), React 19, Tailwind 4,
shadcn/ui (Radix), motion, recharts, cmdk, zod, and SQLite through Node's
built-in `node:sqlite`, so there are no native modules to compile. The design
plan is in [PLAN.md](PLAN.md).
