# Program: English compile (typed rules)

**Date:** 2026-09-04  
**Status:** ready_for_implementor  
**Handoff (new session):** paste `planning/2026-09-04-english-compile/PROMPT.md`  
**Source plans:** this thread’s product lock; `docs/architecture/02.md` (Ask before Auto-review; 258 after TypedRule); spike `scratch/english-review` (feel only)  
**Repo / branch assumptions:** `/Users/chriskarani/CodingProjects/rv` from current `main`. Branch `feat/english-compile`. Apple Silicon, Swift 6.3.3 via `tools/swift-6.3.3`, warm `.build`.  
**Stop line:** **First Swift workflow run is W1 only.** Do **not** use Zig `implementor` / `implementor-program`. Runner is `.grok/workflows/english-compile-swift.rhai` (sibling of `orchestrate-implement-swift`). W1 lands product law + a typed rule form the engine can match for **git force-push**. It does **not** implement live Auto-review on the hook, Host Ask (OPE-264), companion app, MCP `ProposedAction`, npm/process analyzer, Wax, billing, or wiring `scratch/english-review` to `rv hook`. W2–W3 are specified so later runs do not invent. W4+ are deferred programs with entry criteria.

---

## 0. One-line goal

You type English, rv shows a real rule, you save it, the hook matches that rule with no model. W1 builds the form and the matcher. English and Apple come in W3.

---

## 1. Tree-truth ledger

| ID | Slice / finding | Status | Evidence | Residual if partial |
|----|-----------------|--------|----------|---------------------|
| F-law | Product semantics for English compile | open | conversation lock; no `docs/architecture/english-compile.md` | W1 T1 |
| F-02 | 02.md § Order still owns when | landed | `docs/architecture/02.md` | pointer only in W1 T1 |
| F-ir | `ProposedAction.shell` | landed | `Sources/RVDomain/ProposedAction.swift` | do not add `.mcp` |
| F-git | `GitAction.push(force:refspec:)` | landed | `GitAction.swift` | W1 predicates bind this |
| F-engine | `ActionPolicyEngine` + builtins | landed | `ActionPolicyEngine.swift`; overlay cannot weaken hard deny | W1 extends `EffectiveActionPolicy` |
| F-bind | `ReviewBind` cannot override hard deny | landed | `HardPolicyDecision.swift` | do not change bind math |
| F-reviewer | AFM shadow | landed | `FoundationModelsActionReviewer.swift`; `ShadowReviewRunner` never `ReviewBind.apply` | live bind is deferred |
| F-pin | Always-allow preview | partial | `RulePinning` opaque fingerprint JSON → allowlist exact command | W2 replaces draft with typed form |
| F-createRule | `ApprovalDecision.createRule` | partial | case exists; no `PolicyDraft` type | W2 |
| F-ast | `PolicyPredicate` / `TypedRule` | open | grepped Sources: no types | W1 T2–T3 |
| F-ask | Host Ask Claude | deferred | OPE-264; `HostNativeAsk.capability(.claude)=denyOrTTY` | not this program |
| F-app | Companion English box | deferred | 247/248 missing | later program |
| F-spike | Throwaway Mac app | landed (demo) | `scratch/english-review` | never a product path |
| F-status | `git status` as GitAction | deferred | no `.status` case | refuse English until later analyzer |
| F-npm | process/npm analyzer | deferred | effects have no process kind | W3 compiler refuses; own program |
| F-mcp | MCP actions | deferred | `ProposedAction` shell-only | own program |
| F-packs | reset-hard deny | landed | day-one packs | verify by not editing Engine walkers |

---

## 2. Locked design decisions

| Decision | Choice | Rationale | Units affected |
|----------|--------|-----------|----------------|
| Three products | Wall / compiled form / Auto-review stay separate | Spike showed allow-English still asks | all |
| Compile | Model fills a **closed form**; human previews; save writes form; hook matches form | Not regex, not saved English, not Wax | W2–W3 |
| W1 form | `PolicyPredicate.gitPush(force:branch:)` only | Engine already has `GitAction.push` + `resources.branchName`; `supportingCommand` is not the matcher | w1-predicate, w1-match, w1-engine |
| Types module | Predicate + TypedRule **shapes in RVDomain** | `ActionPolicyEngine` is Domain and must stay pure | w1-predicate, w1-rule |
| Persistence | Load/save/merge I/O in **RVPolicy** | 02.md store ownership; no I/O in Domain | w1-store |
| Overlay | Typed rules restrict-only; allow cannot beat `RulePinning.blocksAllowOverride` / builtin hardDeny | Same as today | w1-engine |
| Ask vs allow | Ask wins if both match | Grok Bot was right; spike allow was weak | w1-engine, W3 |
| Merge | invariants ⊳ machine ⊳ repo | already 02.md | w1-store |
| English UI W1 | none | CLI `rv policy show` only | w1-cli |
| English compiler | W3, protocol in Domain, fake in tests, AFM behind `#if canImport` in RVPolicy | Tests never call live Apple | W3 |
| Uncompilable English | refuse; do not save | “be careful in prod” is not a rule | W3 |
| Spike | stays throwaway; do not import it | not the companion | all |
| Auto-review live | not this program | Ask missing on Claude; 02.md order | deferred |
| MCP / npm / git status | not W1 predicates | no typed analysis yet | deferred |
| New SPM module | **no** | hexagonal: Domain/Policy/CLI only | all |
| 02.md execute | do not start 264/247/253 from this name | same as agent-computer | all |

Unresolved forks: **none**.

---

## 3. Global reject list

- `RV_BYPASS` or any hook-honored skip-evaluate env
- Allow because XPC missed
- Live Auto-review / `ReviewBind.apply` on the hook path
- Host Ask / OPE-264 / companion SwiftUI / Island
- `ProposedAction.mcp` or MCP codecs
- Matching `supportingCommand` as the primary predicate (evidence only)
- Saving English text as the matcher
- Wax / Linear as policy storage
- Training Apple’s base model
- Importing `scratch/english-review` from rv targets
- `class` in Domain/Engine/Policy
- `try!` / `!` on production paths
- Command text in `os_log`
- Live-HOME tests
- `swift package clean` / wipe `.build`
- Changing pack `Decision` cases / adding `case ask` to pack Decision
- Putting Foundation Models in RVDomain or RVEngine
- Weakening builtin hard deny with a typed allow
- Implementing W2/W3 in the first launch
- Foreign product names in user-facing copy

---

## 4. Program e2e oracle pack

| # | Command | Expect | Notes |
|---|---------|--------|-------|
| 1 | `tools/gate.sh RVDomainTests` | PASS | after W1 T5 |
| 2 | `tools/gate.sh RVPolicyTests` | PASS | after W1 T6 |
| 3 | `tools/gate.sh RVCLITests` | PASS | after W1 T8 |
| 4 | Domain test: force-push main + typed deny rule → `HardPolicyDecision.hardDeny` | PASS | W1 T5 live_smoke sibling |
| 5 | Domain test: typed **allow** force-push main still hardDeny (builtin/shared branch) | PASS | wall holds |
| 6 | Build with real HOME, then `HOME=$tmp .build/arm64-apple-macosx/debug/rv policy show` | exit 0; names builtin / machine / repo (empty layers print `(none)`); temp HOME tree empty | darwin; after T8. Never wrap `tools/swift-6.3.3` in temp HOME — Darwin pin is `$HOME/Library/Developer/Toolchains`. |
| 7 | `rg -n "scratch/english-review" Sources Package.swift` | no matches | fail-on-match |
| 8 | `tools/gate.sh RVEngineTests` or corpus reset-hard | `git reset --hard` still deny | no Engine walker edits |
| 9 | `rg -n "PolicyPredicate" Sources/RVDomain` | hits after T2 | presence |

---

## 5. Ownership matrix (program)

| Path / glob | Exclusive unit id | Wave |
|-------------|-------------------|------|
| `docs/architecture/english-compile.md` | w1-law | W1 |
| `docs/architecture/02.md` (pointer sentences only) | w1-law | W1 |
| `AGENTS.md` `CONTEXT.md` (one-line pointers) | w1-law | W1 |
| `docs/architecture/MODULES.md` (PolicyPredicate / TypedRule rows) | w1-law | W1 |
| `Sources/RVDomain/PolicyPredicate.swift` | w1-predicate | W1 |
| `Tests/RVDomainTests/PolicyPredicateTests.swift` | w1-predicate | W1 |
| `Sources/RVDomain/TypedRule.swift` | w1-rule | W1 |
| `Tests/RVDomainTests/TypedRuleTests.swift` | w1-rule | W1 |
| `Sources/RVDomain/PolicyMatch.swift` | w1-match | W1 |
| `Tests/RVDomainTests/PolicyMatchTests.swift` | w1-match | W1 |
| `Sources/RVDomain/ActionPolicyEngine.swift` `Sources/RVDomain/HardPolicyDecision.swift` (only if explanation needs a field) | w1-engine | W1 |
| `Tests/RVDomainTests/ActionPolicyEngineTypedRuleTests.swift` | w1-engine | W1 |
| `Sources/RVPolicy/TypedRuleStore.swift` | w1-store | W1 |
| `Tests/RVPolicyTests/TypedRuleStoreTests.swift` | w1-store | W1 |
| `Sources/RVDomain/ExplainStep.swift` / explain attachment used by engine | w1-explain | W1 |
| `Tests/RVDomainTests/TypedRuleExplainTests.swift` | w1-explain | W1 |
| `Sources/RVCLI/Commands/PolicyCommand.swift` `Sources/RVCLI/RV.swift` | w1-cli | W1 |
| `Tests/RVCLITests/PolicyCommandTests.swift` | w1-cli | W1 |
| `Sources/RVPolicy/RulePinning.swift` `RulePinStore.swift` | w2-preview / w2-save | W2 |
| `Sources/RVDomain/EnglishCompiler.swift` | w3-protocol | W3 |
| `Sources/RVPolicy/FoundationModelsEnglishCompiler.swift` | w3-afm | W3 |
| `Sources/RVCLI/Commands/PolicyDraftCommand.swift` | w3-cli | W3 |

---

## 6. Waves

### Wave W1 — Typed form + matcher + `rv policy show`

- **Depends on waves:** none
- **mode:** full
- **max_units:** 8
- **max_parallel:** 3
- **agent_budget:** 1024
- **product_oracle_cmds:**
  - `tools/gate.sh RVDomainTests`
  - `tools/gate.sh RVPolicyTests`
  - `tools/gate.sh --filter PolicyCommand` (full RVCLITests is not W1 proof)
  - Build with real HOME, then `HOME=$tmp .build/arm64-apple-macosx/debug/rv policy show`
  - `rg -n "scratch/english-review" Sources Package.swift` (must fail if match — use `! rg` / exit 1 on hit)
- **Wave done when:** all 8 units merged + host disk gate + live verify PASS; force-push-main typed deny matches; typed allow cannot un-block shared-branch hard deny; `rv policy show` runs.

#### Unit: w1-law

- **Title:** Land english-compile product law
- **Mode:** implement
- **Goal:** Durable overlay so agents stop rediscovering the spike.
- **Acceptance:**
  1. `docs/architecture/english-compile.md` exists and states the three products, compile pipeline, shell-first, MCP/npm deferred, Ask-before-live-reviewer, open vs closed.
  2. `docs/architecture/02.md` points at that file for 258 / Auto-review **semantics** and still says § Order owns when.
  3. `AGENTS.md` + `CONTEXT.md` + `MODULES.md` have one-line pointers; PolicyPredicate/TypedRule listed on Domain (shapes) and Policy (store).
- **Composition acceptance:** AGENTS.md pointer is greppable `english-compile.md`.
- **Live smoke:** `test -s docs/architecture/english-compile.md && rg -n "english-compile.md" docs/architecture/02.md AGENTS.md`
- **Depends on:** none
- **Parallel-safe with:** none (docs shared with humans; do first)
- **Code paths (exclusive):** `docs/architecture/english-compile.md`, `docs/architecture/02.md`, `docs/architecture/MODULES.md`, `AGENTS.md`, `CONTEXT.md`
- **Test paths (exclusive):** none
- **Gates:**
  - `rg -n "english-compile.md" docs/architecture/02.md`
  - `rg -n "Ask beats allow" docs/architecture/english-compile.md`
- **Reject (local):** rewriting § Order; starting 264
- **Residuals allowed:** visual HTML none
- **Fat?:** no
- **Skills to inject:** none beyond repo AGENTS.md

#### Unit: w1-predicate

- **Title:** `PolicyPredicate` closed AST
- **Mode:** implement
- **Goal:** One Codable enum the engine can match without reading argv.
- **Acceptance:**
  1. `PolicyPredicate.gitPush(force: GitPushForce?, branch: String?)` exists in RVDomain.
  2. No other cases in W1 (no npm, no mcp, no git status).
  3. Round-trip Codable test.
- **Composition acceptance:** `ActionPolicyEngine` still compiles (import only later in T5).
- **Live smoke:** `tools/gate.sh RVDomainTests --filter PolicyPredicate`
- **Depends on:** w1-law
- **Parallel-safe with:** none
- **Code paths (exclusive):** `Sources/RVDomain/PolicyPredicate.swift`
- **Test paths (exclusive):** `Tests/RVDomainTests/PolicyPredicateTests.swift`
- **Gates:**
  - `tools/gate.sh RVDomainTests --filter PolicyPredicate`
- **Reject (local):** `supportingCommand` on the type; extra cases
- **Residuals allowed:** none
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-hexagonal-spm`, `swift-testing-pro`, `swift-functional-core`

#### Unit: w1-rule

- **Title:** `TypedRule` value
- **Mode:** implement
- **Goal:** Predicate + verdict + origin.
- **Acceptance:**
  1. `TypedRule` has `id: RuleID`, `predicate: PolicyPredicate`, `verdict: TypedRuleVerdict` (`allow` / `ask` / `deny`), `origin: TypedRuleOrigin` (`builtin` / `machine` / `repo`).
  2. Value type, Sendable, Codable.
  3. Tests cover equality + round-trip.
- **Composition acceptance:** none (Domain only)
- **Live smoke:** `tools/gate.sh RVDomainTests --filter TypedRule`
- **Depends on:** w1-predicate
- **Parallel-safe with:** none
- **Code paths (exclusive):** `Sources/RVDomain/TypedRule.swift`
- **Test paths (exclusive):** `Tests/RVDomainTests/TypedRuleTests.swift`
- **Gates:**
  - `tools/gate.sh RVDomainTests --filter TypedRule`
- **Reject (local):** storing raw English on the rule
- **Residuals allowed:** none
- **Fat?:** no
- **Skills to inject:** hexagonal-spm, testing-pro, functional-core

#### Unit: w1-match

- **Title:** Match predicate to `ProposedAction`
- **Mode:** implement
- **Goal:** Pure `PolicyMatch.matches(predicate, action) -> Bool`.
- **Acceptance:**
  1. `gitPush(force: .force, branch: "main")` matches `GitAction.push` with `GitPushForce.force` and `resources.branchName == "main"` (or refspec that names main).
  2. Same predicate does not match a feature-branch force-push.
  3. Does not read `supportingCommand`.
- **Composition acceptance:** uses existing `GitAction` / `ActionResources` only.
- **Live smoke:** `tools/gate.sh RVDomainTests --filter PolicyMatch`
- **Depends on:** w1-predicate
- **Parallel-safe with:** w1-rule
- **Code paths (exclusive):** `Sources/RVDomain/PolicyMatch.swift`
- **Test paths (exclusive):** `Tests/RVDomainTests/PolicyMatchTests.swift`
- **Gates:**
  - `tools/gate.sh RVDomainTests --filter PolicyMatch`
- **Reject (local):** argv glob; npm
- **Residuals allowed:** refspec parsing enough for `main` vs `feature` fixtures used in tests
- **Fat?:** no
- **Skills to inject:** hexagonal-spm, testing-pro, evaluate-parity (do not change pack Decision)

#### Unit: w1-engine

- **Title:** Engine applies typed rules restrict-only
- **Mode:** implement
- **Goal:** `EffectiveActionPolicy` carries `[TypedRule]`; evaluate uses them after builtins.
- **Acceptance:**
  1. Matching typed **deny** on force-push main → `hardDeny` with that `RuleID`.
  2. Matching typed **allow** on force-push main cannot beat builtin shared-branch / `blocksAllowOverride` — still hardDeny.
  3. Matching typed **ask** on a non-hard force-push (feature branch) → `mandatoryHuman`.
- **Composition acceptance:** pack fallback still used when no semantic/typed hit; `git reset --hard` builtin/pack path unchanged.
- **Live smoke:** `tools/gate.sh RVDomainTests --filter ActionPolicyEngineTypedRule`
- **Depends on:** w1-rule, w1-match
- **Parallel-safe with:** none (`ActionPolicyEngine.swift` unique)
- **Code paths (exclusive):** `Sources/RVDomain/ActionPolicyEngine.swift` (and `EffectiveActionPolicy` in that file)
- **Test paths (exclusive):** `Tests/RVDomainTests/ActionPolicyEngineTypedRuleTests.swift`
- **Gates:**
  - `tools/gate.sh RVDomainTests --filter ActionPolicyEngineTypedRule`
  - `tools/gate.sh RVDomainTests --filter ActionPolicyEngine` (existing builtins still pass)
- **Reject (local):** reviewer bind; AFM
- **Residuals allowed:** `ask` maps to `mandatoryHuman` (no pack `Decision.ask`)
- **Fat?:** no
- **Skills to inject:** hexagonal-spm, functional-core, evaluate-parity, testing-pro

#### Unit: w1-store

- **Title:** Persist machine typed rules
- **Mode:** implement
- **Goal:** RVPolicy loads/saves `[TypedRule]` under the policy directory; merge restrict-only.
- **Acceptance:**
  1. `TypedRuleStore` round-trips a gitPush deny rule in a temp directory (not live HOME).
  2. Merge: builtin (engine) ⊳ machine ⊳ repo; a repo allow cannot drop a machine deny.
  3. No command text in the on-disk JSON beyond typed fields (branch name is a resource, not argv).
- **Composition acceptance:** `ActionPolicyEngine` is not imported into a new module; store returns Domain values.
- **Live smoke:** `tools/gate.sh RVPolicyTests --filter TypedRuleStore`
- **Depends on:** w1-rule, w1-engine
- **Parallel-safe with:** none
- **Code paths (exclusive):** `Sources/RVPolicy/TypedRuleStore.swift`
- **Test paths (exclusive):** `Tests/RVPolicyTests/TypedRuleStoreTests.swift`
- **Gates:**
  - `tools/gate.sh RVPolicyTests --filter TypedRuleStore`
- **Reject (local):** writing under real `~/.config/rv` in tests; fingerprint-only allowlist as the typed store
- **Residuals allowed:** existing `AllowlistStore` exact-command pins remain until W2
- **Fat?:** no
- **Skills to inject:** hexagonal-spm, testing-pro

#### Unit: w1-explain

- **Title:** Explanation names the typed rule
- **Mode:** implement
- **Goal:** When a typed rule fires, `ActionPolicyExplanation.ruleID` is that rule.
- **Acceptance:**
  1. Typed deny test: explanation.ruleID == saved TypedRule.id.
  2. Builtin hard deny (reset-hard / working-tree) still uses builtin RuleID when no typed rule needed.
  3. Do not add a new pack ExplainStep ID unless `rv explain` already has a semantic slot — prefer explanation on `ActionPolicyVerdict`.
- **Composition acceptance:** existing `rv explain` still runs (no CLI edit in this unit).
- **Live smoke:** `tools/gate.sh RVDomainTests --filter TypedRuleExplain`
- **Depends on:** w1-engine
- **Parallel-safe with:** w1-store
- **Code paths (exclusive):** only fields already on `ActionPolicyExplanation` / engine return; no new CLI files
- **Test paths (exclusive):** `Tests/RVDomainTests/TypedRuleExplainTests.swift`
- **Gates:**
  - `tools/gate.sh RVDomainTests --filter TypedRuleExplain`
- **Reject (local):** forking ExplainStep pipeline IDs; logging argv
- **Residuals allowed:** TTY pretty print of typed rules is W1 CLI
- **Fat?:** no
- **Skills to inject:** hexagonal-spm, testing-pro

#### Unit: w1-cli

- **Title:** `rv policy show`
- **Mode:** implement
- **Goal:** Operator can see built-in vs machine vs repo typed rules.
- **Acceptance:**
  1. `rv policy show` is a real subcommand on `RV`.
  2. Output names the three origins; empty machine/repo is honest, not fake rules.
  3. Temp HOME: exit 0; does not mint grants; does not call AFM.
- **Composition acceptance:** `RV.swift` subcommands list includes Policy; help mentions `policy`.
- **Live smoke:** Build with real HOME, then `HOME=$tmp .build/arm64-apple-macosx/debug/rv policy show`. Do not wrap `tools/swift-6.3.3` in temp HOME.
- **Depends on:** w1-store, w1-explain
- **Parallel-safe with:** none
- **Code paths (exclusive):** `Sources/RVCLI/Commands/PolicyCommand.swift`, `Sources/RVCLI/RV.swift` (subcommand array only)
- **Test paths (exclusive):** `Tests/RVCLITests/PolicyCommandTests.swift`
- **Gates:**
  - `tools/gate.sh RVCLITests --filter PolicyCommand`
- **Reject (local):** `rv policy draft` (W3); hook changes
- **Residuals allowed:** robot JSON optional if `--robot` already exists for other commands — match existing CLI style
- **Fat?:** no
- **Skills to inject:** hexagonal-spm, testing-pro, cli-for-agents if needed

---

### Wave W2 — Semantic Always-allow / Always-block (typed pin)

- **Depends on waves:** W1
- **mode:** standard
- **max_units:** 4
- **max_parallel:** 2
- **agent_budget:** 512
- **product_oracle_cmds:**
  - `tools/gate.sh RVPolicyTests RVDomainTests`
  - existing pin hard-stop tests still pass
- **Wave done when:** `RulePinning.preview` draft is a typed predicate JSON (or equivalent Codable form), not fingerprint-only; save writes `TypedRuleStore`; allow+hardStop still `allowedToSave == false`.

#### Unit: w2-preview

- **Title:** Preview is a typed form
- **Mode:** implement
- **Goal:** Replace opaque fingerprint draft for git push pins.
- **Acceptance:**
  1. Preview for a pending force-push main includes `PolicyPredicate.gitPush` + polarity.
  2. Sentence still human (“Always block force-push to main” / cannot-override).
  3. Existing IPC `rulePreview.sentence` tests updated, not deleted.
- **Live smoke:** `tools/gate.sh RVPolicyTests --filter RulePinning`
- **Depends on:** none (wave after W1)
- **Parallel-safe with:** none
- **Code paths (exclusive):** `Sources/RVPolicy/RulePinning.swift`
- **Test paths (exclusive):** `Tests/RVPolicyTests/RulePinningTests.swift`
- **Gates:** `tools/gate.sh RVPolicyTests --filter RulePinning`
- **Reject (local):** AFM; English
- **Residuals allowed:** non-git pending actions may keep fingerprint draft until process analyzer
- **Fat?:** no
- **Skills to inject:** hexagonal-spm, testing-pro, hook-xpc only if IPC envelope fields change

#### Unit: w2-save

- **Title:** Save writes TypedRule
- **Mode:** implement
- **Goal:** `RulePinStore.save` persists typed deny/allow (allow only if not hardStop).
- **Acceptance:**
  1. Block pin → machine TypedRule deny loadable by TypedRuleStore.
  2. Allow pin on hardStop throws `RulePinError.hardStop`.
  3. draftMismatch still throws if preview/save diverge.
- **Live smoke:** `tools/gate.sh RVPolicyTests --filter RulePinStore`
- **Depends on:** w2-preview
- **Parallel-safe with:** none
- **Code paths (exclusive):** `Sources/RVPolicy/RulePinStore.swift`
- **Test paths (exclusive):** `Tests/RVPolicyTests/RulePinStoreTests.swift` (extend)
- **Gates:** `tools/gate.sh RVPolicyTests --filter RulePin`
- **Reject (local):** dropping exact-command allowlist without a migration note
- **Residuals allowed:** old exact-command pins still honored until a later migration unit
- **Fat?:** no
- **Skills to inject:** hexagonal-spm, testing-pro

#### Unit: w2-service-preview

- **Title:** Service Always-allow uses typed preview
- **Mode:** implement
- **Goal:** Existing ServiceRuntime preview path still round-trips.
- **Acceptance:**
  1. IPC rulePreview `allowedToSave` false on secret/hard stop fixtures.
  2. Cancel still writes nothing (existing tests).
- **Live smoke:** `tools/gate.sh RVServiceTests --filter Pending` or current preview test filter
- **Depends on:** w2-save
- **Parallel-safe with:** none
- **Code paths (exclusive):** `Sources/RVService/ServiceRuntime.swift` only around RulePinning.preview call if signature changes
- **Test paths (exclusive):** existing `Tests/RVIPCTests/PendingAndRuleRoundTripTests.swift` if sentence/draft shape changes
- **Gates:** `tools/gate.sh RVServiceTests RVIPCTests --filter rulePreview` (adjust to actual filter that exists)
- **Reject (local):** companion UI
- **Residuals allowed:** createRule still does not run English
- **Fat?:** no
- **Skills to inject:** hexagonal-spm, hook-xpc if IPC, testing-pro

#### Unit: w2-verify-wall

- **Title:** Wall still holds after typed pins
- **Mode:** verify_only
- **Goal:** reset-hard / ssh / shared-branch still deny.
- **Acceptance:**
  1. Corpus or engine tests for reset-hard still deny.
  2. `blocksAllowOverride` tests still pass.
- **Live smoke:** `tools/gate.sh RVDomainTests RVEngineTests` (narrow filters if named)
- **Depends on:** w2-save
- **Parallel-safe with:** w2-service-preview
- **Code paths (exclusive):** none unless gate red
- **Test paths (exclusive):** none unless gap-fill
- **Gates:** `tools/gate.sh RVDomainTests --filter ActionPolicyEngine`
- **Reject (local):** new features
- **Residuals allowed:** none
- **Fat?:** no
- **Skills to inject:** evaluate-parity

---

### Wave W3 — English drafts the form (CLI, fake model)

- **Depends on waves:** W2
- **mode:** full
- **max_units:** 6
- **max_parallel:** 2
- **agent_budget:** 1024
- **product_oracle_cmds:**
  - `tools/gate.sh RVDomainTests RVPolicyTests RVCLITests`
  - `HOME=$(mktemp -d) tools/swift-6.3.3 run --skip-update rv policy draft --english "never allow force-push to main" --robot` → JSON with predicate gitPush force main, `allowedToSave` true, **no save**
  - same with `--save` then `rv policy show` lists a machine deny
  - `rv policy draft --english "be careful in prod"` → refuse, write nothing
- **Wave done when:** English in, typed preview out, save/cancel, fake compiler in tests, AFM optional Darwin path, uncompilable refused, ask beats allow, npm/mcp English refused.

Units (abbreviated; expand 1:1 at W3 launch, do not start in first run):

| id | Goal | Exclusive |
|----|------|-----------|
| w3-protocol | `EnglishCompiler` protocol in Domain: english → `RulePreview` with TypedRule draft or refuse | `EnglishCompiler.swift` |
| w3-fake | Deterministic fake: known sentences → gitPush forms; else refuse | tests |
| w3-ask-wins | Two rules ask+allow same predicate → ask | engine tests |
| w3-cli | `rv policy draft --english --save` | PolicyDraftCommand |
| w3-afm | Optional `FoundationModelsEnglishCompiler` in RVPolicy `#if canImport`; tests inject fake, never require Apple | AFM file |
| w3-refuse | npm / mcp / empty / “be careful” → refuse; store unchanged | tests |

W3 reject: hook bind, companion app, live HOME Apple as the only proof (Darwin manual AFM is extra, not the gate).

---

## 7. Integration acceptance (program complete)

W1 complete (first launch bar):

- [ ] `english-compile.md` + 02 pointer
- [ ] Typed deny force-push main matches
- [ ] Typed allow cannot un-block wall
- [ ] `rv policy show` works on temp HOME
- [ ] No scratch import, no hook Auto-review
- [ ] Residuals: fingerprint allowlist still exists until W2; no English yet

Program complete (after W3):

- [ ] English → preview → save → engine match without model on the second call
- [ ] Cancel writes nothing
- [ ] Uncompilable English refuses
- [ ] Ask beats allow
- [ ] Packs still deny reset-hard
- [ ] Residuals registered: MCP, npm, git status, companion UI, live Auto-review, Claude Ask

---

## 8. Launch recipes

Zig `implementor` / `implementor-program` / `plan-harden` are **out**. This is Swift. Use the project workflow `english-compile-swift`.

### Wave W1 (first session)

```text
workflow name=english-compile-swift
agent_budget=256
args={
  wave: "W1",
  mode: "full",
  repo: "/Users/chriskarani/CodingProjects/rv"
}
```

Paste-only: new Grok session, entire `planning/2026-09-04-english-compile/PROMPT.md`.

### Wave W2

```text
workflow name=english-compile-swift
agent_budget=128
args={ wave: "W2", mode: "standard", repo: "/Users/chriskarani/CodingProjects/rv" }
```

### Wave W3

```text
workflow name=english-compile-swift
agent_budget=256
args={ wave: "W3", mode: "full", repo: "/Users/chriskarani/CodingProjects/rv" }
```

---

## 9. PR / review plan

- One draft PR per wave on `feat/english-compile` (or stacked `feat/english-compile-w1`).
- After W1: Domain/Policy/CLI review; security light (no hook).
- After W3: `/multi-agent-swift-pr-review` with this plan; include evaluate-parity + hexagonal-spm. Adversarial on engine allow-override.
- Plan completeness lane must use this tree-truth ledger.
- Do not merge live Auto-review in these PRs.

---

## 10. Deferred programs (explicit)

| Program | Why deferred | Entry criteria |
|---------|--------------|----------------|
| Host Ask Claude (OPE-264) | 02.md before any live reviewer | Claude pauses; leftover-ask-as-permit gone |
| Companion English box | no Mac app | 247/248; IPC only |
| Live Auto-review (253) | Ask + TypedRule + shadow | 264 + W3 + 250 shadow log |
| Process/npm analyzer | no ProcessAction | own IR ticket; then extend PolicyPredicate |
| `ProposedAction.mcp` | shell-only IR | own program; Linear tools |
| AFM LoRA adapter | base model first | local disagreement corpus after shadow |
| Company admin UI | merge is files | repo typed-rule file is enough |
| Spike → product | throwaway | never |

---

## 11. Suggested workflow extensions (optional)

None required. Sequential waves via `english-compile-swift` (`wave: W1` then `W2` then `W3`). Do not stuff W2/W3 into the first launch. Do not call Zig implementor.
