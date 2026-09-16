# Factory status

Living board for implement sessions. Do **not** re-grill.

**Agent entry:** `AGENTS.md` → this file → relevant skill → `tools/gate.sh`

## Board

| | Ticket | Notes |
|---|---|---|
| Done | T0–T9 | Scaffold through catalog + `rv packs`. Allow-once and doctor live. |
| Done | maint | Operator-surface seams (setup analytics, ceremony snapshot, robot format). |
| Done | T10–T14 | Merged to `feat/t10-t14-size-speed` (PR #36 draft). One-shot evaluate refuses major-semver-skewed `rvd`. Spec: [`specs/phase-5-size-speed.md`](specs/phase-5-size-speed.md). |
| Done | C hook T1–T5 | Implemented on `feat/c-hook-pipe` (PR #43). C `rv` pipes `hookEvaluate` to `rvd`; miss execs `rv-cli`. |
| Done | session scan T1–T10 | `rv scan` / `rv scan sessions` session forensics. Fence: [`specs/phase-4-session-scan.md`](specs/phase-4-session-scan.md). |
| Done | Claude CL-T1–T5 | Codec, dispatch, settings merge, doctor, MODULES. Spec: [`specs/claude-host.md`](specs/claude-host.md). |
| Done | OpenClaw host (OPE-266) | Spend-first Ask. `HookHost.openclaw`, `before_tool_call` / `exec`, exclusive `~/.openclaw/extensions/rv-guard/`, plugin-owned wait then spend. Never `requireApproval`. Fail-closed sqlite scan. |
| Done | Hermes host (OPE-265) | Spend-first Ask. `HookHost.hermes`, `pre_tool_call` / `terminal`, exclusive `~/.hermes/plugins/rv-guard/`, confirm then spend. Never `action:approve`. |
| Next | Claude CL-later-ask | Fenced: never emit official `permissionDecision: "ask"` (leftover-ask-as-permit). Host Ask is wrapper confirm-then-spend. |
| In progress | File-tool secrets | W1 file door landed. W2: `normal`/`strict`, `secret.allow_paths`, denial-only `rv blocks`. Grep / MCP still forbidden. |
| Overlay | Guard maturity | Honor [`docs/architecture/never-slip.md`](../architecture/never-slip.md) + [`residual-risk.md`](../architecture/residual-risk.md). Does not start OPE-156. |
| Next | Claude CL-later-mcp | Fenced: MCP tool-name / args policy. Not started. |

`docs/factory/PLAN.md` wins product-law conflicts. It is a conflict arbiter, not mandatory full session-start reading.

## Specs (landed)

| File | State |
|---|---|
| `specs/phase-0-repo.md` | Landed |
| `specs/phase-1-engine.md` | Landed |
| `specs/phase-1b-ux.md` | Landed |
| `specs/phase-1c-service.md` | Landed |
| `specs/phase-1d-hosts.md` | Landed |
| `specs/phase-2-packs.md` | Landed |
| `specs/phase-3-allow.md` | Landed |
| `specs/phase-4-later.md` | Landed (fence only) |
| `specs/phase-4-session-scan.md` | Implemented (T1–T10). Session forensics `rv scan`. |
| `specs/phase-5-size-speed.md` | Implementing (T10–T14) |
| [`specs/claude-host.md`](specs/claude-host.md) | Implemented (CL-T1–T5). File-tool secrets in progress. Fenced later: CL-later-ask, CL-later-mcp. |
| [`specs/cli-thin.md`](specs/cli-thin.md) | Implemented (CL1, CL3, CL4) on `feat/cli-thin` (#150). CL2 withdrawn (`HookRun` gone; do not fold miss into `HookDoor`). |

## Parallel rules (reminder)

| Wave | Tickets | Worktree? |
|---|---|---|
| Done | T0 → T1 serial; T2 ∥ T3; T4 then T5; T6; T7; T8 ∥ T9 | — |
| Done | T10 ∥ T11 ∥ T12 ∥ T13; then T14 (after T11) | Separate worktrees; exclusive files in the Phase 5 spec |
| Done | session scan T1; then T2; then T3 ∥ T4 ∥ T5; then T6; then T7; then T8; then T9; then T10 | `rv scan` / `rv scan sessions` |
| Done | C-hook T1; then T2 ∥ T3; then T4; then T5 | C hook pipe + Swift miss |
