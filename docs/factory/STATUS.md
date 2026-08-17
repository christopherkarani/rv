# Factory status

Goal: Go Ready kickoff for rv T0–T9 in `~/CodingProjects/rv`.

| Step | State |
|---|---|
| Locked plan | Done |
| Phase specs (8) | Landed |
| Adversarial FP / FN / known-unknowns | Landed; PLAN patched |
| Handoff | Complete (factory → implement T0) |
| Stress test ×2 | Landed (`reviews/stress-1.md`, `stress-2.md`) |
| Implement prompts | Landed (`docs/factory/prompts/T0.md`–`T9.md`) |
| Cohesiveness Go Ready | **Go Ready** |
| Kickoff canvas | [rv-factory](/Users/chriskarani/.cursor/projects/Users-chriskarani-CodingProjects-rv/canvases/rv-factory.canvas.tsx) |

## Specs

| File | State |
|---|---|
| `specs/phase-0-repo.md` | Landed |
| `specs/phase-1-engine.md` | Landed (patched after FN/KU) |
| `specs/phase-1b-ux.md` | Landed (`hostDenyText` nil on allow; robot `rule_id` colon form) |
| `specs/phase-1c-service.md` | Landed (consume = grant; T3 adds `rvd`) |
| `specs/phase-1d-hosts.md` | Landed (indeterminate deny; T6 LaunchAgent; missing `rv` blocks Pi/OpenCode) |
| `specs/phase-2-packs.md` | Landed |
| `specs/phase-3-allow.md` | Landed (`$HOME/.config/rv` only) |
| `specs/phase-4-later.md` | Landed (fence only) |

## Parallel kickoff (after Go Ready)

| Wave | Tickets | Worktree? |
|---|---|---|
| 1 | T0 | No — serial on main |
| 2 | T1 | No — serial after T0 |
| 3 | T2 ∥ T3 | Yes — separate worktrees |
| 4 | T4 then T5 | One worktree, serial |
| 5 | T6 ∥ T7 | Yes if ownership split |
| 3 or later | T8 ∥ T9 | Yes — after T1 |
