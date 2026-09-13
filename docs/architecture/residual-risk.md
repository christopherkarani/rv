# Residual risk

Named 2026-09-13. Overlay on `docs/architecture/02.md`. Not the 0.2 execute queue.

**Execute overlay:** `planning/2026-09-13-guard-maturity-implementable-program.md`. Do not start IR (OPE-156), Host Ask, or live Auto-review from this name.

Human picture: named holes in `normal` we will not chase. Quiet agent work stays quiet. A crafted bypass that is not never-slip is residual or `strict` — not a new `normal` regex.

**Arbiter:** this file wins for holes we will not chase in `normal`. `docs/architecture/never-slip.md` wins for what must deny even when wrapped. `docs/architecture/02.md` § Order still owns **when**. Next code ticket stays OPE-156. `MODULES.md` owns the hexagon. `docs/factory/PLAN.md` still wins hook-guard law (no `RV_BYPASS`, no allow-because-XPC-missed, no command text in `os_log`).

This page is law, not a matcher and not a second engine. Packs, `SecretPathCatalog`, and unwrap stay where they are. `$CMD` / `unwrapLimited` is never-slip, not residual.

## Registry

Named `RV-RR-NN`. Each row is a hole in `normal`. `strict` may tighten a row; `n/a` means this hole does not change. Do not invent a third safety level.

| ID | Hole | `normal` | `strict` | Why we stop |
|---|---|---|---|---|
| **RV-RR-01** | Encoded / reconstructed secret names | allow | n/a | Catalog matches executing operands as written. Decoding or reconstructing a secret name is a language interpreter, not `SecretPathCatalog`. |
| **RV-RR-02** | Pack walk matching print/prose guts while the door (`evaluateWithSemantics`) allows | door allow | n/a | Pin walk may still match `print` / `echo` / `git commit -m` / `rg` guts. Product door is `evaluateWithSemantics`. Do not add a `normal` regex to "fix" the walk. |
| **RV-RR-03** | Grok fail-open if the hook never runs (host does not invoke rv) | allow | n/a | Grade is hook. A host that never calls `rv` is not an evaluate miss and not allow-because-XPC-missed. `strict` does not change this. |
| **RV-RR-04** | Codex `write_stdin` (no official intercept) | allow | n/a | Host stdin/write gap. Official intercept is PreToolUse / Bash. No official `write_stdin` event. Not a fake `cat` of stdin. File-tool Read/Edit/Write is own program. |
| **RV-RR-05** | Interpreter bodies that are not executing sinks; anything that needs a partial language interpreter | allow | n/a | Executing = today’s unwrap sinks. Do not reconstruct Python / Node / Ruby to chase crafted `normal` bypasses. |

## What a row is

| | What it is | What it is not |
|---|---|---|
| **Residual** | A named hole in `normal` we will not chase. | A never-slip family. A landmine / near-miss allow we must keep. |
| **`strict`** | Restrict-only overlay that may deny a named hole. | A third safety level. A new `normal` walker. |
| **Host gap** | The host never invoked rv, or has no official intercept. | Allow because `rvd` is down or skewed. A matcher miss inside evaluate. |

## Safety

Levels are `normal` (default) and `strict` only. Never-slip still denies at both. A crafted bypass that is not never-slip is a new `RV-RR-*` row or a `strict` deny — not a new `normal` regex.

## Operator

The two lists are this page (`RV-RR-*`) and `docs/architecture/never-slip.md`. Operator surface is `rv safety` (effective `normal` / `strict`) and `rv test` (`rv test --robot '<cmd>'` → `rv.test.v1` JSON). Isolated-HOME W3 transcript: `planning/2026-09-13-guard-maturity/oracles.md`; scripted run: `tools/host-oracle.sh`. Not a new CLI. Not 02.md § Order Manual for Ask.

## Locked

1. Crafted bypass that is not never-slip is residual or `strict` — not a new `normal` regex.
2. `$CMD` / `unwrapLimited` is never-slip, not residual.
3. Product door is `evaluateWithSemantics`. Pin pack `evaluate` is the 0.11.0 scoreboard, not a second engine.
4. Safety is `normal` and `strict` only.
5. Next code ticket is OPE-156. Do not start IR, Ask, or Auto-review from this name.

## Forbidden

- A new `normal` regex to close a row on this page
- Putting `$CMD` / `unwrapLimited` here
- Scanning `echo` / `print` / `git commit -m` / `rg` guts as executing shell to "close" **RV-RR-02**
- Reconstructing a language interpreter to chase **RV-RR-01** or **RV-RR-05**
- A fake `cat` of Codex `write_stdin`
- Allow because XPC missed (that is not **RV-RR-03**)
- A third safety level
- Starting OPE-156 / Host Ask / Auto-review from this name
- `RV_BYPASS`; command text in `os_log`; live-HOME tests
- OS-enforced / Seatbelt claim
