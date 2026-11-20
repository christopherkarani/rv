# rv Cloud dashboard

The hosted dashboard for rv: fleet posture, the deny feed, the observe-to-enforce
rollout report, signed organization policy, and audit-chain integrity across
every machine running rv. Next.js 16 on Vercel, Supabase (Postgres, Auth) for
data and sign-in, shadcn/ui for the interface.

rv Cloud is read-mostly by design. It shows what happened and distributes
signed policy through your MDM; it never approves, overrides or loosens
anything on a machine, never holds your policy signing key, and never
receives command text, prompts, file contents or secret values.

## How it fits together

```text
machine (rv)                                rv Cloud (this app)                 people
  rv audit forward ── POST /api/v1/events ─▶  ingest_events()  ─┐
  rv report --json ── POST /api/v1/report ─▶  ingest_report()   ├─▶ Postgres ◀── dashboard (RLS)
  enroll once ─────── POST /api/v1/enroll ─▶  enroll_machine() ─┘
  org policy ◀──── your MDM ◀──── signed bundle (signed offline with rv managed sign)
```

- **Tenancy.** Every row belongs to an org. People read through row-level
  security as themselves; machine writes go through security-definer
  functions only the service role can call, each one transaction.
- **Machine auth.** An org enrollment token (`rvc_enr_…`, shown once, stored
  hashed) is traded for a per-machine credential (`rvc_mch_…`, shown once,
  stored hashed, revocable per machine).
- **Ingest formats.** `/api/v1/events` accepts exactly what `rv audit forward`
  sends: OCSF 1.3.0 (its default) or `rv.audit.v1` (`--format rv`). Batches
  are idempotent (rv's forwarder is at-least-once), the duplicate a deny
  leaves in `blocks.jsonl` is dropped the same way rv drops it, and each
  machine's hash chain is checked for continuity: a forwarded event that does
  not continue the last head is recorded as a gap.
- **Reports.** `/api/v1/report` takes `rv report --json` (`rv.report.v1`) and
  computes compliance with the same rule as rv. Optional `hosts` and `packs`
  fields are accepted for the client update that adds them.
- **Policy.** The editor writes an unsigned `policy.json` using rv's own
  keys. You sign it with `rv managed sign`; the upload is checked against
  rv's parser rules and verified (Ed25519) against your pinned keys, and an
  older serial is refused, before it is stored byte for byte.

## Deploy (Vercel + Supabase)

1. **Supabase project.** Create one. Apply the schema with the Supabase CLI:
   ```sh
   npx supabase link --project-ref <ref>
   npx supabase db push          # applies supabase/migrations
   ```
2. **Auth.** In Supabase Auth: set the Site URL to your `APP_URL`, add
   `${APP_URL}/auth/callback` to the redirect allow-list, and configure SMTP
   (the built-in sender is rate-limited and not for production). Optionally
   enable the GitHub provider and set `NEXT_PUBLIC_AUTH_GITHUB=true`.
3. **Vercel project.** Import the repository with **Root Directory**
   `dashboard`. Set the variables from [`.env.example`](.env.example).
   `vercel.json` schedules the daily retention job at `/api/cron/prune`,
   authenticated with `CRON_SECRET`.
4. **First org.** Sign in at `APP_URL`, create an organization, create an
   enrollment token in Settings and follow the commands it shows.
5. **Plans.** New orgs start on `pilot`. Change `orgs.plan` in SQL until
   billing exists; it sets the longest retention an org can choose.

## Enrolling a machine

Settings shows these with your URL and token filled in. They work with rv as
it ships today:

```sh
# 1. Trade the enrollment token for this machine's credential
CRED=$(curl -fsS https://cloud.example.com/api/v1/enroll -H 'content-type: application/json' \
  -d "{\"token\":\"rvc_enr_…\",\"name\":\"$(hostname -s)\"}" | sed -E 's/.*"credential":"([^"]+)".*/\1/')
# 2. Keep it in the Keychain / Secret Service as an rv secret
printf %s "$CRED" | rv secrets set RV_CLOUD --environment
# 3. Forward the audit log every five minutes
rv audit forward --to https://cloud.example.com/api/v1/events --header 'Authorization=Bearer ${secret:RV_CLOUD}' --install
```

Posture reports need a scheduled `rv report --json` POST until rv ships
`rv report --to`; Settings prints a cron line for it. Until a machine sends
its first report it shows as "Awaiting report".

## Develop

Needs Node 22, Docker and a Postgres 16 you can reach.

```sh
npm install
scripts/dev-stack.sh up           # GoTrue + PostgREST + Mailpit + gateway, applies migrations
cp .env.example .env.local        # then paste values from .dev-stack/keys.env, APP_URL=http://localhost:3000
npm run dev                       # http://localhost:3000; sign-in emails land in Mailpit (http://127.0.0.1:54324)
```

`dev-stack.sh` assumes Postgres at `127.0.0.1:54322` (override with `DB_URL`
and `DB_HOST_URL`). If your machine can pull Supabase's own images,
`npx supabase start` works too.

| Command | What it runs |
| --- | --- |
| `npm run lint` | ESLint (Next.js + React compiler rules) |
| `npx vitest run tests/unit` | Ingest parsers, report compliance, policy validation and signatures |
| `npx vitest run` | Plus schema/RLS tests and ingest API tests (needs the dev stack and `DATABASE_URL`) |
| `node e2e/smoke.mjs` | Browser flow against a running app: sign-in, enroll, ingest, policy, invites, revoke, exports, mobile layout |
| `npm run build` | Production build; needs no secrets |
| `node scripts/sync-packs.mjs` | Regenerates the pack and rule catalog from `../Sources/RVPacks` |
| `scripts/dev-stack.sh reset` | Drops the `public` schema and re-applies migrations |

CI runs all of it in `.github/workflows/dashboard.yml`.

## Layout

| Path | What |
| --- | --- |
| `supabase/migrations/` | Schema, RLS policies, ingest and aggregate functions |
| `src/app/api/v1/` | Machine endpoints: enroll, report, events |
| `src/app/(app)/` | Signed-in pages; each streams its data inside Suspense |
| `src/lib/ingest/` | Parsers for rv's event and report formats |
| `src/lib/policy.ts` | policy.json validation and Ed25519 verification |
| `src/lib/machine-status.ts` | Machine status and drift, from the latest report |
| `src/proxy.ts` | Session refresh and sign-in redirect |

## Known limits

- Host modes and enabled packs per machine appear once rv's report includes
  them; until then those cells read "not reported".
- Generated Supabase types are not checked in: run
  `npx supabase gen types typescript --linked > src/lib/database.types.ts`
  and pass the type to the clients to tighten queries.
- Billing, SSO/SCIM and alert delivery are not built yet.
