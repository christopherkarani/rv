# Host wire matrix

`hostDenyText` is the only reason string. Codecs wrap it. PLAN +
`host-contracts-v1.md` win wording fights.

## Two layers

**Host API** (what Pi / Grok / OpenCode see) is not the same as
**`rv hook` stdout / exit** (what the adapter reads).

## `rv hook` stdout / exit

| Evaluate | `--host grok` | `--host pi` / `--host opencode` |
|---|---|---|
| allow (incl. medium match) | empty, exit 0 | empty, exit 0 |
| deny | `{"decision":"deny","reason":"<hostDenyText>"}` + newline, **exit 0** | same JSON, **exit 1** |
| indeterminate | same JSON, reason is the incomplete-eval sentence, exit 0 | same JSON + sentence, exit 1 |

PLAN #7: Grok emit is JSON + exit 0. Do **not** emit exit 2. The host may
honor exit 2; rv does not use that door. Extra keys (`ruleId`, allow-once
codes, `block`) stay off stdout.

Pi/OpenCode hosts never see this JSON. The adapter maps it.

## Host API (after the adapter)

| Evaluate | Grok | Pi | OpenCode |
|---|---|---|---|
| allow (incl. medium match) | empty, exit 0 | no block | no throw |
| deny / indeterminate | JSON deny (above) | `{ block: true, reason }` | `throw new Error(reason)` |

Adapters honor `decision=deny` **regardless of exit code**. Empty stdout +
exit 0 → allow.

## Adapter miss (binary) vs daemon miss

PLAN #6 / `host-contracts-v1.md`:

| Event | Pi | OpenCode | Grok |
|---|---|---|---|
| cannot spawn `rv` (ENOENT) | `{ block: true, reason: "rv missing" }` | throw `rv missing` | **host fail-open** (process never starts) |
| started `rv` times out, crashes, or non-JSON | `{ block: true, reason: "rv failed" }` | throw `rv failed` | host fail-open |
| Grok malformed / unreadable stdin | — | — | empty allow (T4.3) |

`rvd` down or skewed is **not** this table. `rv hook` evaluates in-process
and then uses the evaluate rows above.

## Ownership

| Piece | Owner |
|---|---|
| `hostDenyText` / view models | `RVPresentation` (T2). CLI calls it. |
| palettes, TTY detect | `RVTheme` |
| `reduce` / `render` → `[String]` | `RVTUI` (TTY `rv test` / `explain` only) |
| complete Host adapter behavior: embedded resources, decode, `encodeAllow`, `encodeDeny(reason:)`, Hook mapper/voice | `RVHooks` (no evaluate, no XPC, no Presentation import, no setup mutations) |
| I/O, evaluate call, fallback, Decision switch, Host adapter setup mutations | `RVCLI` |
| XPC listener, launchd **template** | `RVService` (T3). Live plist is T6. |
| Codable frames | `RVIPC` (`rv.ipc.v1`) |

`RVHooks` must not import CLI, TUI, Presentation, or Service.

## Surfaces that stay off v1

Host Allow button. Pi `registerMessageRenderer`. OpenCode toast.
`permission.ask`. Read / Edit / MCP hooks. Live HOME in tests. Production
Unix socket. Command text in `os_log`.
