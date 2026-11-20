# Hook-local decide

Status: Phase 2a. The C hook decides a call itself when rvd could give
no other answer, so rvd is off the hot path for most calls. Everything
else goes to rvd exactly as before.

## Shape

```
host ─stdin─▶ rv (C)
               │ 1. spawn sibling rv-hook-local (pinned, sanitized, 1 s)
               │      final  ──▶ validate reply ──▶ print, exit
               │      escalate / timeout / crash / untrusted / garbage
               ▼
             2. today's XPC (macOS) / Unix socket (Linux) path to rvd,
                today's fallbacks (RV_HOOK_WHEN_DOWN, observe step-aside)
```

- `Sources/rv-hook-local/main.swift`: a thin executable over
  `LocalHookCommand` (RVService).
- `Sources/RVService/LocalHookDecider.swift`: the decision.
- `Sources/rv-c/local_eval.{h,c}`: spawn, verify, deadline, framing.
- `Sources/rv-c/daemon_trust.c` `rv_verify_local_evaluator`: peer trust.
- `Sources/rv-c/rv.c` `try_local_door`: wiring; the reply goes through
  the same `accept_reply` (request id, semver major) and `deliver_reply`
  as rvd's.

## What is decided locally

`LocalHookDecider` runs rvd's own hook door (`hookWire` over the decision
half of `GatedEvaluate`, `decideVerdict` / `decideFile`) over the same
packs, policy, config and organization policy, read from the passwd home.
In place of what only rvd holds it installs probe ports, and any probe
that fires escalates:

| rvd memory | Local stand-in | Fires when |
| --- | --- | --- |
| Judge model | `JudgePort` that records the call | a pack-allowed, non-safe-lane command with a judge bundle installed → `judge` |
| Allow-once grants, allowlist, rebase recovery, contained delete (Policy gate) | empty grant table plus an allowlist loader that records being called | any deny the Policy gate would see → `policy-gate` |
| Unlock codes, pending approvals | mint / pending ports that record the call | a human-approvable deny → `ask` |
| rvd's launch environment | rerun pinned to `RV_GUARD_MODE=enforce` | observe mode, where the enforce verdict is not the same allow → `observe` |

A final answer is therefore only:

- an allow no probe touched (no judge, no Policy gate);
- a shell deny the Policy gate never sees (`policyGateAccess == .skip`)
  that no transport may unlock (`denyPinned`);
- a file-tool allow or deny (the file door has no Policy gate, unlock
  code or pending row);
- the foreign-tool allow (not this host's tool).

Indeterminate results, malformed payloads, a second evaluation in one
call, or an override-audit effect escalate (`indeterminate`, `malformed`,
`unexpected`). The `judge` escalation is the Phase 2b slot: that class
of call can later go from the hook straight to the judge pool
(`rv-judge serve`) instead of to rvd.

Under observe, a final allow also needs the enforce verdict for the same
call to be that allow. rvd's launch environment may pin enforce (the env
may only tighten), and the local process cannot see it; requiring both
verdicts to agree makes the answer independent of it. The comparison
keys off the guard mode the live pass itself read (from its own
`EvaluationInputs`), never a separate read of `config.json`: a writer
flipping the mode between two reads must not skip the enforce rerun.

### Environment

The C hook spawns `rv-hook-local` with exactly `HOME`, `USER`, `LOGNAME`
from the passwd entry and `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, cwd `/`,
stderr to `/dev/null`, default signal dispositions, and (Darwin)
close-on-exec for every other descriptor. The evaluator also resolves the
home with `getpwuid` itself, and passes an empty environment to guard-mode
resolution, as rvd sees none of the hook's environment either. Nothing an
agent sets in the hook's environment, argv or cwd reaches the decision.

### Effects

A final local answer performs exactly the writes rvd performs for that
answer, before it replies: judge-log rows (safe-lane, engine-missing),
audit and denial-ledger rows for a deny (`AuditLog.append`, flocked and
hash-chained), exemption audit (`FileLockedJSONLStore`). An escalation
writes nothing, so rvd's own evaluation writes each row once.

`judge-log.jsonl` was serialized only in-process (seek to end, write;
`.atomic` replace on first create). It now goes through
`JSONLAppendLog.append` (a `.lock` sidecar under `flock`, `O_APPEND`,
`O_NOFOLLOW`, 0600), so rvd and any number of evaluators append whole rows
and never replace one another's file. The wait for another writer's
lock is bounded (200 ms in total across the in-process and `flock` waits,
non-blocking attempts); on timeout the row is dropped and the verdict is
not held. A drop in rvd is reported to rvd.log (`AuditDropLog`, kind
`judge-log`); a drop in `rv-hook-local` is not, as its stderr is
`/dev/null`; it names the drop in its spool instead, and rvd's drain
reports it in rvd.log (see "The spool rvd drains").

Every one of those writes ends by one write deadline
(`LocalHookDecider.writeDeadline`, `GatedEvaluate.performBounded`): 750 ms
after the evaluator started, the C hook's 1 s less a 250 ms margin for the
spawn and signature check before it started and the reply after. rvd's own
writes keep their waits (the audit chain's 2 s bound, the ledgers'
blocking locks); the evaluator cannot, since a write that held it past the
C hook's deadline would kill it after it wrote, and rvd would then write
the same rows again.

- **The audit row goes first**, with up to 500 ms (`auditFloor`) of what
  is left. In **enforce** an audit row that cannot land by then is not
  answered locally: the evaluator escalates (`audit-unwritten`) having
  written nothing, and rvd answers the call and writes every row itself. A
  deny is never delivered with its chained record missing. In
  **observe** it never escalates (the C hook's observe step-aside could
  turn a floor deny into an allow): the row's fields go to the spool and
  rvd appends them.
- **The other rows share what is left**, in rvd's order. Before each
  write the deadline is checked; past it the row is dropped unwritten, and
  a held lock is retried with non-blocking attempts only until it passes.
- **The spool write counts inside the deadline**: its 50 ms lock bound is
  cut to what is left (one non-blocking attempt once it has passed).
- **Nothing on this path can hang**: every open is `O_NONBLOCK` and
  accepts only a regular file (the logs, their lock sidecars, the
  `.tmp` of a rewrite, the spool and its uncounted file, and
  `config.json` for the guard mode, `blocks.enabled` and
  `analytics.enabled`), so a FIFO planted at any of them fails that one
  read or write at once.

#### The spool rvd drains

What rvd records in memory for a hook call cannot be written by another
process: the analytics counters live in rvd's `AnalyticsCoordinator`
actor, which overwrites `analytics-counters.json` whole. So the evaluator
hands rvd a spool instead, `<config>/hook-local-spool.jsonl`
(`HookLocalSpool`), one batch per final answer:

- `{"v":1,"decision":"allow|deny|indeterminate"}`: the decision rvd's
  analytics recorder counts for the shell door (none for the file door, as
  in rvd), only when `analytics.enabled` is not off;
- `{"v":1,"dropped":"denial-ledger|judge-log|exemption"}`: a row dropped
  at the deadline;
- `{"v":1,"dropped":"audit","audit":{...}}`: an observe-mode audit row
  that did not land: its kind (`command.denied` or `command.observed`),
  rule, host, tool, category, home-redacted path, `wouldBe` and time.
  Never the command text.

A batch is one flocked `O_APPEND` write (`JSONLAppendLog`, no `fsync`, a
4 MiB cap). A batch that cannot land is counted, one byte per row, in
`<config>/hook-local-spool.uncounted`, appended with no lock at all (64
KiB cap): `a` for an audit row, `x` for any other, so a lost row is still
a counted row. Both files must be this user's regular files.

rvd drains both (`HookLocalSpoolDrainer`) on a private serial queue, never
on the cooperative pool: each evaluation requests a drain and a 60 s timer
requests one too, and a request while one is queued is folded into it, so
exactly one drain runs at a time. The drain takes the spool lock with one
non-blocking attempt; an evaluator holding it costs nothing but a later
drain. Per drain:

- each spooled audit row is validated (every field must be one the
  evaluator writes; the spool is a file, so it is read as untrusted) and
  appended to `audit.jsonl` with `detail.recorded_by: "hook-local"`;
- audit rows lost without their fields (the `a` bytes, or spooled fields
  that do not validate) get one `audit.gap` event with their count, so a
  verifier sees that the chain is missing rows;
- one `rvd.log` line names the recovered rules and counts the rest, at
  most once a minute;
- the decisions join rvd's counts and the daily analytics flush runs, so
  it no longer waits for rvd to evaluate something. An rvd without
  analytics discards spooled decisions.

Malformed lines count as lost, and spool bytes past the cap are counted
and dropped. The spool can add analytics counts and audit rows marked
`recorded_by: hook-local`, never change a verdict. Anything running as the
user could write those rows; it could already append to `audit.jsonl`
itself (the chain is unkeyed, see `docs/guides/audit-log.md`).

Double counting: the C hook kills an evaluator that is still running at
its deadline and asks rvd. An evaluator killed after its spool write (in
the 250 ms margin) has counted its decision, and rvd counts the call
again. The margin makes this rare, and it costs one analytics count, never
a row in the chain or a verdict.

`LocalHookRecordParityTests` proves the parity: two identical homes on
one fixed clock, the evaluator deciding every call over one and rvd
answering each call the evaluator finalized over the other; the audit
chain, denial ledger, judge log and exemption audit must be the same
bytes, and the counts rvd ingests from the spool must equal the counts it
records itself.

Not mirrored: the `HookTiming` past-deadline `rvd.log` line (PR #621, not
on this branch) fires only for an evaluation past rvd's 7 s hook budget,
which a local answer cannot reach inside its 1 s.

## Trust boundary

`rv-hook-local` is a new process holding authority: its final answer is
delivered to the host. It gets the same pinning as `rvd`, checked by the
C hook **before the child reads a byte** (`rv_verify_local_evaluator`):

- the path is `<dir of rv's own executable>/rv-hook-local`, found from
  `_NSGetExecutablePath` / `/proc/self/exe`, never PATH, argv0 or HOME;
- **Darwin**: spawned with `POSIX_SPAWN_START_SUSPENDED`; its live code
  (`SecCodeCopyGuestWithAttributes` by pid, rebound to its cdhash) must
  run from the sibling path and, with no `peer-trust.json`, carry a cdhash
  equal to the on-disk sibling; with a manifest it must be hardened,
  non-adhoc, Developer ID signed `dev.rv.rv-hook-local` from the team the
  production `.service` entry names. A dev (cdhash-pinned) service entry
  has no team to derive this from and gets no local door: every call goes
  to rvd. An invalid manifest rejects it, as it rejects rvd. Only then is
  it resumed (`SIGCONT`);
- **Linux**: `/proc/<pid>/exe` must resolve to the sibling path (as for
  `rvd`, no hash);
- its output must be exactly `rv-hook-local/1 final\n` plus an IPC reply
  that parses, carries this request id and the same semver major, from a
  process that exited 0 within 1 s. Anything else is an escalation.

### Why "never evaluate locally" no longer holds, for this path only

The C hook and `ServiceClient.hookEvaluate` never retried through a local
evaluation door. That rule exists because a local evaluation after an rvd
failure would let an attacker who can make rvd fail (kill it, stall it,
fill its queue) choose a weaker evaluator: one without grants, pending
state or the judge, whose allow is not rvd's allow.

The new door is not that door:

1. **It runs before rvd, never after an rvd failure.** No rvd outcome can
   route a call to it. Its own failure routes to rvd, never to a fallback
   class, so it adds no new way to reach `RV_HOOK_WHEN_DOWN` or the
   observe step-aside (which still needs rvd positively unreachable).
2. **It answers only what rvd would answer identically.** Every input
   rvd has and it lacks is a probe that escalates. A missing judge, grant
   table or pending state can only cause an escalation, never an allow.
3. **It is checked as rvd is checked.** Same sibling pinning, same reply
   validation; a stricter identity on manifest installs (an exact signing
   identifier).
4. **It is proven against rvd.** `LocalHookEquivalenceTests` sends every
   engine corpus command plus ~1000 everyday commands, and file paths
   through Read / Write / Edit / Grep, in and out of a repo, under
   enforce, observe and with a judge installed, through both, and
   requires every final local answer to be rvd's reply byte for byte.

The Swift CLI's `ServiceClient.hookEvaluate` keeps the old rule: it has
no local door.

### Budget

The local door has 1 s, the signature check included: a check that ends
past it kills the child before it resumes. The C hook's evaluate send cutoff (5 s) is
measured from process start, so the door's time comes out of it: the
"5 s cutoff + rvd's 7 s < the 15 s host shim" bound is unchanged, and a
slow door followed by a slow rvd start fails closed (timeout class, never
the observe step-aside).

## Measurements

See the PR description for the numbers measured on the change (cold
`rv hook` local path p50 / p99, and the share of calls decided locally
per configuration from `RV_LOCAL_EQUIVALENCE_REPORT`). No policy
snapshot is built: it is only warranted if the local p99 exceeds 60 ms.

## Packaging

`rv-hook-local` is a SwiftPM product. Until the release pipeline stages
and signs it next to `rv`, `rv-cli` and `rvd`, it is absent from
installs and the door is dormant: every call goes to rvd, as today.
