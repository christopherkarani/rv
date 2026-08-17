# Stress test 2

Hostile pass. Independent of pass 1. Method: follow each prompt’s words as a pedantic implementer who ignores “spirit,” then ask whether that green ticket still violates a spec or PLAN.

Read: `PLAN.md`, `HANDOFF.md`, all specs, prompts T0–T9, reviews under `docs/factory/reviews/`, `references/host-contracts-v1.md`, `references/dcg-0.11.0-notes.md`.

## Verdict (Fix required)

Three named attacks all landed before this pass.

1. **T0 then T1 prompt-only** — T0 is sealed (it orders the spec literally). T1’s prompt body plus its short prove list did **not**. A checkbox-only T1 could omit `RVCorpusTests` from `Package.swift`, default-allow empty core packs, skip oversize, and invent a fake deny `rule_id` for “must not allow.” That violates `phase-1-engine.md` evaluate step 6, PLAN #15, and the L2 corpus contract.
2. **T2 ∥ T3** — yes, they fought `Package.swift`. T0 is library-only. T2 needs ArgumentParser + product `rv`. T3 needs product/target `rvd` **and** used to need `rv service status` as a process, which tempts T3 to add ArgumentParser + `rv` too. Both also invented `RootCommand` / `main.swift`.
3. **Indeterminate as allow** — T4.3 already had a deny row, but a hole remained. T2’s `hostDenyText -> String?` was `nil` unless `Decision.deny`. T4.4 was a two-state “allow / deny” machine. T4.5 had no oversize fixture. `host-contracts-v1.md` said only “Allow: empty stdout.” A literal `if hostDenyText == nil { encodeAllow() }` lets a padded `git reset --hard` through. **Yes, a hole remained.**

Smallest prompt/spec patches are applied. PLAN was not edited. No product Swift. No ryk.

## Literal-reading attacks

### T0 then T1 — prompt-only vs spec

T0 prompt: implement `phase-0-repo.md` literally and prove every spec checkbox. A hostile T0 who only ticks the prompt’s shorter prove list still misses README / `.gitignore` / `MODULES.md` content / PIN `tag_object`+`commit`, but the opening sentence forces the spec. **T0 alone does not violate a spec.**

T1 prompt (before this pass) said “prove every spec checkbox” **and** “Do not add SPM dependencies. Do not add executables,” then listed a prove set that omitted:

| Prompt-only action | Spec / PLAN it violates |
|---|---|
| Refuse every `Package.swift` edit | Spec allows exactly `RVCorpusTests`. Without that target, `swift test --filter RVCorpusTests` never runs. |
| Empty/missing packs “must not allow” → fake `deny(core.git:unavailable)` | Deny always carries a real `rule_id`. Spec wants `indeterminate(.corePacksUnavailable)`. Numbered acceptance did not say so. |
| Skip oversize | Spec body + test plan require `indeterminate(.commandTooLarge)`. Not in the prompt prove list. |
| `PackID(rawValue:)!` to match the old sample | PLAN #3 + T1 prompt forbid `!`. Spec sample used `PackID(rawValue:)` as if non-optional while declaring `RawRepresentable`. |
| Rewrite `push-force-short` so `git push -uf` denies | Prompt required `-uf`. 0.11.0 may not match the combined flag. Spec says do not simplify regexes. |

If the implementer honors “the T1 spec wins API and corpus details,” they do not violate. The attack is real because the prompt’s **prove list** is what a literal agent stops on, and that list was a subset.

Also: T1 `EvaluationResult` used to nest `SafeMatch` inside the struct (uncompilable). A paste-the-snippet agent either fails compile or drops `quickRejected`.

### T2 `hostDenyText == nil` ⇒ T4 allow

FP-02 correctly made `hostDenyText` optional so `git stash drop` (allow + match) is not a host deny. The fix overshot. `nil unless Decision.deny` means `indeterminate` is `nil`. T4 prompt said “hostDenyText is the only string T4/T5 may use.” Combined with T4.4 “Allow → empty. Deny → JSON,” the natural code is:

```
if let reason = hostDenyText(from: result) { encodeDeny(reason) } else { encodeAllow() }
```

That is FN-01 again. T4.3’s indeterminate deny row does not save you if you never switch on `Decision`.

### T5.1 vs T5.3 vs PLAN #6 (missing `rv`)

At the start of this pass, T5.1 said catch spawn errors and return nothing (allow). T5.3 and the T5 prompt said block with `rv missing`. `host-contracts-v1.md` and adversarial-fp FP-04 claimed PLAN was fail-open. **Current PLAN #6 says Pi/OpenCode block.** A literal T5.1 implementer would allow every bash call when the binary is missing — including `git reset --hard`. PLAN wins; T5.1 was the stale line.

### T8 `XDG_CONFIG_HOME`

PLAN #12: config is `$HOME/.config/rv` only. No `XDG_CONFIG_HOME`. T8 spec still had a user-layer path `$XDG_CONFIG_HOME/rv/allowlist.toml` (already struck in the spec by the time this pass finished editing). A literal T8 that honors XDG writes the wrong tree when that env is set.

### T7 prompt vs PLAN #18

T7 prove list said `wired/missing/occupied` and omitted `broken`. PLAN #18: missing/non-exec baked `rv` path is `broken`, not `wired`. A green T7 could call a dead path `wired`.

### T2 robot `rule_id`

PLAN #13: robot JSON `rule_id` is the colon form. T2 spec example was `"rule_id":"reset-hard"`. T2 prompt (later) said colon form. Literal spec-snapshot agent ships the pattern alone.

## Parallel-worktree fights

### T2 ∥ T3 — `Package.swift` (the asked fight)

T0 graph: twelve libraries, no executables, no ArgumentParser, no `rvd` target.

PLAN #4: T2 may add ArgumentParser `from: "1.7.0"` + executable `rv` + `Sources/RVCLI/main.swift`. T3 may add executable `rvd`.

Before this pass:

- T2 prompt: “Do not add, remove, or retarget Package.swift modules. If a graph edit looks required, stop and write a merge plan.” Then: “You may add ArgumentParser…” First sentence wins for a pedant → T2 stalls, or T2 edits `Package.swift` anyway to pass `rv test`.
- T3 prompt: “Package.swift: only additive service-graph lines” + prove `rv service status`.
- T3 spec Depends: claimed T0 already had an empty `rvd` target. False. T3 goes looking, then adds it — correct outcome, wrong premise.
- T3 spec merge plan told T3 it may add `RVCLI → RVIPC` (already in T0) and did **not** forbid ArgumentParser.
- T3 `rv service status` is an ArgumentParser command. From a T1-green SHA, that file does not compile until ArgumentParser exists. Hostile T3 adds the package + product `rv` so the checkbox is green.
- Both tickets were told to union a `RootCommand` / `main.swift` that neither owns exclusively.

Result: both worktrees edit `products`, `dependencies`, and `targets`. Git conflict, and a semantic fight (`@main` on library `RVCLI` vs `rvd` as a separate executable; duplicate ArgumentParser pins).

T8 ∥ T9 and T6 ∥ T7 are cleaner if they do not add ArgumentParser. T8/T9 prompts now say T2 owns that pin. T6 may add `RVCLI` resources; that is a later wave, after T2/T3 merge.

### T4 then T5

Serial on one worktree. No `Package.swift` fight. Fine.

## Prompt vs spec drift

| Ticket | Prompt said | Spec / PLAN said | Literal outcome |
|---|---|---|---|
| T1 | Do not add SPM deps / executables | Add `RVCorpusTests` | Target omitted, or corpus hidden in `RVEngineTests` |
| T1 | Empty packs must not allow | `indeterminate(.corePacksUnavailable)` | Fake deny `rule_id` |
| T1 | Required `git push -uf` | Extract 0.11.0 regex; do not rewrite | Pattern “simplified” to pass the checkbox |
| T2 | `hostDenyText` nil unless deny; only string T4 may use | PLAN #6: indeterminate → hook deny | T4 `nil` ⇒ empty allow |
| T2 spec example | `"rule_id":"reset-hard"` | PLAN #13 colon form | Robot identity slop |
| T3 | Prove `rv service status` | T2 owns product `rv` | T3 adds `rv` + ArgumentParser |
| T3 spec | T0 declared `rvd` | T0 is library-only | Confusion, then a graph edit |
| T4.4 / host-contracts | Allow or deny | T4.3 + PLAN: three `Decision` cases | Two-state codec |
| T5.1 (was) | Catch spawn → allow | PLAN #6 + T5.3: block `rv missing` | Missing binary fail-open |
| T7 prompt | wired/missing/occupied | PLAN #18 + T7.1: also `broken` | Dead path reported wired |
| T8 spec (was) | `$XDG_CONFIG_HOME/rv/…` | PLAN #12: `$HOME/.config/rv` only | Wrong config tree |

Adversarial FN-01 described an older T4.3 Allow row that listed `indeterminate`. That row is already gone. The remaining hole was the **two-state CLI + nil `hostDenyText`**, not the table.

Adversarial FP-04 is stale against **current** PLAN #6 (Pi/OpenCode block on missing `rv`). This pass follows PLAN, not FP-04.

## Fixes you applied (if any)

Prompts:

- **T1** — only allowed `Package.swift` add is `RVCorpusTests`. Empty packs → `indeterminate(.corePacksUnavailable)`. Oversize → `indeterminate(.commandTooLarge)`. Non-failable `PackID` init. `-uf` must not rewrite the regex. Prove list includes those gates plus `$TMPDIR`.
- **T2** — exclusive `Package.swift` lines (ArgumentParser 1.7.0 + product `rv`; no `rvd`). `hostDenyText` is nil on allow, PLAN incomplete-eval sentence on indeterminate, deny sentence on deny. T4/T5 must switch on `Decision`.
- **T3** — exclusive `rvd` product/target. No ArgumentParser, no product `rv`, no `RootCommand`/`main.swift`. Prove `ServiceStatusReport` in-process. Do not coerce indeterminate to allow.
- **T4** — switch on `Decision`; indeterminate deny JSON even if `hostDenyText` is nil; stash-drop allow + oversize deny on the prove list.
- **T5** — ENOENT blocks; do not catch-and-allow; honor indeterminate deny JSON.
- **T7** — `broken` is a first-class host state; non-exec baked path is not `wired`.
- **T8 / T9** — no ArgumentParser / `@main`; `$HOME/.config/rv` only; PolicyGate indeterminate is not allow.

Specs / reference:

- **phase-1-engine.md** — non-failable `PackID` init; acceptance 7c/7d/7e/7f (duplicate `7d` un-aliased); `-uf` extract-or-record.
- **phase-1b-ux.md** — `hostDenyText` covers indeterminate; robot `rule_id` is `core.git:reset-hard`; T2 `Package.swift` lines exclude `rvd`.
- **phase-1c-service.md** — exclusive merge plan; T0 did not declare `rvd`; in-process status; do not coerce indeterminate to allow.
- **phase-1d-hosts.md** — T4.4 three-way `Decision` switch; XPC-down row includes Indeterminate; `encodeDeny` used for indeterminate; T5.3 indeterminate row; OQ7 already locked to PLAN #6.
- **host-contracts-v1.md** — allow / deny / indeterminate; nil `hostDenyText` is not allow.
- **phase-3-allow.md** — XDG already gone by the time this pass edited; left as `$HOME/.config/rv`.

Not edited: `PLAN.md`, product Swift, ryk, `dcg-0.11.0-notes.md` (HANDOFF still points T1 at it; T1 prompt + PLAN already override stash-drop).
