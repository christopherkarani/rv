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
                                              ├── rv-judge --worker --compute cpu           (primary)
                                              └── rv-judge --worker --compute accelerated   (hedge)
```

- **One binary.** `rv-judge serve` is the supervisor; `rv-judge --worker`
  is a worker. The supervisor never loads a model (`RVJudgePool` does not
  depend on `RVLaya`); the worker is the only code that touches Core ML.
- **Workers by role.** Slots are named by role, `primary` and `hedge`; the
  compute units of each are `PoolPolicy` fields (`primaryCompute`,
  `hedgeCompute`). Live: the primary runs `.cpuOnly` (`cpu`), which never
  enters the MPSGraph path that aborted and has the tighter tail under load
  (see "Measurements"); the hedge runs `.cpuAndGPU` (`accelerated`). Each
  answers one prediction at a time over stdin/stdout: 4-byte big-endian
  length + JSON (`RVIPC.FrameCodec`, 1 MiB cap, empty frames refused). A
  malformed frame kills that worker. A worker runs one throwaway prediction
  before it reports ready: the first prediction after a load is 0.3–0.5 s
  slower than the rest, and no real request should pay it.
- **Compiled models and Core ML guard.** Workers load only through the
  verified compiled-model store (`CompiledModelStore`,
  `~/.config/rv/cache/laya/models`, under the passwd home from `getpwuid`,
  never `$HOME` or argv; `core.secrets:home-rv-config` keeps agents out of
  `~/.config/rv`). The store copies Core ML's compile output out of the
  per-user temp dir, hashes every file into a manifest, and verifies the
  manifest before every load; anything it cannot verify refuses
  (`CoreMLRefusal`). rvd, the CLI and both workers share one store, so it
  is safe across processes: verify, compile, install, sweep and discard run
  under an exclusive `flock` on `models.lock` beside the root (two workers
  warming at once compile once and never remove each other's partial copy
  or half-committed entry), and a process that loaded an entry holds a
  shared `flock` on its manifest for as long as the model lives, so the
  sweep of superseded entries (an updated bundle or OS) skips one another
  worker still has loaded. Each worker binds its own `CoreMLGuard` with its
  own in-flight marker and crash history (`guard-cpu`, `guard-accelerated`
  next to rvd's `guard`): one worker's Core ML crashes switch only that
  worker to CPU only, and the CPU worker is pinned to CPU whatever its
  history says. A SIGKILL the supervisor sends itself (budget overrun,
  garbage on stdout) is not a Core ML crash: after reaping that worker and
  before its replacement starts, the supervisor clears its marker (only
  when no live process holds the marker's lock; otherwise the kill counts,
  which only moves that worker to CPU). A refusal (disk nearly full, a
  model it could not verify, a load that failed after the store's retry) is
  a `loadFailed` row, which rvd answers with review.
- **Spawn.** `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT` (only the two
  pipe ends and stderr are inherited), SIGPIPE reset to default in the child,
  a fixed environment (HOME, USER, LOGNAME, TMPDIR, a fixed PATH). A worker
  pid is signalled only before it is reaped (`waitid(WNOWAIT)` first), so a
  reused pid is never killed. A write to a dead worker's pipe cannot raise
  SIGPIPE (Darwin: `F_SETNOSIGPIPE` on the pipe; Linux: blocked on that
  thread for the write); the spawner does not change the process-wide
  disposition.
- **Logs.** launchd gives the agent stderr on `/dev/null`; the supervisor
  points it at `~/Library/Logs/rv/judge.log`, opened `O_NOFOLLOW |
  O_NONBLOCK` and kept only when `fstat` says it is a regular file (a FIFO or
  device planted there is refused without blocking), 0600, rotated past
  1 MiB. Lines are written with one `write(2)` whose errors are ignored, so a
  full disk or a closed stderr cannot raise or stall the supervisor. Workers
  inherit it, so a Core ML abort lands there. rv writes only lifecycle
  lines, never a command or a verdict.

## Routing (`PoolCore`, `PoolPolicy`)

`PoolCore` is a pure state machine (events in, effects out, injected
clock); `JudgePoolSupervisor` performs the effects on one serial queue.

| Constant | Value | Meaning |
|---|---|---|
| `primaryCompute` / `hedgeCompute` | `cpu` / `accelerated` | Compute units per role |
| `hedgeAfter` | 150 ms | The primary has not answered: send the request to the hedge too; first answer wins. Above the CPU p99 under load |
| `primaryBusyWait` | 40 ms | A request that finds a healthy primary busy waits this long for it before going to the hedge (about one CPU p95 under load) |
| `budget` | 1.5 s | The most a request waits, and the most a worker may spend on one prediction before SIGKILL |
| `queueLimit` | 8 | Waiting requests; one more is refused at once (`busy`) |
| `backoffBase` / `backoffCap` | 250 ms doubling / 30 s | Respawn delay after a fault, reset when a worker loads |
| `faultsToDegrade` in `faultWindow` | 3 in 300 s | A worker with that many faults (crash, overrun kill, load timeout) is out of rotation for `degradeCooldown` (600 s) |
| `loadTimeout` | 180 s | A first load compiles the model; past this the loader is killed (a fault) |
| `loadFailureRetry` | 60 s | A worker that reported the bundle unloadable is not respawned sooner |
| `keyChangeInterval` | 10 s | After the model key changes, another change is refused this long |

- A request carries an id, the input, and an answer-by time
  (`min(budget, caller budget)`). It goes to the primary when the primary is
  idle. When the primary is busy but healthy, the request waits up to
  `primaryBusyWait` for it, then goes to the hedge, so a burst does not land
  on the slower hedge at once. A primary that is down or degraded sends
  requests to the hedge without waiting.
- A worker still busy at `budget` after it was sent the request is killed
  and respawned. The kill uses the pool budget, not a shorter client
  deadline: a client that gives up early gets `late`, but the worker is
  not killed for answering in normal time.
- A crash mid-request moves the request to the other worker if it has not
  tried it; otherwise the request fails (`failed`).
- Workers load one at a time, the primary first, so two cold compiles never
  compete.
- Routing as doctor shows it: `hedged`; `hedge only (primary degraded)`;
  `unhedged (hedge degraded)`; `none (both workers degraded)`, where the
  pool answers `failed` at once.
- A request for a different model (engine or bundle path) restarts both
  workers on it; requests in flight for the old model get `warming`. Fault
  history, degradation and backoff stay with each slot, so a key change
  cannot launder a crash-looping worker back into rotation (only a load
  failure, which was about the old bundle, is cleared). A second change
  within `keyChangeInterval` is refused (`failed`, so review) and `warm`
  ignores it: a client alternating keys cannot keep both workers reloading.

**The hedge is always warm.** Hedging only helps if the hedge can answer
inside the 1.5 s budget, and a cold worker needs 1–4 s to load, so a lazily
started hedge would turn every primary fault into a review prompt instead of
an answer. The pool keeps both workers loaded.

## rvd side

- `RVDProcess` (macOS) binds `XPCJudgeClient` at startup
  (`JudgeRuntime.bindClient`). With a client bound, `LiveJudgePort` never
  runs the in-process judge: no fallback, so killing the pool cannot move
  rvd back onto the crash-prone path. `rv test` and the bench CLI keep the
  in-process judge (`JudgeSlot`, its `NSLock`), since they have no pool.
  Known difference: when the bundle fails to load, `rv test` shows the
  in-process path's packs-only result, while the live hook gets review.
- The client keeps one verified connection. The budget sent is computed
  after the connection is obtained: `min(1.5 s, hook deadline − now − 400 ms
  − 250 ms transport slack)`; nothing left is `late` without asking. The
  connection is dropped only on an XPC error, a verification failure, or a
  malformed or refused reply, never on a timeout (a slow answer is not a
  broken supervisor). Every new connection is sent `warm` for the last
  model, and after a connection breaks the client reconnects and re-warms
  in the background (1, 2, 4, 8, 16 s), so a restarted supervisor loads
  before the next judged call.
- Mapping (`JudgeRuntime.read(_: PoolOutcome?)`):

| Pool answer | `JudgeRun` | Gate result |
|---|---|---|
| verdict that decodes and is well formed | `.verdict` | thresholds as before |
| verdict that is malformed, has a missing probability, or a score outside [0, 1] or not finite | `.failed` | review (`prediction-failed`) |
| `busy` | `.busy` | review (`judge-busy`) |
| `late` | `.late` | review (`judge-late`) |
| `warming` | `.warming` | review (`judge-warming`) |
| `failed` | `.failed` | review |
| `loadFailed` (a worker could not load the bundle, or its guard refused) | `.refused` | review (`judge-refused`) |
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
  under a managed manifest (`Scripts/phase2a-development-trust.sh install
  … --judge PATH` emits one for development). `rv doctor` reports the pool
  as unreachable or unverified.
- The sibling CDHash is cached per file identity (device, inode, size,
  mtime and ctime to the nanosecond); a rewrite or replacement hashes again.
- Before each spawn the supervisor compares the on-disk `rv-judge`'s CDHash
  with its own running code (`SecCodeCopySelf`), not only the file identity.
- The C hook validates a `judge` entry like Swift does (it is a known role in
  `daemon_trust.c`), though the hook itself never talks to the pool.
- Every message on the listener is authorized before it is read; the Mach
  service connection only performs the hello and hands out an anonymous
  endpoint, and requests are refused on any connection that has not
  completed the versioned hello (protocol 2). Every reply rvd reads is
  authenticated first. `judge` is a role that proves supervisor identity and
  nothing else: rvd denies it every control, launch and TTY attestation.
- `rv-judge` and `dev.rv.judge.plist` are install files the self-protection
  floor guards, like `rvd` and `dev.rv.evaluate.plist`.

## Lifecycle

- `rv setup` writes `~/Library/LaunchAgents/dev.rv.judge.plist`
  (`RunAtLoad`, `KeepAlive`, `ThrottleInterval` 5, Mach service
  `dev.rv.judge`) when `rv-judge` is installed beside rvd, and bootstraps it
  before rvd, so rvd's first judged call finds the pool. A missing
  `rv-judge` or a refused bootstrap does not stop setup (rvd's judged calls
  then go to review); with a judge bundle installed, setup warns. `rv
  service restart` does not touch it. `rv uninstall` boots it out of both
  launchd domains and removes the plist.
- rvd asks the pool to warm the configured model at startup.
- Upgrade: the supervisor checks its executable's identity every 30 s and
  before each spawn. When the file changed it exits, and launchd restarts it
  from the new bytes, so workers are never spawned from bytes newer than the
  supervisor.
- `install.sh` installs `rv-judge` when the release carries it (releases
  before this one do not); `sign-macos.sh` signs it with the other binaries,
  since rvd pins it by CDHash. The release workflow checks its load commands
  are macOS 15 like the other binaries.

## Doctor

rvd's doctor snapshot has a `judgePool` check: per worker its role, compute
units, phase, restarts, degraded state and load failure, the routing, and
counters (served, hedged, killed, late, busy). Unreachable or unverified is a
warning when a judge bundle is installed (without one nothing is judged and
nothing is reported), as is a degraded or unloadable worker.

`rv doctor`'s human output lists rvd's `judge` and `judgePool` warnings as
problems. On macOS, with a judge bundle installed, it also checks that
`rv-judge` sits beside rvd, the plist exists, and the job is loaded; that row
replaces the unreachable-pool warning it explains. All are warnings: judged
calls go to review, never to allow.

## Measurements

Release `rv-judge --worker`, `laya-ft-v2-coreml` (614 MB fp16 weights), Apple
silicon development machine (14 cores), isolated HOME, 300 requests over 20
commands (`ls -la` to `aws s3 rm … --recursive`), 50 ms apart, one process
per run. "Loaded" ran beside a clean release `swift build` (load average
23–37).

| Worker | Machine | Load | p50 | p95 | p99 | max | `phys_footprint` |
|---|---|---|---|---|---|---|---|
| `cpu` | idle | 4.5 s | 8.5 ms | 19.5 ms | 24.5 ms | 29.7 ms | 170 MB |
| `accelerated` | idle | 3.7 s | 9.8 ms | 286.3 ms | 313.0 ms | 353.5 ms | 347 MB |
| `cpu` | loaded | 1.2–4.3 s | 7.6–12.0 ms | 19.4–33.5 ms | 26.2–66.6 ms | 362–479 ms (first request) | 196–256 MB |
| `accelerated` | loaded | 2.9 s | 11.1 ms | 335.1 ms | 536.4 ms | 720.6 ms | 444 MB |

With the warm-up prediction and the private cache (cold compile into a fresh
directory, load includes the warm-up, load average 13–59):

| Worker | Load | p50 | p95 | p99 | max | `phys_footprint` |
|---|---|---|---|---|---|---|
| `cpu` | 3.8 s | 7.4 ms | 17.2 ms | 18.7 ms | 22.3 ms | 183 MB |
| `accelerated` | 3.4 s | 9.9 ms | 274.4 ms | 291.1 ms | 298.7 ms | 748 MB |

- The CPU worker's p95 under load is far under 300 ms, so it is the primary
  and the GPU only hedges. `hedgeAfter` (150 ms) sits above the CPU p99
  under load; `primaryBusyWait` (40 ms) is about one CPU p95 under load.
- The GPU tail comes from the first prediction on each new input shape (the
  GPU path compiles per shape); it is why the GPU no longer answers first.
- The 0.36–0.48 s first-request tail of the loaded CPU runs is gone with the
  warm-up prediction (max 22 ms).
- Loads are not measured under memory pressure, and the in-production
  `MPSGraphTensorData` abort and LLVM `ENOSPC` were not reproduced here; the
  kill and crash paths are covered by the fake-worker tests
  (`PosixWorkerPoolTests`: a real `kill -9` mid-request, a real hang).

## Not done here

- #623 (budget breaker) and #625 (Core ML guard, verified store) are folded
  in: pool runs go through the same `JudgeCircuit` as the in-process judge
  (`unreachable` and `late` count against it, `refused` is neutral), and
  workers load through #625's store as described above.
