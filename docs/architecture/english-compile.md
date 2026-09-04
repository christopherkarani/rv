# English compile (typed rules)

Named 2026-09-04. Not the 0.2 execute queue.

**Execute W1:** `planning/2026-09-04-english-compile/PROMPT.md`. Program: `planning/2026-09-04-english-compile-implementable-program.md`. Do not start Host Ask (OPE-264), companion app, or live Auto-review from this name.

Human picture: you type English, rv shows a real rule, you save it, the hook matches that rule with no model. W1 builds the form and the matcher. English and Apple come later.

**Arbiter:** this file wins for the three products, the compile pipeline, `PolicyPredicate` / `TypedRule` shapes, restrict-only overlay, and **Ask beats allow**. `docs/architecture/02.md` § Order still owns **when** Host Ask and live Auto-review ship. `MODULES.md` owns the hexagon. `docs/factory/PLAN.md` still wins hook-guard law (no `RV_BYPASS`, no allow-because-XPC-missed, no command text in `os_log`). A human must name this program.

## Three products

Keep these separate. The throwaway spike mixed them: allow-English still asked.

| Product | What it is | What it is not |
|---|---|---|
| **Wall** | Built-in hard deny, packs, `blocksAllowOverride`. Shared-branch force-push to `main` stays denied. | A typed allow. English. Auto-review. |
| **Compiled form** | Closed `PolicyPredicate` + `TypedRule`. Human previews; save writes the form; the hook matches the form with no model. | Regex. Saved English. Wax. `supportingCommand` as the matcher. |
| **Auto-review** | AFM `ActionReviewer` on `.reviewEligible` after Host Ask exists. Shadow today; live bind is a later 02.md ticket. | The matcher. A way around the wall. |

W1 ships the compiled form (git force-push only) and proves the wall still holds. It does not ship English or live Auto-review.

## Compile pipeline

Not regex. Not saved English. Not Wax.

1. A model fills a **closed form** (`PolicyPredicate` + verdict). Uncompilable English is refused and writes nothing. “Be careful in prod” is not a rule.
2. The human previews the form in plain language (Always block force-push to main / cannot-override).
3. Save writes the **form** (`TypedRule`). Cancel writes nothing.
4. The hook matches the saved form. The second call does not run a model.

English in is W3 (`rv policy draft`). W1 has no English UI: `rv policy show` only.

## Open vs closed

Closed world = enum. Open world = protocol at the service edge (or a Domain protocol with a fake in tests).

- **Closed:** `PolicyPredicate` (W1: `gitPush(force:branch:)` only), `TypedRuleVerdict` (`allow` / `ask` / `deny`), `TypedRuleOrigin` (`builtin` / `machine` / `repo`), `ProposedAction.shell`.
- **Open:** `ActionReviewer` / `ApprovalBridge` at RVService. W3: `EnglishCompiler` protocol in RVDomain; fake in tests; AFM adapter in RVPolicy behind `#if canImport`. Tests never call live Apple. Foundation Models stay out of RVDomain / RVEngine.

Do not add `ProposedAction.mcp`, npm/process predicates, or `git status` as a `GitAction` in this program.

## Shell-first

The IR is shell. Analyzers today are Git and filesystem. W1’s only predicate is `PolicyPredicate.gitPush` bound to `GitAction.push` and `resources.branchName` (or a refspec that names that branch). `supportingCommand` is evidence, not the primary matcher.

MCP tools, npm/process, and `git status` English are deferred until those analyzers exist. The compiler refuses them; it does not save a fuzzy rule.

## Ask-before-live-reviewer

Host Ask (Pi, OpenCode, Claude, Hermes) ships before any live reviewer on the hook. `docs/architecture/02.md` § Order owns that sequence (OPE-264/265 before 249/250/253/252). This program does not start those tickets.

`ShadowReviewRunner` records; it never calls `ReviewBind.apply`. Live Auto-review is not this program.

**Ask beats allow.** If a typed ask and a typed allow both match the same action, the verdict is ask. A typed allow cannot beat the wall (`RulePinning.blocksAllowOverride`, builtin `hardDeny`, pack deny floor). Typed ask on a non-hard action maps to `HardPolicyDecision.mandatoryHuman`. Do not add `Decision.ask` to packs.

## Modules

No new SPM target.

| Shape | Module |
|---|---|
| `PolicyPredicate`, `TypedRule` (value types) | RVDomain — `ActionPolicyEngine` is Domain and stays pure |
| Load / save / merge | RVPolicy — invariants ⊳ machine ⊳ repo, restrict-only |
| `rv policy show` | RVCLI |

Merge cannot let a repo allow drop a machine deny. Overlay cannot weaken builtin hard deny.

## Locked

1. Three products stay separate.
2. The matcher is the saved form, not English.
3. W1 predicate is git force-push only.
4. Restrict-only: typed allow never un-blocks the wall.
5. **Ask beats allow.**
6. Merge is invariants ⊳ machine ⊳ repo.
7. Uncompilable English refuses; do not save.
8. `scratch/english-review` stays throwaway. Do not import it from rv targets.
9. Shell-first. MCP / npm / `git status` are later programs.
10. Ask-before-live-reviewer. Do not start 02.md § Order from this name.

## Forbidden

- Saving English text as the matcher
- Matching `supportingCommand` as the primary predicate
- Weakening builtin hard deny with a typed allow
- Live Auto-review / `ReviewBind.apply` on the hook path
- Host Ask / OPE-264 / companion SwiftUI from this name
- `ProposedAction.mcp`, npm/process analyzer, Wax or Linear as policy storage
- Importing `scratch/english-review`
- Foundation Models in RVDomain or RVEngine
- `class` in Domain/Engine/Policy; `try!` / `!` on production paths
- `RV_BYPASS`; command text in `os_log`; live-HOME tests
- Adding `case ask` to pack `Decision`
- Presenting `rv-cli` as the product; foreign product names in user-facing copy

## Waves (so later runs do not invent)

| Wave | Ships | Does not |
|---|---|---|
| W1 | This law, `PolicyPredicate.gitPush`, `TypedRule`, match, restrict-only engine, store, explain rule id, `rv policy show` | English, AFM compiler, hook bind |
| W2 | Typed pin preview/save (replace fingerprint-only draft for git push) | English |
| W3 | English → preview → save; fake compiler in tests; optional AFM in RVPolicy | Live Auto-review, companion box, MCP/npm |

## Deferred (own programs)

Host Ask Claude (OPE-264), companion English box, live Auto-review (253), process/npm analyzer, `ProposedAction.mcp`, AFM LoRA, company admin UI, promoting the spike.
