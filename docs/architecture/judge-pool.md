# Judge worker pool (`dev.rv.judge`)

On macOS the Laya judge runs outside rvd: in two worker processes owned by a
supervisor that launchd keeps alive. rvd asks the supervisor over XPC and
maps every answer that is not an authenticated, well-formed verdict to
review. Linux is unchanged (no Core ML, packs only).

## Why

The judge ran inside rvd behind an `NSLock` and a one-slot semaphore
(`JudgeAdmission`). Field logs showed what that costs:

- 6× `MPSGraphTensorData` assertion aborts and 5× LLVM `ENOSPC` crashes
  inside Core ML, each one killing rvd and every hook waiting on it;
- a corrupt e5rt compile cache that made every later load fail;
- judged calls queued behind one model: p99 19.3 s against an 8 s hook
  client timeout, so a burst read as "rvd is down".

A Core ML prediction cannot be cancelled. The only way to bound one is to
run it in a process that can be killed.

## Shape

```
hook ──XPC──▶ rvd ──XPC (dev.rv.judge)──▶ rv-judge serve (supervisor, no Core ML)
                                              │ posix_spawn, pipes, length-prefixed JSON
                                              ├── rv-judge --worker --compute accelerated   (A)
                                              └── rv-judge --worker --compute cpu           (B)
```

- **One binary.** `rv-judge serve` is the supervisor; `rv-judge --worker`
  is a worker. The supervisor never loads a model (`RVJudgePool` does not
  depend on `RVLaya`); the worker is the only code that touches Core ML.
- **Workers.** A loads with the production compute units (`.cpuAndGPU`,
  named `accelerated`); B with `.cpuOnly`, which never enters the MPSGraph
  path that aborted. Each answers one prediction at a time over stdin/stdout:
  4-byte big-endian length + JSON (`RVIPC.FrameCodec`, 1 MiB cap, empty
  frames refused). A malformed frame kills that worker.
- **Spawn.** `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT` (only the two
  pipe ends and stderr are inherited), SIGPIPE reset to default in the child,
  a fixed environment (HOME, USER, LOGNAME, TMPDIR, a fixed PATH). A worker
  pid is signalled only before it is reaped (`waitid(WNOWAIT)` first), so a
  reused pid is never killed.
- **Logs.** launchd gives the agent stderr on `/dev/null`; the supervisor
  points it at `~/Library/Logs/rv/judge.log` (0600, `O_NOFOLLOW`, rotated
  past 1 MiB). Workers inherit it, so a Core ML abort lands there. rv writes
  only lifecycle lines, never a command or a verdict.

## Routing (`PoolCore`, `PoolPolicy`)

`PoolCore` is a pure state machine (events in, effects out, injected
clock); `JudgePoolSupervisor` performs the effects on one serial queue.

| Constant | Value | Meaning |
|---|---|---|
| `hedgeAfter` | 450 ms | A has not answered: send the request to B too; first answer wins |
| `budget` | 1.5 s | The most a request waits, and the most a worker may spend on one prediction before SIGKILL |
| `queueLimit` | 8 | Waiting requests; one more is refused at once (`busy`) |
| `backoffBase` / `backoffCap` | 250 ms doubling / 30 s | Respawn delay after a fault, reset when a worker loads |
| `faultsToDegrade` in `faultWindow` | 3 in 300 s | A worker with that many faults (crash, overrun kill, load timeout) is out of rotation for `degradeCooldown` (600 s) |
| `loadTimeout` | 180 s | A first load compiles the model; past this the loader is killed (a fault) |
| `loadFailureRetry` | 60 s | A worker that reported the bundle unloadable is not respawned sooner |

- A request carries an id, the input, and an answer-by time
  (`min(budget, caller budget)`). It goes to A when A is idle, else to B.
- A worker still busy at `budget` after it was sent the request is killed
  and respawned. The kill uses the pool budget, not a shorter client
  deadline: a client that gives up early gets `late`, but the worker is
  not killed for answering in normal time.
- A crash mid-request moves the request to the other worker if it has not
  tried it; otherwise the request fails (`failed`).
- Workers load one at a time, A first, so two cold compiles never compete.
- With A degraded, everything routes to B (`cpu-only`); with B degraded,
  A runs unhedged; with both degraded the pool answers `failed` at once.
- A request for a different model (engine or bundle path) restarts both
  workers on it; requests in flight for the old model get `warming`.

**B is always warm.** Hedging only helps if B can answer inside the 1.5 s
budget, and a cold B needs 1–4 s to load, so a lazily started B would turn
every A fault into a review prompt instead of a B answer. Loaded, B costs
about 180–256 MB (see "Measurements"), so the pool keeps both workers
loaded.

## rvd side

- `RVDProcess` (macOS) binds `XPCJudgeClient` at startup
  (`JudgeRuntime.bindClient`). With a client bound, `LiveJudgePort` never
  runs the in-process judge: no fallback, so killing the pool cannot move
  rvd back onto the crash-prone path. `rv test` and the bench CLI keep the
  in-process judge (`JudgeSlot`, its `NSLock`), since they have no pool.
- The budget sent is `min(1.5 s, hook deadline − now − 400 ms − 250 ms
  transport slack)`; nothing left is `late` without asking.
- Mapping (`JudgeRuntime.read(_: PoolOutcome?)`):

| Pool answer | `JudgeRun` | Gate result |
|---|---|---|
| verdict that decodes and is well formed | `.verdict` | thresholds as before |
| verdict that is malformed, has a missing probability, or a score outside [0, 1] or not finite | `.failed` | review (`prediction-failed`) |
| `busy` | `.busy` | review (`judge-busy`) |
| `late` | `.late` | review (`judge-late`) |
| `warming` | `.warming` | review (`judge-warming`) |
| `failed` | `.failed` | review |
| `loadFailed` (a worker could not load the bundle) | `.failed` | review |
| no authenticated answer (not running, refused, unverifiable, past the deadline) | `.unreachable` | review (`judge-unreachable`) |

Every row but a verdict is review. A missing bundle never reaches the pool:
rvd decides that first (`engine-missing`, packs-only, as before). A bundle
that is present but fails to load in the worker is review, not the in-process
path's packs-only floor: the failure can be induced (a full disk, a corrupt
compile cache), and the floor would make it an unjudged allow. The
`judgePool` doctor check names the load failure, and the worker retries the
load every 60 s.

## Trust

Both directions use the hook-consult mechanisms (`MacOSPeerAuthenticator`
on each message's audit token, `ProtectedPeerTrustConfiguration`):

| Trust source | Supervisor accepts a client when | rvd accepts the supervisor when |
|---|---|---|
| Installed peer-trust manifest | its live code satisfies the `service` entry (rvd) | its live code satisfies the `judge` entry |
| No manifest (one-click install) | same euid and exact on-disk bytes of `rvd` beside `rv-judge` (canonical path + CDHash) | same euid and exact bytes of `rv-judge` beside `rvd` |
| Manifest present but invalid | never | never |

- **A manifest without a `judge` entry verifies no supervisor.** rvd then
  treats the pool as unreachable and every judged call goes to review; it
  does not fall back to a sibling pin or to the in-process judge. Add a
  `judge` entry for `rv-judge` to the manifest before installing this build
  under a managed manifest. `rv doctor` (`judgePool`) reports the pool as
  unreachable or unverified.
- The C hook validates a `judge` entry like Swift does (it is a known role in
  `daemon_trust.c`), though the hook itself never talks to the pool.
- Every message on the listener is authorized before it is read; the Mach
  service connection only performs the hello and hands out an anonymous
  endpoint, and requests are refused on any connection that has not
  completed the versioned hello. Every reply rvd reads is authenticated
  first. `judge` is a role that proves supervisor identity and nothing else:
  rvd denies it every control, launch and TTY attestation.
- `rv-judge` and `dev.rv.judge.plist` are install files the self-protection
  floor guards, like `rvd` and `dev.rv.evaluate.plist`.

## Lifecycle

- `rv setup` writes `~/Library/LaunchAgents/dev.rv.judge.plist`
  (`RunAtLoad`, `KeepAlive`, `ThrottleInterval` 5, Mach service
  `dev.rv.judge`) when `rv-judge` is installed beside rvd, and bootstraps it.
  `rv service restart` does not touch it. `rv uninstall` boots it out of
  both launchd domains and removes the plist.
- rvd asks the pool to warm the configured model at startup.
- Upgrade: the supervisor checks its executable's identity every 30 s and
  before each spawn. When the file changed it exits, and launchd restarts it
  from the new bytes, so workers are never spawned from bytes newer than the
  supervisor.
- `install.sh` installs `rv-judge` when the release carries it (releases
  before this one do not); `sign-macos.sh` signs it with the other binaries,
  since rvd pins it by CDHash.

## Doctor

rvd's doctor snapshot has a `judgePool` check: per worker its compute units,
phase, restarts, degraded state and load failure, the routing, and counters
(served, hedged, killed, late, busy). Unreachable or unverified is a warning,
as is a degraded or unloadable worker.

## Measurements

Release `rv-judge --worker`, `laya-ft-v2-coreml` (614 MB fp16 weights), Apple
silicon development machine, isolated HOME, 40 requests over 10 commands
(`ls -la` to `curl … | sh`), one process per run:

| Worker | Load (cold compile / warm cache) | p50 | p95 | max | `phys_footprint` (peak) |
|---|---|---|---|---|---|
| A `accelerated` | 2.7 s | 6.1 ms | 335.7 ms | 338.4 ms | 346 MB (655 MB) |
| B `cpu` | 4.3 s / 1.1 s | 6.1–7.7 ms | 16.7–22.8 ms | 23.6 ms | 180–256 MB (280 MB) |

- B costs about 180–256 MB of physical footprint once loaded (A: 346 MB,
  150 MB of it graphics memory), so keeping it warm is cheap next to what
  it buys: an answer within the budget whenever A
  crashes, hangs or is degraded. A cold B would need 1–4 s, past the 1.5 s
  budget.
- A's tail comes from the first prediction on each new input shape (the
  GPU path compiles per shape); `hedgeAfter` at 450 ms sits above that
  measured p95, so a healthy A is rarely hedged and a stuck one is covered
  by B well inside the budget.
- Loads are not measured under memory pressure, and the in-production
  `MPSGraphTensorData` abort and LLVM `ENOSPC` were not reproduced here; the
  kill and crash paths are covered by the fake-worker tests
  (`PosixWorkerPoolTests`: a real `kill -9` mid-request, a real hang).

## Not done here

- `rv doctor`'s human output does not print rvd's snapshot checks today
  (neither `judge` nor `judgePool`); the check is in the snapshot only.
- Two open PRs land separately and are folded in on rebase:
  - #623 (budget breaker): its `JudgeAdmission` budget and circuit breaker
    wrap this client; pool `busy`/`late` map to its outcomes.
  - #625 (`.cpuOnly` fallback, `CoreMLGuard`, versioned compiled-model
    store): the guard binds per worker process with a per-slot marker, so
    A's crash history drives only A's compute units; a SIGKILL the
    supervisor sends on a budget overrun must not count as a Core ML crash
    (the supervisor clears that slot's marker after its own kill); and the
    store's sweep must not remove the entry the other worker has loaded.
