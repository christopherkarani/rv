# Linux cloud baseline (M0)

First measurements of rv on Linux from a cloud agent session, with the
scripts that reproduce them. Recorded 2026-11-20 on `main` at `c818488`
plus the M0 scripts.

## Machine

Cloud container: Ubuntu 24.04.5, kernel 6.18 (Landlock ABI 7), glibc 2.39,
4 vCPU, 15 GB RAM, x86_64. Process 1 is not systemd, there is no session
D-Bus, and the session runs as root. Swift 6.4.0 official tarball.

## Test suite

`Scripts/cloud-test.sh` from a fresh session, started as root:

| Step | Time | Result |
| --- | --- | --- |
| Debug build with tests | 418 s | ok |
| `swift test` (unfiltered, as in `pr.yml`) | 232 s | 8,837 tests passed, 0 failed, 22 known issues |
| `~/.config/rv` fingerprint | | unchanged |

Running `swift test` directly as root instead fails 17 tests. Each makes a
path unreadable or read-only to prove rv refuses safely, and root ignores
permissions. Two further traps, both handled by the script:

- A new Ubuntu user gets umask 002. rv rejects group-writable managed
  policy files (correctly), so `ManagedSerialStore` fails under it.
- A root run leaves root-owned fixtures at fixed `/tmp` paths and can
  create `/private/tmp`, which turns on macOS-shaped fixtures. A later run
  as an ordinary user then fails 30+ tests. The script runs the suite with
  a private, empty `/tmp` and `/private` hidden, as on a fresh CI VM.

## Hook replay

`Scripts/hook-replay.py`, release build of `rv` and `rvd`. Each call is a
Claude Code `PreToolUse` Bash payload for one of the 1,353 corpus commands
(cycled), with the agent's cwd in a git repository. `rvd` runs with a
throwaway HOME and default config (day-one packs, no judge on Linux).

| Client | Concurrency | Calls | Calls/s | p50 ms | p90 ms | p99 ms | Max ms | Failures |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| socket (rvd only) | 1 | 2,706 | 120 | 5.1 | 26.2 | 31.3 | 53.8 | 0 |
| socket (rvd only) | 8 | 10,000 | 213 | 10.5 | 164.3 | 190.0 | 313.8 | 0 |
| `rv hook` (real path) | 1 | 2,000 | 44 | 20.3 | 40.2 | 52.1 | 77.5 | 0 |
| `rv hook` (real path) | 8 | 10,000 | 130 | 44.4 | 170.7 | 206.3 | 278.9 | 0 |

Every call got an allow or a deny from rvd: no timeouts, no "rvd down"
fallbacks, and no hook-budget (7 s) overrun lines in rvd's log. rvd RSS
went from 49 MB to 65 MB over 10,000 calls; open descriptors stayed flat
(13 to 21 on the socket client, which holds 8 connections).

The `rv` here is the Swift `rv` from `swift build`. Release installs use
the C front door (`Sources/rv-c`), which should start faster; the
socket rows bound what the daemon itself costs.

### Finding: denies serialize under concurrency

| Verdict | Concurrency 1 p50 / p99 ms | Concurrency 8 p50 / p99 ms |
| --- | --- | --- |
| allow | 4.2 / 9.8 | 9.1 / 27.6 |
| deny | 8.0 / 31.8 | 41.3 / 198.1 |

Allows stay fast with 8 agents at once; denies queue. A syscall count on
rvd during a deny-only replay at concurrency 8 (539 replies in 8 s) shows
82% of time in `futex`, and per deny about 3 `fsync`, 4 `rename`, 8
`flock`, 11 `chmod`, 29 `openat` and 65 `newfstatat`. The deny path does
several durable writes under file locks (denial ledger, pending row,
unlock code, audit; see `HookDispatch.swift` and `HookDeadline.swift`).

That is far inside the 7 s budget today, but it grows with the number of
agents denied at once, which is the cloud-agent case.

### Fix 1: pending-approval rows (M3)

`rvd`'s own phase timing (`HookTiming`, logged for every call in a local
experiment) put a deny at concurrency 8 at 112 ms p50, of which 104 ms was
the reply phase. Split further, the unlock-code mint took 0.5 ms and the
pending-approval row 14 ms, growing with the store (9 ms over the first
200 denies, 14 ms over the last 200). `PendingApprovalStore` decoded the
whole file, then re-encoded and rewrote it, on every ask, under an
exclusive lock, and also rewrote it unchanged when an ask reused its
waiting row. Parallel asks queued behind that.

The store now keeps what it last read or wrote, keyed by the file's stamp
(inode, size, mtime, ctime), as `AllowOnceStore` already did. While this
instance wrote the file last, a repeated ask writes nothing, a fresh ask
appends one line, and any other change re-encodes only the rows that
changed. Another writer's save (the CLI's approve, a second process)
changes the stamp: the next call reads the file again, and the next write
after that re-encodes and rewrites every row, as before the fix, after
which the cheap paths apply again. `PendingApprovalStoreScalingTests` pins
the append on the file itself (an ask on a 236-row store keeps the inode
and adds exactly one line), not on a clock; measured, that ask took
16.8 ms before and 1.0 ms after (debug build). Rows this instance wrote
are cached, and returned by the call that wrote them, as read back from
their lines, since the file keeps whole-second dates and review tokens
hash rows across processes (the first version cached the originals and
broke six egress review tests). A rows file that exists but cannot be
read is a store error, never an empty ledger, and is never cached.
"After" numbers are from `eb8032c`.

| Run (release) | p99 before | p99 after | Calls/s before | Calls/s after |
| --- | --- | --- | --- | --- |
| socket, concurrency 1 | 31.3 ms | 12.5 ms | 120 | 176 |
| socket, concurrency 8 | 190.0 ms | 56.9 ms | 213 | 386 |
| `rv hook`, concurrency 1 | 52.1 ms | 25.8 ms | 44 | 55 |
| `rv hook`, concurrency 8 | 206.3 ms | 82.8 ms | 130 | 181 |
| denies only, socket, concurrency 8 (p50) | 112 ms | 42 ms | | |

Still to do: a deny at concurrency 8 is 41 ms p50 against 9 ms for an
allow. What remains on the reply path is the audit append with `fsync`
and the 200-row denial ledger rewrite (`blocks.jsonl`), each under its own
lock, plus analytics counters rewritten with `fsync` on every decision
(in a detached task, so off the reply but not off the disk). rvd RSS after
10,000 calls at concurrency 8 rose from 65 MB to 79 MB with the higher
throughput; a soak run should confirm it levels off.

### Fix 2: denial ledger and analytics writes

After Fix 1 a deny at concurrency 8 still cost several times an allow.
Two per-decision writes did far more work than they needed:

- `DenialLedger.append` (`blocks.jsonl`, the 200-row, 7-day view behind
  `rv blocks`) loaded the whole file, pruned and sorted it, re-encoded
  every row and renamed a new file into place, under `blocks.lock`, on
  every deny. It now keeps what this process last wrote (rows as read back
  from their lines, and the lines), keyed by the file's stamp, as the
  pending store does. While the file is still that, a deny appends one
  line. The file is rewritten only when it would pass 250 rows (200 plus
  `compactionSlack`, 50), holds a row past the 7-day window, or another
  writer changed it. In the first two cases the new file is built from the
  cached lines; after another writer, the file is read back with `load()`
  and every row re-encoded. That writer's rows are kept, and a torn or
  unreadable line is rewritten away, never appended after. `DenialLedger`
  reads (`rv blocks`) are unchanged: newest first, at most 200 rows, none
  older than 7 days; only the file holds up to 250 rows between rewrites.
  Two side effects of the larger file. `rv audit`, its OCSF export and
  `rv audit forward` read `blocks.jsonl` raw (`AuditLedger.events`), not
  through `DenialLedger`, so they can now see up to 50 more, older rows;
  most are dropped again as duplicates of the same deny in `audit.jsonl`,
  and only rows without a chained twin (written before the chain recorded
  denies, or whose audit write failed) show up. And `rv audit forward`
  restarts its `blocks.jsonl` cursor when the file is replaced, which used
  to happen on every deny and now happens on each rewrite: once per 50
  denies at the cap, when a row ages out of the 7-day window, and after
  another writer (an rv process evaluating without rvd) changed the file,
  twice if that writer replaced it.
- `AnalyticsCoordinator` rewrote `analytics-counters.json` (atomic
  replace with `fsync`) twice per decision: once for the count, once for
  a pack list that had not changed. An unchanged pack list now writes
  nothing, and counts reach the file at most once a second
  (`persistDelay`). rvd's own exits (idle, or its binary replaced on
  disk) write pending counts first (`persistPendingNow`, waiting at most
  2 s). A crash or kill can lose up to a second of counts, and so can
  SIGTERM: rvd has no SIGTERM handler, so a stop, restart or upgrade by
  launchd or systemd is that same loss. It is the kind of loss the
  existing best-effort `try?` writes and the detached per-decision task
  already accept. A deferred write never creates the config directory.
  Pack changes, host notes and the daily flush still write at once. rvd's RSS after 10,000 socket calls
  at concurrency 8 fell from 84 MB to 64 MB, which suggests the
  per-decision tasks had been queuing on the coordinator actor.

`DenialLedgerScalingTests` pins the ledger: an append writes in place,
there is one rewrite per 50 rows past the cap with reads capped
throughout, a row past 7 days leaves the file on the next append, another
writer's rewrite or append is kept (also while racing an old-style
writer), and a torn line is rewritten away. It checks writes by inode and
line count, not wall time: the per-deny cost is measured by the
`hook-replay.py` runs below. `AnalyticsCounterPersistenceTests` pins the
counters: 50 decisions leave the file untouched, counts land after the
delay, `persistPendingNow` writes them at once and they survive a
restart, a deferred write does not recreate a removed directory, and a
pack change and the daily flush write at once.

Before is `08b1f53` (Fix 1), after is `fc2cd23`, both release builds, run
back to back for each row, in two rounds. Two other agents were building
on the same 4 vCPUs (load average 2 to 17 during the runs), so absolute
numbers move between rounds; compare within a row. The `rv hook` rows
are dominated by process start-up under that load.

| Run (release) | Round | p50 ms before → after | p99 ms before → after | Calls/s before → after |
| --- | --- | --- | --- | --- |
| socket, concurrency 1 | 1 | 6.4 → 5.1 | 22.8 → 18.1 | 125 → 166 |
| socket, concurrency 1 | 2 | 5.5 → 4.7 | 20.5 → 13.0 | 138 → 186 |
| socket, concurrency 8 | 1 | 26.8 → 18.1 | 106.9 → 65.8 | 223 → 376 |
| socket, concurrency 8 | 2 | 26.5 → 17.2 | 99.2 → 65.3 | 230 → 393 |
| `rv hook`, concurrency 1 | 1 | 18.0 → 15.0 | 25.7 → 23.5 | 55 → 64 |
| `rv hook`, concurrency 1 | 2 | 28.1 → 23.5 | 50.8 → 44.4 | 34 → 41 |
| `rv hook`, concurrency 8 | 1 | 67.2 → 38.1 | 175.6 → 104.8 | 110 → 188 |
| `rv hook`, concurrency 8 | 2 | 64.7 → 60.0 | 160.7 → 176.0 | 116 → 119 |
| denies only, socket, concurrency 8 | 1 | 47.5 → 7.8 | 69.0 → 25.4 | 171 → 904 |
| denies only, socket, concurrency 8 | 2 | 60.4 → 17.0 | 90.1 → 69.8 | 136 → 388 |

By verdict, socket at concurrency 8: deny p50 58.0 → 15.1 ms (round 1)
and 55.7 → 14.5 ms (round 2); allow p50 19.4 → 20.8 and 18.9 → 19.4 ms.
A deny is now no slower than an allow on this path.

What is left: rvd's phase timing on the after build, denies only at
concurrency 8, puts a deny at 7 to 11 ms mean: effects (audit append and
ledger row) 2.8 to 5.4 ms, reply (unlock-code mint and pending row) 1.3
to 1.6 ms, waiting for an offload thread 0.5 to 1.2 ms. A local
experiment that skipped the audit `fsync` (not committed) cut effects to
0.9 to 1.2 ms mean but did not raise throughput or lower the deny p50
(891 and 781 calls/s without it, 926 and 737 with it, run alternately):
the time moved into the reply phase, where the allow-once and pending
stores take their own locks. So the audit `fsync` stays. It is
`AuditLog`'s documented guarantee (a crash cannot drop an append that
already returned true) and is not the bottleneck at this load. If it
becomes one, two changes would keep that guarantee: `fsync` after
releasing the log's locks, so concurrent appends share a journal commit,
or a blocking wait bounded by the same deadline in place of the 2 ms
sleep-poll that `AppendLock` and the `flock` wait use today. The first
changes what a crash can leave behind (more than one unacknowledged line
torn, not only the last), so it needs a decision about the chain
verifier first.

### Corpus agreement

Of the 1,353 corpus commands, 367 got a different verdict from the live
rvd than the corpus pins. The harness reports this and does not fail on
it, because the corpus pins pack-level verdicts while a live rvd also runs
repository and path probes:

- `mcp-host-config` (188) and `catalog-deny-stress` (129): the MCP host
  guard and catalog packs are off in a default config.
- `git push` variants: a live rvd asks for human approval for remote
  branch changes, which is a deny on the wire.
- Writes under `/tmp`: outside the repository, so rv refuses to treat the
  path as in-repo.
- `rm -rf ./build` and similar: allowed live because `./build` does not
  exist in the fixture repository.

A run of the corpus against a config with catalog packs and the MCP guard
on would narrow this to the cases worth reading one by one.

## Reproduce

```sh
Scripts/cloud-test.sh                       # as root in a cloud session
swift build -c release --product rvd && swift build -c release --product rv
Scripts/hook-replay.py --bin-dir .build/release --client socket --calls 10000 --concurrency 8
Scripts/hook-replay.py --bin-dir .build/release --client rv --calls 10000 --concurrency 8
Scripts/hook-replay.py --bin-dir .build/release --client socket --filter deny.json --calls 2000 --concurrency 8
```

`--json FILE` writes the full summary, including latency per corpus file,
the slowest commands, and every disagreement example.
