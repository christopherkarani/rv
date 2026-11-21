# rv Console — enterprise dashboard plan

## Why this shape

rv already exports everything an enterprise dashboard needs; it just has no
place to land it:

| rv surface | What it gives the dashboard |
| --- | --- |
| `rv audit forward --to URL` (OCSF 1.3.0 default, or `--format rv`) | Batched, at-least-once POSTs of every `rv.audit.v1` event: denies, observed would-be denies, overrides, MCP calls, secret use/misuse, config and policy changes, owner actions, egress, workspaces |
| `audit.forward` in the organization policy (`rv managed`) | Pushes the forward URL and headers to every machine in the fleet, so onboarding is one policy change |
| `rv_prev` / `rv_chain_head` on each forwarded event | Off-machine tamper evidence: the receiver can check that each event's `prev` equals the previous event's head (`docs/guides/audit-log.md`, "Verifying the chain") |
| OCSF `metadata.uid` | Stable id, so at-least-once resends dedupe |
| `rv report --json` (`rv.report.v1`) | Per-machine posture for MDM: version, platform, org policy state and serial, MCP gateway health, secret policy violations, 24h audit counts, chain head |

So rv Console is **the receiving end of `rv audit forward` plus a posture
collector for `rv report`**, with a UI on top. No agent changes are needed
to ship it.

## What enterprises expect, mapped to pages

| Page | Questions it answers | Data |
| --- | --- | --- |
| **Overview** | Is the fleet safe right now? What did rv stop this week? | KPIs (blocked, would-be blocked, overrides, MCP calls, secret misuse, compliant devices), decision timeline, top rules, by agent host, live feed |
| **Activity** | What exactly happened, where, when? | Full audit stream: search, filter by kind/decision/device/host, event inspector with raw JSON, CSV/JSONL export |
| **Detections** | Which rules fire, on which agents, trending up? | `command.denied` / `command.observed` grouped by rule, pack, category, reason code |
| **Fleet** | Which machines run rv, are they compliant, are they current? | `rv report` posture + last-seen from events |
| **MCP governance** | Which servers/tools do agents call, which are denied or need approval, how slow are they? | `mcp.call`, `mcp.approval`, `mcp.tool.changed` |
| **Secrets** | Which secrets are used, any misuse? | `secret.use`, `secret.misuse` (names and fingerprints only — rv never forwards values) |
| **Policy & changes** | Who loosened the gate, was it authorized? Is the org policy rolled out? | `config.changed`, `policy.changed`, `policy.managed`, `owner.action`, report `managed.serial` |
| **Integrity** | Has any machine's audit log been edited, cut, or gone quiet? | Chain verification per device, chain breaks, report head vs last forwarded head, stale devices |
| **Alerts** | Who gets told, and where, when something needs a person? | Slack and signed webhooks; rules for chain breaks, secret misuse, forged MCP approvals, unauthorized loosening, non-compliance, block spikes, silent devices |
| **Settings** | How do I connect machines, who can see this? | Ingest tokens, onboarding snippets (CLI, org policy, MDM), SSO status, users and roles |

## Architecture

```
 rv (each machine) ── rv audit forward (cron/launchd) ──▶ POST /api/v1/ingest   ─┐
                   └─ rv report --json (MDM script)  ──▶ POST /api/v1/reports  ─┤
                                                                                ▼
                                       Next.js 16 (App Router, Node runtime) + SQLite (node:sqlite, WAL)
                                                                                │
                              Server Components query SQLite directly ──────────┤
                              /api/v1/events (live tail, paging), /api/v1/export┘
```

- **Ingest** accepts both forward formats, validates with zod, dedupes on uid,
  derives OCSF reason codes for `rv`-format events, and advances each device's
  hash chain incrementally (a mismatch is stored as a chain break). Bearer
  tokens are random 256-bit values stored as SHA-256 hashes.
- **SSO**: OpenID Connect (openid-client) with PKCE, state and nonce; email-domain allowlist, group-to-role mapping, just-in-time accounts, optional enforcement with local-admin break-glass.
- **Alerts**: rules evaluated after each ingest commit and on a one-minute sweep; per-subject cooldowns, a flood cap, retries, and a delivery log. Slack Block Kit or a signed JSON webhook; URLs encrypted at rest.
- **Auth**: email + scrypt password, HMAC-signed session cookie checked in
  `proxy.ts` and again server-side; roles `admin` / `viewer`. First run shows a
  one-time setup screen (or seeds from `RV_CONSOLE_ADMIN_*`). Login is rate
  limited. Ingest endpoints use tokens only, never cookies.
- **Storage**: one SQLite file in `RV_CONSOLE_DATA_DIR` (Docker volume),
  retention pruning (`RV_CONSOLE_RETENTION_DAYS`, default 90).
- **Ops**: `Dockerfile` (standalone output, non-root), `/api/health`, security
  headers, `npm run seed` for a realistic demo fleet, CI job for lint,
  typecheck, unit tests and build.

## Design language — "editor" console

Modeled on the feel of an AI code editor (dark, quiet, dense, fast), not on any
product's assets:

- Window chrome: thin title bar with breadcrumb, `⌘K` palette pill, range
  picker and a live indicator; icon rail + labeled explorer; editor-style page
  tabs; a status bar with fleet, ingest and chain state.
- Geist Sans / Geist Mono; ids, rules, hashes and paths in mono.
- Motion (motion/react): spring layout transitions on nav and tabs
  (`layoutId`), staggered panel entrance, counting KPIs, AnimatePresence on the
  live feed, cursor-following spotlight on panels, blinking caret on headings,
  ⌘K command palette for navigation and actions. All of it honors
  `prefers-reduced-motion`.
- Charts (recharts) use a validated palette: blocked / overrides / observed /
  MCP in a CVD-checked order for both themes; status colors always carry an
  icon and a label.

## Milestones

1. Data layer: schema, ingest (both formats), chain verification, reports, queries, tests.
2. Auth: setup, login, sessions, tokens, users.
3. Shell: chrome, nav, tabs, palette, status bar, motion primitives.
4. Pages in the order above.
5. Ops: Docker, health, seed, CI, README.
