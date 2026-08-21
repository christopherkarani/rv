# Factory status

Living board for implement sessions. Do **not** re-grill. Do **not** load `docs/factory/reviews/*` to implement.

**Agent entry:** `AGENTS.md` → this file → relevant skill → `tools/gate.sh`

## Board

| | Ticket | Notes |
|---|---|---|
| Done | T0–T9 | Scaffold through catalog + `rv packs`. Allow-once and doctor live. |
| Done | maint | Operator-surface seams (setup analytics, ceremony snapshot, robot format). |
| **Current** | **T10–T14** | Size + hook speed. Spec: [`specs/phase-5-size-speed.md`](specs/phase-5-size-speed.md). Frontier: T10 ∥ T11 ∥ T12 ∥ T13; T14 after T11. Prompts: `prompts/T10.md` … `T14.md`. Integration: `feat/t10-t14-size-speed`. |

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
| `specs/phase-5-size-speed.md` | Implementing (T10–T14) |

## Parallel rules (reminder)

| Wave | Tickets | Worktree? |
|---|---|---|
| Done | T0 → T1 serial; T2 ∥ T3; T4 then T5; T6; T7; T8 ∥ T9 | — |
| **Current** | T10 ∥ T11 ∥ T12 ∥ T13; then T14 (after T11) | Separate worktrees; exclusive files in the Phase 5 spec |

Historical factory→T0 handoff: [`HANDOFF.md`](HANDOFF.md) (do not use as session start).
