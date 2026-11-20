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
agents denied at once, which is the cloud-agent case. Candidate work for
M3: one append per deny instead of several rename-and-fsync rewrites, or
moving the non-decision writes off the reply path.

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
```

`--json FILE` writes the full summary, including latency per corpus file,
the slowest commands, and every disagreement example.
