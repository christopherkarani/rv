# rv Cloud dashboard (prototype)

A front-end prototype of the hosted rv dashboard from the product spec: fleet
posture, the deny feed, the observe-to-enforce rollout report, the org policy
editor and audit integrity. Built with Next.js, Tailwind CSS and shadcn/ui
(Base UI primitives), with light and dark themes.

There is no backend yet. Every page reads mock data from `src/lib/data.ts`,
generated from a fixed seed. The data uses the rv client's real shapes:

| Mock | Real source in rv |
| --- | --- |
| `Machine` | one `rv.report.v1` document (`Sources/RVCLI/Commands/ReportCommand.swift`) |
| `AuditEvent` | one `rv.audit.v1` record sent by `rv audit forward` |
| pack and rule ids | `Sources/RVPacks/Resources/packs/*.json` |
| policy editor output | `policy.json` as parsed by `Sources/RVPolicy/ManagedPolicy.swift` |

The policy editor downloads an unsigned `policy.json` that follows that
parser's keys (`version`, `organization`, `serial`, `mcp`, `secrets`,
`audit.forward`, `gate`). Signing stays off the server:
`rv managed sign policy.json --key <key>`, then `rv managed verify <dir>`.

## Run

```sh
npm install
npm run dev     # http://localhost:3000
npm run build   # production build; all pages prerender
npm run lint
```

## Pages

| Route | What it shows |
| --- | --- |
| `/` | Fleet stats, 14-day deny and would-be-block chart, top rules, drift, rollout summary |
| `/machines` | Fleet table with drift, compliance and silence filters (`?filter=drift`) |
| `/machines/[id]` | One machine's report: host modes, posture, checks, packs, chain head, events |
| `/activity` | Log-style feed of denies, observed blocks, overrides and alerts |
| `/rollout` | Per-host readiness to move from observe to enforce |
| `/policy` | Org policy editor with live `policy.json` preview, and revisions |
| `/audit` | Audit chain status per machine and SIEM destinations |
| `/settings` | Enrollment command, retention, data received, danger zone |

## Not wired yet

- Ingest API, auth, and storage (see the spec's data model section).
- `rv cloud enroll` and `rv report --to` do not exist in the client yet.
- Buttons that would write data (export, upload, revoke, rotate) are inert.
- The dashboard never approves or overrides anything on a machine, by design.
