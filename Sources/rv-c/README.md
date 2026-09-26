# rv-c — C front door

`rv` (the installed front door) is C, not Swift. It locates and execs the
installed `rv-cli` sibling, fast-paths hook evaluation over XPC (Darwin) or
AF_UNIX (Linux), and replays (miss) to `rv-cli` on anything unexpected:
NUL bytes, oversize input, dead child, missing sibling. Fail-closed: every
miss path exits 2 (deny), never 0.

Not an SPM target by design (plain `clang -std=c11`). Constraints, all
enforced by `tests/run.sh`:

- Apple Silicon + macOS 15 floor, or Linux aarch64/x86_64.
- `-Wall` clean. No Foundation/CFNetwork linkage (Darwin).
- `is_valid_host` must match `HookHost.setupSlotOrder` or a missing host
  silently misses as operator.

## Swift mirrors — change both, or change the vectors

| C | Swift | Contract |
|---|---|---|
| `evaluation_route.h` (`rv_semver_major`, `rv_should_miss_replay`) | `RVIPC/EvaluationRoute.swift` + `ProtocolVersion.major(of:)` | `tests/evaluation_route_vectors.tsv` drives BOTH harnesses. Add cases there; never fork per-side cases. |
| `json_reply.{h,c}` (hook-reply decode, recursion-capped) | `RVIPC/IPCEvaluate.swift` (`EvaluateReply`: `via` must be `"xpc"`) | Same wire rule: unexpected shape, `result.error`, missing `via`, or `via != "xpc"` is MISS. |
| `json_escape.{h,c}` (request JSON building) | `RVIPC/IPCJSON.swift` + hook request encoders | Byte-level JSON escaping; covered by `json_escape_test.c`. |

## Test entry points

- `tests/run.sh` — C unit tests + process proofs (argv forging, NUL replay,
  bounded stdin, broken sibling, SIGPIPE). Runs in PR CI on Linux and macOS.
- `Scripts/c-hook-proof.sh` + `Tests/RVCLITests/CHookPipeTests.swift` —
  end-to-end proof against staged release binaries.
- `Tests/RVIPCTests/EvaluationRouteTests.sharedVectorsMatchCImplementation` —
  Swift side of the shared-vectors parity lock.
