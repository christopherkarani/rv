# rv-c — C front door

`rv` (the installed front door) is C, not Swift. It locates and execs the
installed `rv-cli` sibling for operator commands. Authority-bearing hooks
verify the daemon before any reply field is consumed (`daemon_trust.{h,c}`):
Darwin checks every XPC reply's sender against the root trust manifest's
`.service` role, or — with no manifest installed — pins it to the exact
sibling `rvd` bytes; Linux requires a same-uid `SO_PEERCRED` peer whose
`/proc/<pid>/exe` is the sibling `rvd`, verified before sending. Manifest
entries with a role this build does not know (written by a newer RV) are
skipped; known roles keep every check. Operator/help commands still
execute the installed sibling CLI.

## When rvd gives no verdict

Budgets: each Hello exchange 3000 ms (covers a launchd cold spawn), the
hookEvaluate exchange 8000 ms (rvd enforces its own shorter deadline).
A transient failure before the hookEvaluate request is sent (timeout, XPC
connection invalid/interrupted, `ENOENT`/`ECONNREFUSED` on Linux) retries
the whole sequence once after 200 ms; the request itself is never resent.

Every failure is classified and rendered by `hook_fallback.{h,c}` with a
distinct, actionable message. Nothing ever replays to `rv-cli`.

| Class | Cause | Rendering |
|---|---|---|
| `input` | stdin unreadable, over 1 MiB, NUL, invalid UTF-8, request build failure | host deny, always |
| `unreachable` | service not registered / connection invalid / refused / missing socket | per `RV_HOOK_WHEN_DOWN` |
| `timeout` | an exchange exceeded its budget | per `RV_HOOK_WHEN_DOWN` |
| `untrusted` | daemon identity check failed, HelloAck not ok / skew | per `RV_HOOK_WHEN_DOWN` |
| `protocol` | bad reply JSON, id mismatch, version skew | per `RV_HOOK_WHEN_DOWN` |

`RV_HOOK_WHEN_DOWN` (read from the hook's environment):

- `ask` (default; also any unrecognized value): Claude and Cursor get their
  native ask wire (exit 0) so the human decides in the host; hosts without
  an ask primitive get their deny shape.
- `deny`: the host's deny shape and deny exit code (Codex: `decision:
  block` + stderr + exit 2; Pi/OpenCode/OpenClaw/Hermes exit 1; others 0).
- `allow`: empty stdout, exit 0 — defers to the host's own permission
  system. It is never an RV allow verdict.

The Swift hook path (`RVCLI/Service/HookDaemonFallback.swift`, used for
hosts not piped here) mirrors the classes, messages and modes.

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
| `hook_fallback.{h,c}` (daemon-miss rendering) | `RVCLI/Service/HookDaemonFallback.swift` | Same messages (`HookDaemonFallbackTests` reads `hook_fallback.c`), same `RV_HOOK_WHEN_DOWN` modes; Swift deny reuses the host codecs. |
| `daemon_trust.{h,c}` (daemon-identity verification) | `RVService/XPCEvaluateClient.swift` + `RVIsolation/WorkspacePeerAuthenticator.swift` (`MacOSPeerCodeVerifier`, `ProtectedPeerTrustConfiguration.hookTrustSource`) | Same trust decision: valid manifest requires `.service`; missing manifest pins sibling `rvd` (hook consult only); invalid manifest fails closed; unknown-role entries are skipped (`tests/daemon_trust_test.c` ↔ `PeerTrustManifestParseTests`). Linux has no Swift transport; C is the reference. |

## Test entry points

- `tests/run.sh` — C unit tests + process proofs (argv forging, host-compatible no-replay denials,
  bounded stdin, broken sibling, SIGPIPE, daemon-down `RV_HOOK_WHEN_DOWN` rendering). Runs in PR
  CI on Linux and macOS.
- `Scripts/c-hook-proof.sh` + `Tests/RVCLITests/CHookPipeTests.swift` —
  end-to-end proof against staged release binaries.
- `Tests/RVIPCTests/EvaluationRouteTests.sharedVectorsMatchCImplementation` —
  Swift side of the shared-vectors parity lock.
