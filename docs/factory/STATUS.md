# Factory status

Living board for implement sessions. Do **not** re-grill. Do **not** load `docs/factory/reviews/*` to implement.

**Agent entry:** `AGENTS.md` → this file → relevant skill → `tools/gate.sh`

## Board

| | Ticket | Notes |
|---|---|---|
| Done | T0–T9 | Scaffold through catalog + `rv packs`. Allow-once and doctor live. |
| Done | maint | Operator-surface seams (setup analytics, ceremony snapshot, robot format). |
| Done | T10–T14 | Merged to `feat/t10-t14-size-speed` (PR #36 draft). One-shot evaluate refuses major-semver-skewed `rvd`. Spec: [`specs/phase-5-size-speed.md`](specs/phase-5-size-speed.md). |
| Done | C hook T1–T5 | Implemented on `feat/c-hook-pipe` (PR #43). C `rv` pipes `hookEvaluate` to `rvd`; miss execs `rv-cli`. Spec: [`spec/spec-architecture-c-hook-pipe.md`](../../spec/spec-architecture-c-hook-pipe.md). |
| Done | session scan T1–T10 | `rv scan` / `rv scan sessions` session forensics. Spec: [`spec/spec-architecture-session-scan.md`](../../spec/spec-architecture-session-scan.md). |
| Done | Claude CL-T1–T5 | Codec, dispatch, settings merge, doctor, MODULES. Spec: [`specs/claude-host.md`](specs/claude-host.md). |
| Done | OpenClaw host (OPE-266) | Host only, no Ask. `HookHost.openclaw`, `before_tool_call` / `exec`, exclusive `~/.openclaw/extensions/rv-guard/`, fail-closed sqlite scan. |
| Done | Hermes host (OPE-265) | Host only, no Ask. `HookHost.hermes`, `pre_tool_call` / `terminal`, exclusive `~/.hermes/plugins/rv-guard/`, fail-closed sqlite scan. |
| Next | Claude CL-later-ask | Fenced: `permissionDecision: "ask"`. Not started. |
| Next | Claude CL-later-secrets | Fenced: Read/Edit/Write secret-path guards. Not started. |
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
| `specs/phase-4-session-scan.md` | Implemented (T1–T10). Session forensics `rv scan`. Spec: [`spec/spec-architecture-session-scan.md`](../../spec/spec-architecture-session-scan.md) |
| `specs/phase-5-size-speed.md` | Implementing (T10–T14) |
| [`spec/spec-architecture-c-hook-pipe.md`](../../spec/spec-architecture-c-hook-pipe.md) | Implemented (T1–T5). C hook pipe + Swift miss. Supersedes the T15 thin-Swift fence. |
| [`specs/claude-host.md`](specs/claude-host.md) | Implemented (CL-T1–T5). Fenced later: CL-later-ask, CL-later-secrets, CL-later-mcp. |
| [`specs/cli-thin.md`](specs/cli-thin.md) | Draft. Deepen CLI without a new SPM target. CL1 EvaluationRoute → CL2 Hook door ∥ CL3 EvaluationWorld → CL4 drop Engine. |

## Parallel rules (reminder)

| Wave | Tickets | Worktree? |
|---|---|---|
| Done | T0 → T1 serial; T2 ∥ T3; T4 then T5; T6; T7; T8 ∥ T9 | — |
| Done | T10 ∥ T11 ∥ T12 ∥ T13; then T14 (after T11) | Separate worktrees; exclusive files in the Phase 5 spec |
| Done | session scan T1; then T2; then T3 ∥ T4 ∥ T5; then T6; then T7; then T8; then T9; then T10 | Exclusive files in `spec/spec-architecture-session-scan.md` § 5b |
| Done | C-hook T1; then T2 ∥ T3; then T4; then T5 | Exclusive files in `spec/spec-architecture-c-hook-pipe.md` |

Historical factory→T0 handoff: [`HANDOFF.md`](HANDOFF.md) (do not use as session start).
