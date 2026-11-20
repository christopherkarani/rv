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
lock is bounded (200 ms, non-blocking attempts); on timeout the row is
dropped, as on any other judge-log failure, and the verdict is not held.

Every one of those writes shares one 200 ms budget
(`LocalHookDecider.recordBudget`, `GatedEvaluate.performBounded`): a log
another process holds is retried with non-blocking locks until the budget
passes, and the row is then dropped. rvd's own writes keep their waits
(the audit chain's 2 s bound, the ledgers' blocking locks); the evaluator
cannot, since a write that held it past the C hook's 1 s deadline would
kill it after it wrote, and rvd would then write the same rows again.

#### The spool rvd drains

What rvd records in memory for a hook call cannot be written by another
process: the analytics counters live in rvd's `AnalyticsCoordinator`
actor, which overwrites `analytics-counters.json` whole. So the evaluator
hands rvd a spool instead, `<config>/hook-local-spool.jsonl`
(`HookLocalSpool`), one batch per final answer:

- `{"v":1,"decision":"allow|deny|indeterminate"}`: the decision rvd's
  analytics recorder counts for the shell door (none for the file door, as
  in rvd), only when `analytics.enabled` is not off;
- `{"v":1,"dropped":"audit|denial-ledger|judge-log|exemption"}`: a row
  the record budget dropped.

A batch is one flocked `O_APPEND` write (`JSONLAppendLog`, 50 ms lock
bound, no `fsync`, a 4 MiB cap). A batch that cannot land is counted, one
byte per row, in `<config>/hook-local-spool.uncounted`, appended with no
lock at all (64 KiB cap), so a lost row is still a counted row. Rows
carry a kind and nothing else: no command text, path or session.

rvd drains both off the reply path, on the task that records its own
analytics for each evaluation (`ServiceRuntime.ingestHookLocalSpool`):
the spool is read and truncated under the writers' lock (1 s bound), the
decisions join rvd's counts, and dropped or lost rows produce one
`rvd.log` line (`rvd: the hook-local evaluator dropped records ...`). An
rvd without analytics discards spooled decisions. Malformed lines count as
lost; the spool can only add analytics counts, never change a verdict.

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
