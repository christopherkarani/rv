# Factory status

Living board for implement sessions. Do **not** re-grill. Do **not** load `docs/factory/reviews/*` to implement.

**Agent entry:** `AGENTS.md` → this file → relevant skill → `tools/gate.sh`

## Board

| | Ticket | Notes |
|---|---|---|
| Done | T0–T6 | Scaffold through curl install + TTY setup show. Host adapters live. |
| **Current** | **T7** | `rv doctor` (service + hosts + packs). Prompt: [`prompts/T7.md`](prompts/T7.md). Specs: `specs/phase-1c-service.md`, `specs/phase-1d-hosts.md`. Skill: `.grok/skills/swift-hook-xpc`. |
| Next | T8 ∥ T9 | After T1 (already green): allow-once and pack catalog in parallel worktrees per PLAN. |

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

## Parallel rules (reminder)

| Wave | Tickets | Worktree? |
|---|---|---|
| Done | T0 → T1 serial; T2 ∥ T3; T4 then T5; T6 | — |
| Now | T7 | `feat/t7-doctor` (may have paralleled T6) |
| Later | T8 ∥ T9 | Yes — separate worktrees |

Historical factory→T0 handoff: [`HANDOFF.md`](HANDOFF.md) (do not use as session start).
