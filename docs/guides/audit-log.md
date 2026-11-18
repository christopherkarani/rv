# The audit log

rv writes what it refuses, what a person overrides, what changes its own
rules, and every MCP tool call and secret use to one append-only file in
which each line carries the SHA-256 of the line before it.

How this was checked: `rv audit`, `rv audit verify` (intact and after
editing a line), `rv audit export --format ocsf` and `--json` were run on
Linux against a log the other guides' runs produced; the outputs below
are from those runs. The record fields for denies, overrides, MCP calls
and restarts were read from the source. The custodian end-to-end test
also checked that the chain verifies after trust, approvals and calls.

## Where it is

`~/.config/rv/audit.jsonl`, mode 0600, one JSON object per line. Other
ledgers in `~/.config/rv` (the deny list behind `rv blocks`, egress
denials, workspace logs) are joined with it by `rv audit` into one
`rv.audit.v1` stream, but only `audit.jsonl` is hash-chained.

Nothing in it is command text, a secret value, a policy body or a tool's
arguments. Records carry rule ids, host names, secret names, argument
*names*, fingerprints and home-redacted paths.

## One record

From a run on Linux (`rv secrets set` of a new secret):

```json
{"decision":"info","detail":{"added":"OPENAI_API_KEY","authorized_by":"none","direction":"loosening","new":"1 definitions","prior":"0 definitions","setting":"secrets"},"kind":"config.changed","prev":"0000000000000000000000000000000000000000000000000000000000000000","schema":"rv.audit.v1","source":"audit.jsonl","subject":"secrets","time":"2026-11-17T19:37:03Z"}
```

| Field | Meaning |
| --- | --- |
| `schema` | Always `rv.audit.v1` |
| `time` | UTC, ISO 8601 |
| `kind` | What happened; dotted names filter by prefix (`mcp` matches `mcp.call`) |
| `decision` | `allowed`, `denied`, `pending`, `failed` or `info` |
| `subject` | What it is about: a rule id, `server/tool`, a secret name, a setting |
| `reason` | Why, when there is one |
| `workspace`, `runtime`, `agent` | Set when they apply |
| `source` | Which writer or ledger |
| `detail` | Kind-specific string fields |
| `prev` | SHA-256 of the previous line; 64 zeros on the first line |

Each append waits at most 2 seconds for the file's lock. When it cannot
write, rv fails closed where it matters: an MCP call that cannot be
recorded is not sent, an override that cannot be recorded is not applied,
and a change that loosens rv's rules is refused (exit 74). A deny stands
either way.

## Reading it

```bash
rv audit
```

```text
2026-11-17T19:37:03Z  info     config.changed  secrets  0 definitions -> 1 definitions  added=OPENAI_API_KEY  by=none
2026-11-17T19:37:19Z  info     secret.use  EXAMPLE_API_KEY  reason=staged for launch
```

```bash
rv audit --kind mcp.call --since 24h
```

```bash
rv audit -n 200 --json
```

```bash
rv audit export --since 7d > rv-audit.jsonl
```

`rv audit` shows the newest 50 by default (`-n`); `--since` takes `30m`,
`24h`, `7d`; `--kind` is repeatable. `export` writes JSON Lines oldest
first; `--format ocsf` maps them to OCSF 1.3.0 for a SIEM. `rv audit
forward --to https://…` posts new events in batches and advances its
cursor only on a 2xx answer.

## Verifying the chain

```bash
rv audit verify
```

```text
audit chain intact: 2 lines, head 5acdcd3f268db5ed1b58bfad22df3c5f75c2845cc9f7ef27fedb01990fc72e6c
```

After changing one character in line 1 of the same file:

```text
audit chain BROKEN at line 2 of ~/.config/rv/audit.jsonl: prev does not match line 1
  lines 1-1 are intact; line 2 or the one before it was edited, removed, inserted, or reordered
```

`verify` exits 0 when intact and 1 at the first break; `--json` gives
`lines`, `head`, `unchained` and `firstBreak`.

What this proves and what it does not: the chain is **unkeyed**. It finds
an edit, deletion, insertion or reordering that did not recompute the
hashes after it. Anything running as you can rewrite the whole file and
recompute every hash, or cut off the tail, and `verify` will still say
intact. To catch that, keep the head somewhere the agent cannot reach:
forwarded events carry `rv_chain_head`, so compare it off the machine.

## What is recorded

### Hook denies and overrides

| Kind | Decision | `subject` | `detail` |
| --- | --- | --- | --- |
| `command.denied` | `denied` | rule id, e.g. `core.git:reset-hard` | `host`, `tool`, `category`, `path` (home shown as `~`) |
| `command.observed` | `info` | rule id | as above, plus `would_be` (`deny` or `ask`): observe mode let it run |
| `command.override` | `allowed` | rule id | `host`, `override` (allow-once, allowlist, rebase recovery, contained delete); `reason` repeats the override |
| `owner.action` | | | every owner-authentication attempt, passed or not |

Plain allows are not logged. Every hook deny is recorded whatever
`rv blocks` keeps.

A command rv could not finish evaluating ("Run it in Terminal") is
refused too. Each such refusal by the hook or file-tool guard is recorded as
a `command.denied` row marked `detail.verdict: indeterminate`. Its `subject` is
`rv.indeterminate:<reason>` and `reason` holds the reason class, never the
command: `selfProtection` (an rv command that would weaken rv),
`packageScriptUnresolved`, `unresolvedInvocation`,
`inlineProgramNeedsJudge`, `commandTooLarge`, `budgetExhausted` or
`corePacksUnavailable`. `rv test` and `rv explain` record nothing.

Observe mode keeps refusing the ones that touch rv's own protection, and
records them as that same `command.denied`: an rv command that would
weaken rv, a command naming rv's config, its hook or service files, a host
settings file or rv's Linux secret store, and one that stops rvd or writes
rv's install. For example, `$EDITOR ~/.claude/settings.json`
(`unresolvedInvocation`) is still refused. Observe lets every other one
run and records it as `command.observed` with `would_be: deny`. Observe
never records an `inlineProgramNeedsJudge` as `command.observed`: when no
judge can score such a program, observe counts it as a would-be allow, which
is not logged.

`rv report` counts these rows with the other `command.denied` (and
`command.observed`) events. They are not rule denies, so `rv blocks` does
not list them.

### Changes to rv's own rules

`config.changed` (safety level, host modes, `guard.mode`, packs, the
allowlist, secret definitions, egress reviews), `policy.changed` (a new
`policy.toml` revision) and `policy.managed` (organization policy
accepted, changed, or no longer verifying). Each carries the prior and
new value, `direction` (tightening or loosening) and `authorized_by`:
the owner check that passed, the organization signature, or `none`. The
record is written before the change.

### MCP calls

One `mcp.call` record per step of a call, `source` `mcp-gateway`,
`subject` `server/tool`:

| `detail` field | Meaning |
| --- | --- |
| `server`, `tool` | Which tool |
| `policy` | The decision: `allow`, `ask` or `deny` |
| `argumentKeys` | The argument names, comma-separated (never the values); `argumentKeysTruncated` when cut |
| `isError` | Whether it ended in an error |
| `stage` | `forward`: written before the call is sent |
| `approval`, `approvedVia` | The approval id and how it was approved |
| `durationMs` | How long the server took, when it answered |

The `decision` reads `allowed` for a call that went to the server (even
if it then failed), `pending` while it waits for approval, and `denied`
when rv or a person refused it. The `reason` says how it ended, for
example `timed out: no answer within 300 s`, `upstream exited`,
`upstream restarting: process exited`, `the server has not listed this
tool since rv restarted it`, `64 calls to this server are already in
flight`, `not sent: MCP server <name> has its most requests in flight`
(after its `forward` record; an approved call's row keeps its approval
id, since the approval was spent), `gateway stopped; the call may still
have run`, or `cancelled by client`.

Other MCP kinds:

- `mcp.approval`: `mcp.json` trusted, approvals granted or refused, a
  forged grant rejected, OAuth sign-ins, a secret refused at launch or
  at relaunch.
- `mcp.tool.changed`: a tool listed with a definition you did not trust.
- `mcp.hosts.ungoverned`: serve started while host configs run servers
  around the gateway (counts only).

**Restarts** are not a record of their own. A call cut off by a crash is
an `mcp.call` with reason `upstream exited`; a call refused while the
server comes back has `upstream restarting: <why>`; a call to a tool the
restarted server did not list again names that. The restart steps
themselves (gone, restarting in N s, back, gave up) are on serve's
stderr, which your MCP host usually keeps in its own log.

### Secrets

`secret.use` for each launch staged and each request forwarded and its
outcome; `secret.misuse` (alert-worthy) for a request the secret's own
policy refused or that came from the wrong process. Values never appear;
`fingerprint` is a keyed hash you can compare with `rv secrets check`.
