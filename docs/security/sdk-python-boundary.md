# Python SDK service boundary

Last updated: 2026-09-30. The `rv-sdk` wheel (`sdk/python`) is an intent-only
client of `rvd` over `rv.ipc.v1`. It constructs typed intents and relays opaque
handles; identity, authority, and enforcement stay in Swift. Normative contract:
`sdk/WIRE.md`. Version policy: `sdk/VERSIONING.md`.

## What the SDK can and cannot do

The SDK speaks the same 12 methods as the first-party CLI (`evaluate`,
`hookEvaluate`, `explain`, `classify`, `listPacks`, `setPackEnabled`,
`doctorSnapshot`, `pendingList`, `pendingWatch`, `pendingResolve`, `rulePreview`,
`ruleSave`). A same-user Python process gains no authority it could not already
obtain by speaking the protocol directly; the SDK adds ergonomics, not privilege.
`hookEvaluate` is raw-only (host adapters stay Swift/C); there are no
session/exec/PTY, secrets, MCP, or supervisor APIs because `rvd` exposes none.

The SDK contains no evaluator and no fallback verdict path. Skew, an unreachable
service, or an unprovable version is a hard typed error, never a locally computed
verdict — a deliberate divergence from `ServiceClient`'s in-process fallback,
which a non-Swift client must not emulate.

## The v1 trust root is the OS user boundary

- Transports: owner-only AF_UNIX sockets (`0600` socket, `0700` `rv` dir,
  base dir owned and not group/world-writable, all checked by the SDK and
  never repaired), same-UID peers (filesystem identity plus the `getpeereid`
  gate on the macOS listener), no `/tmp` fallback, `sockaddr_un` length caps,
  post-connect inode re-verify.
- Requests carry no principal fields: no owner, definition authority, instance,
  session authority, workspace authority, approval, or `trusted` status. The
  wire has nowhere to put them and the curated API has no such parameters.
- Approval resolution echoes the service-minted id, fingerprint, and identity
  verbatim; the ledger re-verifies all three and resolves terminal-once.
  `sessionSuffix` is display-only and is never sent.
- Curated gating: `pending_resolve` only resolves items from the approvals
  iterator; `rule_save` only persists drafts from `rule_preview`;
  `set_pack_enabled` is marked operator-only. These are ergonomics — the service
  re-enforces every invariant.

## Residuals and hardening backlog (not v1 blockers)

- `rvd` IPC authenticates callers at same-user granularity only. Per-client
  capabilities (peer audit tokens, per-connection grants) would be a service-wide
  project affecting the CLI and C front door too, not a Python-only change.
- The pre-existing Linux listener does not peer-check; the new macOS listener
  does (`getpeereid`). Filesystem modes remain the Linux boundary.
- A socket swap-and-restore inside the check-connect race window is a residual
  same-user risk (pre/post inode checks narrow it to a microsecond race).
- The service impersonation story is socket identity (pinned path, modes, owner,
  version attestation), not cryptographic peer authentication.
- Executable attestation below this boundary is unenforced
  (`ExecutableAssurance` is `.unattested`/`.launchObserved`); the SDK launches
  nothing and claims no attestation.
- `ensure_runtime` spawns a supervised `rvd` only when explicitly called. Two
  daemons racing the same socket path last-writer-wins the bind (same as the
  Linux behavior); both serve identical methods over shared file-backed stores.

## Regression coverage

`sdk/python/tests/test_security.py` (scripted fail-closed suite) and the live
forgery cases in `sdk/python/tests/test_integration.py` pin: forged approval
ids, tampered fingerprints/identities echoed verbatim, double-resolve terminal
errors, fresh request ids, downgrade-as-hard-error, unknown shapes rejected,
wrong-mode sockets refused without repair, cross-uid refusal, and eager local
validation (`cwd`, packs) that sends nothing.
