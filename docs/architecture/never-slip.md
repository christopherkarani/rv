# Never-slip

Named 2026-09-13. Overlay on `docs/architecture/02.md`. Not the 0.2 execute queue. Do not start IR (OPE-156), Host Ask, or live Auto-review from this name.

Human picture: a short list still denies when wrapped. Quiet agent work stays quiet. Chasing every crafted bypass in `normal` never ships.

**Arbiter:** this file wins for what must deny even when wrapped. `docs/architecture/02.md` § Order still owns **when**. Next code ticket stays OPE-156. Named holes that are not never-slip live in `docs/architecture/residual-risk.md`. `MODULES.md` owns the hexagon. `docs/factory/PLAN.md` still wins hook-guard law (no `RV_BYPASS`, no allow-because-XPC-missed, no command text in `os_log`).

This page is law, not a matcher and not a second engine. Packs, `SecretPathCatalog`, and unwrap stay where they are. `matchingView` stays the grant key until 158.

## Four families

Must deny, wrapped or not. Wrappers do not weaken a family.

| Family | What it is | What it is not |
|---|---|---|
| **Day-one critical/high executing git/fs** | Executing hits that packs already deny at critical/high: `git reset --hard`, `rm -rf /`, fork-bomb. | Data (`echo` / `print` / `git commit -m` / `rg`). Medium/low pack matches. A landmine / near-miss row. |
| **Catalog secrets on executing operands** | `SecretPathCatalog` hits on **executing** operands (`cat ~/.ssh/id_rsa`). | Secret-shaped text that is only data. A second scanner. File-tool Read/Edit/Write (own program). |
| **Unwrap-limited** | `unwrapLimited` or an unparseable **executing** wrapper (`bash -c $CMD`). Recursion/parse limits → deny, never allow. | `unknown` syntax (that falls back to packs). A data wrapper that never executes. |
| **Pinned unlockable** | Policy gate must not spend: `core.secrets`, `builtin.action`, protected-path. | Unlockable pack denies. `BoundReview.mandatoryHuman`. |

## Executing

Today’s unwrap sinks. Not an AST. Not OPE-156.

**Executing** means `bash -c` / `sh -c` payload, `python -c os.system` / equivalent.

`echo`, `print`, `git commit -m`, `rg` are data.

| Line | Family | Door |
|---|---|---|
| `git reset --hard` | Day-one git/fs | deny |
| `bash -c 'git reset --hard'` | Day-one git/fs (wrapped) | deny |
| `python -c "os.system('git reset --hard')"` | Day-one git/fs (wrapped) | deny |
| `bash -c $CMD` | Unwrap-limited | deny |
| `cat ~/.ssh/id_rsa` | Catalog secrets | deny |
| `echo 'git reset --hard'` | none (data) | allow |
| `python -c "print('git reset --hard')"` | none (data) | allow |

## Wrappers and unknown

A wrapper does not turn a never-slip deny into allow. Completeness of unwrap is a later ticket (OPE-156, then 254–256). Until then the families still hold on today’s sinks.

`unknown` syntax falls back to packs rather than a fake semantic hit. It is not Git, not filesystem, and not a way around a family-1 pack deny that already matches the line.

Recursion or parse limits on an executing wrapper are `unwrapLimited` → deny, never allow. Allow-because-unwrap-limited is forbidden.

Packs, secrets, Git/FS, and hard policy must read the same innermost **executing** command after a complete unwrap. Dual scanners on different strings fail this overlay.

## Safety

Levels are `normal` (default) and `strict` only. Never-slip denies at both. A crafted bypass that is not one of the four families is residual or a `strict` deny — not a new `normal` regex, and not a third level.

## Locked

1. Four families. Not a second evaluate engine.
2. Wrappers do not weaken those families.
3. `unknown` → packs, never a fake semantic hit.
4. Recursion/parse limits → deny, never allow.
5. Executing = today’s unwrap sinks. Data is not executing.
6. Safety is `normal` and `strict` only.
7. `matchingView` stays the grant key until 158. This page is not that key.
8. Next code ticket is OPE-156. Do not start IR, Ask, or Auto-review from this name.

## Forbidden

- Allow because the command was wrapped
- Allow because unwrap/parse limited
- Scanning `echo` / `print` / `git commit -m` / `rg` guts as executing shell
- A fake Git/FS hit on unknown syntax
- A third safety level
- Spending PolicyGate on `core.secrets`, `builtin.action`, or protected-path
- Starting OPE-156 / Host Ask / Auto-review from this name
- `RV_BYPASS`; command text in `os_log`; live-HOME tests
