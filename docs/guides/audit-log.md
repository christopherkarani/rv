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
arguments. Records carry rule ids, host names, agent session ids, secret
names, argument *names*, fingerprints and home-redacted paths.

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
| `command.denied` | `denied` | rule id, e.g. `core.git:reset-hard` | `host`, `tool`, `category`, `path` (home shown as `~`), `session` (the agent session id, when the host sent one; OCSF `actor.session.uid`) |
| `command.observed` | `info` | rule id | as above, plus `would_be` (`deny` or `ask`): observe mode let it run |
| `command.override` | `allowed` | rule id | `host`, `override` (allow-once, allowlist, rebase recovery, contained delete); `reason` repeats the override |
| `owner.action` | | | every owner-authentication attempt, passed or not |

Plain allows are not logged. Every hook deny is recorded whatever
`rv blocks` keeps.

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

## Reason codes in the OCSF export

`rv audit export --format ocsf` and `rv audit forward --format ocsf` put
one stable reason code in OCSF's `status_code` on every `denied` event and
on every observe- or audit-mode would-be denial (`command.observed`,
`egress.observed`). Other events carry no `status_code`. The code is
derived from what the record already holds, so `audit.jsonl` and the other
OCSF fields are unchanged: `status_detail`, `message` and
`unmapped.rv_reason` still carry the free-text reason.

Key SIEM rules on these strings. They are never renamed; a new reason gets
a new code. A recorded reason rv does not recognise (from an older or newer
writer) gets its area's `*-other` code rather than none.

| Code | Kind | When |
| --- | --- | --- |
| `rv.command.denied-rule` | `command.denied` | A pack or built-in rule denied it; `subject` names the rule |
| `rv.command.denied-secret-path` | `command.denied` | It touched a secret path (`detail.category` such as `ssh`) |
| `rv.command.denied-judge` | `command.denied` | The Laya judge blocked or held it |
| `rv.command.observed-deny` | `command.observed` | Observe mode let it run; enforcement would have denied |
| `rv.command.observed-ask` | `command.observed` | Observe mode let it run; enforcement would have asked |
| `rv.command.observed-other` | `command.observed` | No `would_be` was recorded (older rows) |
| `rv.egress.denied-policy` | `egress.denied` | Not on the runtime's egress allowlist |
| `rv.egress.denied-credential` | `egress.denied` | Missing, malformed or unknown proxy credential |
| `rv.egress.header-too-large` | `egress.denied` | Request headers over 64 KiB |
| `rv.egress.malformed` | `egress.denied` | Not a CONNECT `host:port` or absolute `http://` request |
| `rv.egress.dns-failed` | `egress.denied` | The name did not resolve |
| `rv.egress.address-filtered` | `egress.denied` | It resolved only to addresses the dial filter refuses |
| `rv.egress.dial-failed` | `egress.denied` | The connection could not be made |
| `rv.egress.binary-mismatch` | `egress.denied` | The runtime binary is not admitted or its pin changed |
| `rv.egress.unattributed-peer` | `egress.denied` | Binary-scoped policy with no runtime to attribute the peer to |
| `rv.egress.sni-mismatch` | `egress.denied` | The TLS ClientHello named another server than the CONNECT target |
| `rv.egress.denied-other` | `egress.denied` | Any other recorded reason |
| `rv.egress.observed-denied-policy` | `egress.observed` | Audit mode let it past the allowlist |
| `rv.egress.observed-other` | `egress.observed` | Any other would-be reason |
| `rv.mcp.denied-policy` | `mcp.call` | The tool's policy is `deny` |
| `rv.mcp.inexact-number` | `mcp.call` | An argument rule reads a number rv could not parse exactly |
| `rv.mcp.unserved-tool-name` | `mcp.call` | A tool name rv never lists, so never serves |
| `rv.mcp.hiding-schema` | `mcp.call` | The tool's schema property names hide text from a client |
| `rv.mcp.hiding-untracked` | `mcp.call` | An untracked tool of a server that listed one with a hiding schema |
| `rv.mcp.not-listed-since-restart` | `mcp.call` | The server has not listed the tool since rv restarted it |
| `rv.mcp.not-approved` | `mcp.call` | An `ask` call that was declined or not run |
| `rv.mcp.call-denied-other` | `mcp.call` | Any other denied call |
| `rv.mcp.approval-forged` | `mcp.approval` | A grant not signed by rv was rejected |
| `rv.mcp.approval-refused` | `mcp.approval` | `rv mcp approve` refused (presence, code, or the approval changed) |
| `rv.mcp.secret-refused` | `mcp.approval` | A server's secret was refused at launch or relaunch |
| `rv.mcp.approval-denied-other` | `mcp.approval` | Any other denied approval |
| `rv.secret.malformed` | `secret.use`, `secret.misuse` | Gateway refusal `malformed` |
| `rv.secret.unknown-route` | `secret.use`, `secret.misuse` | `unknownRoute` |
| `rv.secret.no-placeholder` | `secret.use`, `secret.misuse` | `noPlaceholder` |
| `rv.secret.unknown-placeholder` | `secret.use`, `secret.misuse` | `unknownPlaceholder` |
| `rv.secret.foreign-placeholder` | `secret.use`, `secret.misuse` | `foreignPlaceholder` |
| `rv.secret.too-large` | `secret.use`, `secret.misuse` | `tooLarge` |
| `rv.secret.unsafe-value` | `secret.use`, `secret.misuse` | `unsafeValue` |
| `rv.secret.echo-method` | `secret.use`, `secret.misuse` | `echoMethod` |
| `rv.secret.encoded-placeholder` | `secret.use`, `secret.misuse` | `encodedPlaceholder` |
| `rv.secret.surface-not-allowed` | `secret.use`, `secret.misuse` | `surfaceNotAllowed` |
| `rv.secret.repeated-placeholder` | `secret.use`, `secret.misuse` | `repeatedPlaceholder` |
| `rv.secret.outside-allow-rules` | `secret.use`, `secret.misuse` | `outsideAllowRules` |
| `rv.secret.ambiguous-path` | `secret.use`, `secret.misuse` | `ambiguousPath` |
| `rv.secret.audit-unavailable` | `secret.use`, `secret.misuse` | `auditUnavailable` |
| `rv.secret.runtime-mismatch` | `secret.use`, `secret.misuse` | `runtimeMismatch` |
| `rv.secret.runtime-unverified` | `secret.use`, `secret.misuse` | `runtimeUnverified` |
| `rv.secret.expired` | `secret.use`, `secret.misuse` | `expired` |
| `rv.secret.refresh-failed` | `secret.use`, `secret.misuse` | `refreshFailed` |
| `rv.secret.aws-key-mismatch` | `secret.use`, `secret.misuse` | `awsKeyMismatch` |
| `rv.secret.aws-signed-streaming` | `secret.use`, `secret.misuse` | `awsSignedStreaming` |
| `rv.secret.approval-pending` | `secret.use`, `secret.misuse` | `approvalPending` |
| `rv.secret.approval-denied` | `secret.use`, `secret.misuse` | `approvalDenied` |
| `rv.secret.approval-unavailable` | `secret.use`, `secret.misuse` | `approvalUnavailable` |
| `rv.secret.binary-mismatch` | `secret.use`, `secret.misuse` | `binaryMismatch` |
| `rv.secret.aws-unsigned-payload` | `secret.use`, `secret.misuse` | `awsUnsignedPayload` |
| `rv.secret.aws-credentials-in-response` | `secret.use`, `secret.misuse` | `awsCredentialsInResponse` |
| `rv.secret.request-timeout` | `secret.use`, `secret.misuse` | `requestTimeout` |
| `rv.secret.refused-other` | `secret.use`, `secret.misuse` | No refusal recorded, or one rv does not know |
| `rv.admission.denied` | `admission` | The runtime action was denied |
| `rv.admission.rejected` | `admission` | The runtime action was rejected before review |
| `rv.agent.refused` | `agent.*` | An agent instance was refused |
| `rv.owner.refused` | `owner.action` | Owner authentication did not pass |
| `rv.denied-other` | any other | A denial of a kind with no codes of its own |

The `rv.secret.*` codes map one-to-one onto the gateway refusal kept in
`detail.refusal`; the `rv.egress.*` denial codes onto the proxy's recorded
`reason` (before the oracle collapse the cage sees).

### Schema conformance

The export targets OCSF 1.3.0 and declares its profiles in
`metadata.profiles` (`host`, plus `security_control` on Network Activity,
Process Activity and Detection Finding). A test runs one event of every
kind through the mapper and validates it against vendored 1.3.0 schemas
(`Tests/RVHistoryTests/Fixtures/ocsf-1.3.0`). Known gap: API Activity,
Application Lifecycle and Device Config State Change also carry `action`
and `disposition` (and API Activity `device`), and Detection Finding carries
`is_alert`, which 1.3.0 does not define for those classes; they are kept because existing SIEM rules read them.
