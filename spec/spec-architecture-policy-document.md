---
title: Shareable policy document and English compile
version: 1.0
date_created: 2026-09-08
last_updated: 2026-09-08
owner: rv
tags:
  - architecture
  - design
  - schema
  - policy
  - english-compile
---

# Introduction

This specification is the implementation contract for rv's shareable policy document and the English-compile authoring path.

Users share a TOML file of **compiled typed rules**. They may author those rules in English. Apple Foundation Models fill a closed form. A human previews. Save writes the form. The hook matches the form with no model.

This program does not replace `docs/architecture/english-compile.md`. That file still wins for the three products, restrict-only overlay, Ask beats allow, and Foundation Models placement. This file wins for the on-disk shareable document, the TOML schema, import/export, and how English provenance sits beside the matcher.

A human must name this program. It is not the 0.2 execute queue (`docs/architecture/02.md` § Order).

# 1. Purpose & Scope

## Purpose

Give people one file they can commit, gist, or mail, and one authoring loop:

1. Type English (or paste a shared file).
2. rv shows a typed rule.
3. Save writes the typed rule into `policy.toml`.
4. Evaluate matches that rule. No model on the second call.

## Audience

Implementers of rv (Swift 6.3.3, macOS 26, Apple Silicon) using `tools/gate.sh`. Reviewers using the ticket DAG in §5b.

## In scope

- Format lock: TOML, not YAML, not a second JSON dialect for humans.
- Schema for `policy.toml` (machine and repo).
- Decode to existing `TypedRule` / `PolicyPredicate` values. Matcher unchanged.
- Optional `english` provenance on each rule. Provenance is not a matcher.
- `rv policy draft` English → preview → optional save into `policy.toml`.
- `rv policy export` / `apply` / `validate`.
- JSON `typed-rules.json` read-compat during migration.
- Wire `EffectiveActionPolicy.rules` from the loaded document into `applyGitSemantics` (today it passes `.empty`).
- Fail-closed load of an invalid policy document on evaluate.

## Out of scope

- YAML policy files, dual YAML+TOML, or a Markdown runtime format.
- Custom pack JSON / ICU regex packs written by users.
- Pack enablement (`config.toml` `[packs]`). A shared policy file must not disable the wall.
- Allowlist / denylist rows (`allowlist.toml`, `denylist.toml`). Repo allowlist stays inert.
- Saving English as the matcher.
- Live Auto-review / `ReviewBind.apply` on the hook.
- Host Ask (OPE-264/265), companion SwiftUI English box.
- `ProposedAction.mcp`, npm/process analyzer, `git status` as a `GitAction`.
- New SPM target.
- Foundation Models in RVDomain or RVEngine.
- New TOML library dependency in the first tickets (narrow dialect, same family as `AllowlistTOML`).
- Training Apple's base model.
- Foreign product names in user-facing copy.

## Assumptions

- W1 typed form exists: `PolicyPredicate.gitPush`, `TypedRule`, `TypedRuleStore` JSON `{ schemaVersion: 1, rules: [...] }`, `rv policy show`.
- W1 predicate remains git force-push only until a later analyzer program adds cases. The schema is closed: unknown `predicate` keys refuse the file.
- `ActionPolicyEngine` is pure and already honors typed rules when `EffectiveActionPolicy.rules` is non-empty. `applyGitSemantics` currently passes `policy: .empty`. That is a residual this program closes.
- Human-authored rv files already on disk: `config.toml`, `allowlist.toml`, `denylist.toml`. Machine ledgers stay JSON/JSONL (`allow-once.jsonl`, `pending-approvals.jsonl`).
- Tests never call live Apple. CLI tests inject `FakeEnglishCompiler`.
- `public enum RVDomain {}` shadows the module. English-compile preview type is `TypedRulePreview` in RVDomain, not `RVPolicy.RulePreview`.

# 2. Definitions

| Term | Meaning |
|---|---|
| **Wall** | Built-in hard deny plus day-one packs. Shared-branch force-push to `main` stays denied. Pack JSON is not this document. |
| **Compiled form** | Closed `PolicyPredicate` + `TypedRuleVerdict`. The hook matches this. |
| **Policy document** | On-disk TOML named `policy.toml`. The shareable unit. Decodes to compiled forms plus optional English provenance. |
| **English provenance** | The `english` string on a rule row. Human intent. Ignored by `PolicyMatch`. |
| **English compile** | Model (or fake) fills a closed form from English. Uncompilable English writes nothing. |
| **TypedRulePreview** | Preview value: plain-language sentence, draft document rule, `allowedToSave`. Distinct from `RVPolicy.RulePreview` (pin preview). |
| **Machine store** | `$HOME/.config/rv/policy.toml`. Origin `.machine`. |
| **Repo store** | `<workspace>/.rv/policy.toml`. Origin `.repo`. |
| **Legacy JSON** | `$HOME/.config/rv/typed-rules.json` and `<workspace>/.rv/typed-rules.json`. Read-compat only. |
| **Narrow TOML dialect** | The subset parsed by rv: `schema_version`, `[[rule]]` tables, listed keys, `#` comments, basic quoted strings. Same family as `AllowlistTOML`. |
| **Restrict-only merge** | invariants ⊳ machine ⊳ repo. Later layer may tighten verdict rank allow < ask < deny. It must not drop an earlier deny or ask. |
| **AFM** | Apple Foundation Models. Adapter in RVPolicy behind `#if canImport(FoundationModels)`. |

# 3. Requirements, Constraints & Guidelines

## Format lock

- **REQ-001**: The shareable policy document is TOML. rv shall not parse YAML policy, `.yml`, or `.yaml` as this document.
- **REQ-002**: Rationale that implementors must not reopen: human-authored rv files are already TOML (`config.toml`, `allowlist.toml`, `denylist.toml`); YAML is a new language plus a new decoder; JSON remains the machine ledger format and the W1 typed-rules IR, not the gist people share.
- **REQ-003**: One schema for machine, repo, export, and apply. Origin is assigned by **which path loaded the file**, never by a field inside the file.
- **REQ-004**: Filename is `policy.toml`. Machine path is `RVPolicyPaths.policyFile`. Repo path is `<workspace>/.rv/policy.toml`.
- **REQ-005**: Do not add Yams, a YAML decoder, or a full TOML package in this program. Parse with a dedicated `PolicyDocumentTOML` in RVPolicy, same style as `AllowlistTOML`.

## Document vs matcher vs wall

- **REQ-010**: `PolicyMatch` and `ActionPolicyEngine` consume `TypedRule` only. They shall not read `english`.
- **REQ-011**: Pack catalog JSON stays the wall. `policy.toml` shall not contain pack patterns, ICU, `enabled`, or `disabled`.
- **REQ-012**: `allowlist.toml` / `denylist.toml` stay separate. A policy document shall not contain `[[allow]]` or `exact_command`.
- **REQ-013**: Auto-review (`ActionReviewer`) is a third product. The policy document is not a prompt and not a reviewer bind.
- **REQ-014**: Three products stay separate in CLI copy: wall / compiled form / Auto-review.

## Schema

- **REQ-020**: Root requires `schema_version = 1`. Missing, non-integer, or any other version is invalid.
- **REQ-021**: Rules are `[[rule]]` array-of-tables. Zero rules is valid (empty overlay).
- **REQ-022**: Each rule requires `id` (canonical `RuleID` `pack:pattern`), `verdict` (`allow` \| `ask` \| `deny`), `predicate` (v1: `gitPush` only).
- **REQ-023**: For `predicate = "gitPush"`: optional `force` (`none` \| `forceWithLease` \| `force`); optional `branch` (non-empty string). Omitted `force` or `branch` means unspecified and matches any, same as `PolicyPredicate.gitPush(force:branch:)` nil fields. `force = "none"` is `GitPushForce.none`, not omit.
- **REQ-024**: Optional `english` string. Trimmed empty becomes nil. Stored as provenance on save when the compiler had English.
- **REQ-025**: Unknown keys on root or on a rule refuse the file. Unknown `predicate` values refuse the file. Unknown `verdict` / `force` refuse the file.
- **REQ-026**: Duplicate `id` in one file refuses. Duplicate `predicate` (equal `PolicyPredicate`) in one file refuses.
- **REQ-027**: `id` must parse as `RuleID`. Default compiler-assigned pack for gitPush is `typed.git` (valid `PackID`). Users may supply another valid `pack:pattern`. Invalid PackID refuses.
- **REQ-028**: The file shall not contain `origin`. Load stamps origin.
- **REQ-029**: `#` comments are allowed. Basic quoted strings are required in v1. Multiline literal strings are not required in v1; a multiline value is invalid.
- **REQ-030**: Render is deterministic: `schema_version` first, then rules in saved order, keys in the order `id`, `verdict`, `predicate`, `force` (if set), `branch` (if set), `english` (if set).

## Load / save / merge

- **REQ-040**: Decode TOML → `PolicyDocument` → `[TypedRule]` via `typedRules(origin:)`. English is dropped at this conversion.
- **REQ-041**: Machine load path: if `policy.toml` exists, load it. Else if legacy `typed-rules.json` exists, load JSON as today. If both exist, TOML wins and JSON is not merged.
- **REQ-042**: Repo load path: same preference under `.rv/`.
- **REQ-043**: Save (draft `--save`, apply, pin-to-typed) writes `policy.toml` and does not write new `typed-rules.json`. Existing JSON is left in place until uninstall or a later cleanup ticket.
- **REQ-044**: Merge remains `TypedRuleStore.merge(builtin:machine:repo:)` restrict-only. Repo allow cannot drop machine deny or ask. Machine allow cannot drop builtin deny or ask.
- **REQ-045**: Directory `0700`, file `0600` on write, same as typed-rules. Exclusive lock `.policy.lock` beside the file. Add both to `RVPolicyPaths.uninstallArtifacts`.
- **REQ-046**: Missing file → empty layer. Unreadable, invalid TOML, schema mismatch, unknown key, duplicate id/predicate → `PolicyDocumentError.invalidFile`.
- **REQ-047**: Evaluate / hook miss / TTY test that loads policy: `invalidFile` is **fail-closed** (indeterminate or deny via existing incomplete-eval path). It is not skip-overlay-and-allow. Allowlist's fail-open does not apply here.
- **REQ-048**: `rv policy show` still prints builtin / machine / repo. Invalid file: stderr `rv policy show: invalid policy file`, exit 1 (update copy from `invalid typed-rules file`).

## English compile

- **REQ-060**: `EnglishCompiler` protocol lives in RVDomain. Method: English string in, `TypedRulePreview` or typed refuse. No I/O. No Foundation Models import.
- **REQ-061**: `TypedRulePreview` fields: `sentence` (plain language of the form), `rule` (`PolicyDocumentRule` draft, origin unset), `allowedToSave` (false on hard-stop allow), `refusal` (nil on success).
- **REQ-062**: Uncompilable English (`"be careful in prod"`, empty, MCP/npm/`git status`, multiple unrelated actions) refuses. Writes nothing. Exit non-zero on CLI.
- **REQ-063**: v1 success shape is `predicate = gitPush` only. Compiler must not invent other predicates.
- **REQ-064**: Fake compiler in tests: table-driven English → form or refuse. Never requires Apple.
- **REQ-065**: `FoundationModelsEnglishCompiler` in RVPolicy, `#if canImport(FoundationModels)`, `usesSystemModel` test seam (same pattern as `FoundationModelsActionReviewer`). Unavailable / timeout / Linux → typed error, not a guessed allow.
- **REQ-066**: Production `rv policy draft` may call AFM when available. Tests inject the fake. The hook path shall not call `EnglishCompiler`.
- **REQ-067**: CLI: `rv policy draft --english "<text>"` prints preview and writes nothing. `--save` writes only when `allowedToSave` and preview succeeded. `--robot` / `--json` emit the preview struct, still no save unless `--save`.
- **REQ-068**: `--save` without `--english` is invalid usage.
- **REQ-069**: Save appends or replaces by equal `PolicyPredicate` in the **machine** store unless `--repo` is passed (writes workspace `.rv/policy.toml`). `--repo` still restrict-only at merge time.
- **REQ-070**: Ask beats allow remains engine law. A compiled ask and a compiled allow on the same predicate merge to ask.

## Share / apply / export

- **REQ-080**: `rv policy export` writes a policy document of **one** origin. Default: machine. `--repo` exports repo. It shall not export merged-effective (that would stamp mixed origins into a file with no origin field).
- **REQ-081**: Export includes `english` when the store still has it. Legacy JSON rules export with `english` omitted.
- **REQ-082**: `rv policy validate [PATH]` exit 0 on missing or valid; exit 2 on invalid. No HOME write. Default PATH is machine file if omitted.
- **REQ-083**: `rv policy apply PATH` loads PATH as a document (origin ignored), prints the same preview sentences `policy show` would use, and writes nothing unless `--save`. `--save` writes to machine (default) or `--repo`. Merge restrict-only with the destination layer's existing rules (destination file is one layer; do not drop existing tighter verdicts).
- **REQ-084**: Apply shall not recompile `english`. If a row has `english` and a compiled predicate, the predicate wins. A row with `english` and no predicate is invalid (refuse), not a compile trigger.
- **REQ-085**: Sharing English-only text is authoring: `rv policy draft --english`, not `apply`.

## Engine wire

- **REQ-090**: `applyGitSemantics` takes `policy: EffectiveActionPolicy = .empty` and passes it to `ActionPolicyEngine.evaluate`. Existing tests that omit it stay on `.empty`.
- **REQ-091**: EvaluationWorld / GatedEvaluate loads machine+repo (and builtin) via `TypedRuleStore.loadEffective`, sets `EffectiveActionPolicy.rules`, and passes that into `applyGitSemantics`. Engine still does not import RVPolicy.
- **REQ-092**: Pack deny / indeterminate remains a floor. Typed allow cannot weaken a pack deny. Typed deny may still deny when packs allow.
- **REQ-093**: Builtin hard deny still cannot be weakened by a typed allow (`RulePinning.blocksAllowOverride`, `ActionPolicyEngine` builtins).

## Constraints

- **CON-001**: No `RV_BYPASS`. No env a hook child honors to skip evaluate or skip this document.
- **CON-002**: No command text in `os_log`. `english` may contain command-like words; do not log the document body.
- **CON-003**: No live-HOME tests. Temp directories only.
- **CON-004**: No `class` in Domain/Engine/Policy. No `try!` / `!` on production paths.
- **CON-005**: Do not add `case ask` to pack `Decision`.
- **CON-006**: Do not import `scratch/english-review`.
- **CON-007**: Do not start Host Ask or companion UI from this spec.
- **CON-008**: Project allowlist stays inert. Applying a shared `policy.toml` into `.rv/` is typed restrict-only overlay, not an allowlist grant.
- **CON-009**: Do not present `rv-cli` as the CLI.

## Guidelines / patterns

- **GUD-001**: User-facing talk: "policy file" and "typed rule". Do not say "YAML policy" or "regex pack you share".
- **GUD-002**: Prefer one `[[rule]]` per closed action. Do not encode essays as one rule.
- **GUD-003**: Pin / always-allow that already writes `TypedRule` should write `policy.toml` through the same encoder once T2 lands.
- **PAT-001**: File/TOML edges stay `String`. In-memory domain uses `RuleID`, `PolicyPredicate`, `TypedRuleVerdict`.
- **PAT-002**: Closed world = enum (`PolicyPredicate`, verdict, force). Open world = `EnglishCompiler` protocol, fake in tests, AFM at RVPolicy.

# 4. Interfaces & Data Contracts

## 4.1 TOML schema (v1)

```toml
schema_version = 1

[[rule]]
id = "typed.git:force-push-main"
verdict = "deny"
predicate = "gitPush"
force = "force"
branch = "main"
english = "Never allow force-push to main"
```

| Key | Required | Values |
|---|---|---|
| `schema_version` | yes | integer `1` |
| `[[rule]]` | no | zero or more |
| `rule.id` | yes | `RuleID.rawValue` |
| `rule.verdict` | yes | `allow` / `ask` / `deny` |
| `rule.predicate` | yes | `gitPush` |
| `rule.force` | no | `none` / `forceWithLease` / `force` |
| `rule.branch` | no | non-empty string |
| `rule.english` | no | single-line string |

## 4.2 Domain types (shapes)

```swift
public struct PolicyDocument: Sendable, Equatable {
    public var schemaVersion: Int
    public var rules: [PolicyDocumentRule]
}

public struct PolicyDocumentRule: Sendable, Equatable {
    public var id: RuleID
    public var verdict: TypedRuleVerdict
    public var predicate: PolicyPredicate
    public var english: String?
}

public struct TypedRulePreview: Sendable, Equatable {
    public var sentence: String
    public var rule: PolicyDocumentRule
    public var allowedToSave: Bool
    public var refusal: EnglishCompileRefusal?
}

public enum EnglishCompileRefusal: Sendable, Equatable {
    case empty
    case uncompilable
    case unsupportedPredicate
    case hardStop
}

public protocol EnglishCompiler: Sendable {
    func compile(_ english: String) async throws -> TypedRulePreview
}
```

`PolicyDocumentRule.typedRule(origin:)` drops `english`.

## 4.3 Paths

| Layer | Path |
|---|---|
| Machine TOML | `$HOME/.config/rv/policy.toml` |
| Machine lock | `$HOME/.config/rv/.policy.lock` |
| Repo TOML | `<workspace>/.rv/policy.toml` |
| Repo lock | `<workspace>/.rv/.policy.lock` |
| Legacy machine JSON | `$HOME/.config/rv/typed-rules.json` |
| Legacy repo JSON | `<workspace>/.rv/typed-rules.json` |

`HOME` from process environment only. Do not read `XDG_CONFIG_HOME`.

## 4.4 CLI

| Command | Writes | Behavior |
|---|---|---|
| `rv policy show` | no | List builtin / machine / repo typed rules (existing). |
| `rv policy draft --english TEXT` | no | Compile, print preview. |
| `rv policy draft --english TEXT --save` | machine `policy.toml` | Compile, save if allowed. |
| `rv policy draft --english TEXT --save --repo` | repo `policy.toml` | Same, repo layer. |
| `rv policy validate [PATH]` | no | Exit 0/2. |
| `rv policy export [--repo] [--output PATH]` | stdout or PATH | One origin, TOML. |
| `rv policy apply PATH` | no | Preview document. |
| `rv policy apply PATH --save` | machine or `--repo` | Merge restrict-only into that layer. |

`--json` / `--robot` on draft/show/apply preview: JSON of the typed form, not English-as-matcher.

## 4.5 Engine seam

```swift
public func applyGitSemantics(
    pack: EvaluationResult,
    analysis: SemanticAnalysis,
    command: ShellCommand,
    context: GitAnalysisContext = .empty,
    enabledPacks: [PackID] = dayOnePackIDs,
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult
```

Assembly (RVService / GatedEvaluate) loads the document and passes `EffectiveActionPolicy(rules: merged)`.

## 4.6 Modules

| Shape | Module |
|---|---|
| `PolicyDocument`, `PolicyDocumentRule`, `TypedRulePreview`, `EnglishCompiler`, `EnglishCompileRefusal` | RVDomain |
| `PolicyDocumentTOML` parse/render, store load/save, AFM compiler | RVPolicy |
| `applyGitSemantics` policy argument | RVEngine |
| Load rules into evaluate | RVService (EvaluationWorld / GatedEvaluate) |
| `rv policy *` | RVCLI |

No new target.

# 5. Acceptance Criteria

- **AC-001**: Given a valid `policy.toml` with one gitPush deny on force+main, When decoded, Then `TypedRule.predicate == .gitPush(force: .force, branch: "main")` and `verdict == .deny`.
- **AC-002**: Given a rule with `english` set, When `PolicyMatch.matches` runs, Then only `predicate` is consulted.
- **AC-003**: Given `predicate = "gitStatus"` or an unknown key `pattern = ".*"`, When validate/load runs, Then `invalidFile` and no partial rules.
- **AC-004**: Given machine deny and repo allow on the same predicate, When merged, Then machine deny remains.
- **AC-005**: Given both `policy.toml` and `typed-rules.json` in the machine dir, When loadMachine runs, Then TOML rules are used and JSON is ignored.
- **AC-006**: Given only legacy JSON, When loadMachine runs, Then JSON rules load as today.
- **AC-007**: Given invalid `policy.toml` on the evaluate path, When a command would otherwise pack-allow, Then the result is not allow (fail-closed).
- **AC-008**: Given `rv policy draft --english "never allow force-push to main" --robot` with FakeEnglishCompiler, When run in temp HOME, Then JSON contains gitPush force main, `allowedToSave` true, and `policy.toml` is absent.
- **AC-009**: Given the same draft with `--save`, When run in temp HOME, Then `policy.toml` contains that `[[rule]]` and no `typed-rules.json` is created.
- **AC-010**: Given `rv policy draft --english "be careful in prod"`, When run, Then non-zero exit, no file write.
- **AC-011**: Given `rv policy apply shared.toml --save` where shared has deny and destination has allow on the same predicate, When saved, Then destination keeps deny.
- **AC-012**: Given `apply` of a file that has `english` but no `predicate`, When run, Then refuse, write nothing.
- **AC-013**: Given `applyGitSemantics` with a typed deny rule and pack allow on `git push --force origin main`, When `core.git` is enabled, Then hardDeny with that rule id.
- **AC-014**: Given typed allow on force-push main, When builtin shared-branch hard deny applies, Then still hardDeny (wall holds).
- **AC-015**: Given AFM unavailable, When `FoundationModelsEnglishCompiler.compile` is called with `usesSystemModel: true` on a non-Apple test seam, Then typed error, not a form.
- **AC-016**: `rg scratch/english-review Sources Package.swift` is empty.
- **AC-017**: Uninstall artifact list includes `policy.toml` and `.policy.lock`.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | `PolicyDocument` + `TypedRulePreview` + `EnglishCompiler` shapes | none | `Sources/RVDomain/PolicyDocument.swift`, `Sources/RVDomain/EnglishCompiler.swift`, `Tests/RVDomainTests/PolicyDocumentTests.swift` | Types exist; `typedRule(origin:)` drops english; protocol compiles | ≤100 |
| T2 | Narrow TOML parse/render | T1 | `Sources/RVPolicy/PolicyDocumentTOML.swift`, `Tests/RVPolicyTests/PolicyDocumentTOMLTests.swift` | AC-001, AC-002, AC-003, REQ-030 round-trip | 101–1499 |
| T3 | Store TOML + JSON fallback + paths | T2 | `Sources/RVPolicy/TypedRuleStore.swift`, `Sources/RVPolicy/RVPolicyPaths.swift`, `Tests/RVPolicyTests/TypedRuleStoreTests.swift` | AC-004, AC-005, AC-006, AC-017 | 101–1499 |
| T4 | `applyGitSemantics` takes policy | none | `Sources/RVEngine/ApplyGitSemantics.swift`, `Sources/RVEngine/ApplySemantics.swift`, `Tests/RVEngineTests/ApplyGitSemanticsTests.swift` (new or extend) | Default `.empty` preserves current tests; passing a deny rule denies on force-push main | 101–1499 |
| T5 | EvaluationWorld loads rules fail-closed | T3, T4 | `Sources/RVService/**` evaluate assembly only (EvaluationWorld / GatedEvaluate), `Tests/RVServiceTests/**` for AC-007/AC-013/AC-014 | AC-007, AC-013, AC-014 | 101–1499 |
| T6 | Fake compiler + `rv policy draft` | T1, T3 | `Sources/RVCLI/Commands/PolicyDraftCommand.swift`, `Sources/RVCLI/RV.swift`, `Tests/RVCLITests/PolicyDraftCommandTests.swift`, `Tests/RVPolicyTests/FakeEnglishCompiler.swift` (or Domain test fake) | AC-008, AC-009, AC-010 | 101–1499 |
| T7 | `validate` / `export` / `apply` | T3, T6 | `Sources/RVCLI/Commands/PolicyCommand.swift`, `Tests/RVCLITests/PolicyDocumentCommandTests.swift` | AC-011, AC-012, REQ-080–085 | 101–1499 |
| T8 | AFM adapter (optional runtime) | T1 | `Sources/RVPolicy/FoundationModelsEnglishCompiler.swift`, `Tests/RVPolicyTests/FoundationModelsEnglishCompilerTests.swift` | AC-015; tests `usesSystemModel: false`; no live Apple | 101–1499 |
| T9 | Law pointers | T3 | `docs/architecture/english-compile.md` (shareable document + TOML paths; JSON remains legacy), `CONTEXT.md` one-line, `docs/architecture/MODULES.md` PolicyDocument row | Greppable `policy.toml`; still says matcher is the form | ≤100 |

Frontier: T1 ∥ T4. T8 ∥ T2 after T1. T5 after T3+T4. T6 after T1+T3. T7 after T3+T6. T9 after T3.

T5 exclusive-writes must not edit `ApplyGitSemantics.swift` (T4 owns it) or `TypedRuleStore.swift` (T3 owns it).

# 6. Test Automation Strategy

- **Test levels**: Swift Testing unit tests in `RVDomainTests`, `RVPolicyTests`, `RVEngineTests`, `RVServiceTests`, `RVCLITests`. No live AFM. No live HOME.
- **Frameworks**: Swift Testing (`@Test`, `#expect`, `#require`). Temp directories via `FileManager` + UUID, `defer` cleanup.
- **Fixtures**: TOML strings in tests (valid, unknown key, bad version, duplicate id, english-only, JSON-legacy sibling). FakeEnglishCompiler table: force-push main deny; refuse "be careful in prod"; refuse empty.
- **Gate**: `tools/gate.sh RVDomainTests` then `RVPolicyTests` then `RVEngineTests` then `RVServiceTests` then `tools/gate.sh --filter Policy` (or PolicyDraft/PolicyDocument filter). Do not wipe `.build`.
- **Live smoke** (temp HOME, real binary after `tools/swift-6.3.3` build with real HOME):
  1. `HOME=$tmp rv policy show` → three origins, `(none)` ok.
  2. `HOME=$tmp rv policy draft --english "never allow force-push to main" --save` then `cat $tmp/.config/rv/policy.toml` contains `gitPush` and `deny`.
  3. `HOME=$tmp rv policy draft --english "be careful in prod"` → non-zero, no file.
  4. Invalid TOML in machine path → `rv test` / evaluate of an allowed `echo hi` is not a silent skip of overlay; show exits 1.
- **Coverage**: parse/render, JSON fallback, both-files TOML-wins, merge restrict-only, apply refuse english-only, engine wall vs typed allow, fail-closed invalid file.
- **Performance**: none. Compile is offline authoring, not hook.

# 7. Rationale & Context

W1 already locked the product: English is not the matcher. The missing piece is a file people can share without sending ICU pack JSON or a prompt.

YAML looks like a "policy document" to many tools. rv already picked TOML for every human-authored file. Adding YAML means a second config language, a decoder dependency, and implicit typing bugs (unquoted `no`, `off`, integers). TOML keeps comments, explicit strings, and the same parse family as allowlist.

JSON `typed-rules.json` is a fine IR and a bad gist: no comments, no `english` field today, and it sits next to lockfiles people should not mail. `policy.toml` is the share envelope. JSON remains read-compat so W1 installs do not break.

Repo allowlist is inert on purpose (a checkout must not grant itself). Repo `policy.toml` is different: it only **restricts** (deny/ask). A typed allow in repo still cannot drop machine or builtin deny. That is how a team can share "no force-push to main" without sharing an escape hatch.

English on the row is provenance for the next human. Recompiling on import would make two machines with two AFM versions disagree. Apply is byte-stable on the compiled keys.

`applyGitSemantics(..., policy: .empty)` means saved rules currently do not run on the hook. Sharing a file without T4/T5 is a souvenir. This program closes that residual.

# 8. Dependencies & External Integrations

### External Systems

- **EXT-001**: None. No network. No gist host. Share is a file.

### Third-Party Services

- **SVC-001**: Apple Foundation Models, on-device, optional. Authoring only. Timeout and unavailable are typed failures.

### Infrastructure Dependencies

- **INF-001**: `$HOME/.config/rv` and workspace `.rv/`. Process `HOME` only.
- **INF-002**: Exclusive file lock beside `policy.toml`.

### Data Dependencies

- **DAT-001**: Legacy `typed-rules.json` schemaVersion 1 (W1).
- **DAT-002**: Day-one packs still from RVPacks JSON. Not this file.

### Technology Platform Dependencies

- **PLT-001**: macOS 26, Apple Silicon, Swift 6.3 language mode 6. AFM compile requires FoundationModels when present; fake compiler does not.

### Compliance Dependencies

- **COM-001**: Factory hook-guard law: no bypass env, no allow-because-XPC-missed, no command text in `os_log`, no live-HOME tests (`docs/factory/PLAN.md`).

# 9. Examples & Edge Cases

## Valid share file

```toml
schema_version = 1

[[rule]]
id = "typed.git:force-push-main"
verdict = "deny"
predicate = "gitPush"
force = "force"
branch = "main"
english = "Never allow force-push to main"

[[rule]]
id = "typed.git:force-push-any"
verdict = "ask"
predicate = "gitPush"
force = "force"
```

Second rule: any branch, force only. Ask beats allow if a later layer adds allow on a subset; deny still wins over ask on the same predicate.

## Unspecified vs none

```toml
[[rule]]
id = "typed.git:push-main"
verdict = "ask"
predicate = "gitPush"
branch = "main"
```

Omitting `force` matches force, force-with-lease, and ordinary push to `main`.

```toml
[[rule]]
id = "typed.git:push-main-no-force"
verdict = "allow"
predicate = "gitPush"
force = "none"
branch = "main"
```

Matches only non-force. Cannot un-block builtin shared-branch force-push deny.

## Invalid files (must refuse)

```toml
schema_version = 1
[[rule]]
id = "typed.git:x"
verdict = "deny"
predicate = "gitPush"
pattern = "git push -f"
```

Unknown key `pattern`.

```toml
schema_version = 1
[[rule]]
id = "typed.git:x"
verdict = "deny"
english = "Never force-push main"
```

Missing `predicate`. Apply must not compile.

```toml
schema_version = 2
[[rule]]
id = "typed.git:x"
verdict = "deny"
predicate = "gitPush"
```

Wrong version.

```yaml
schema_version: 1
rules:
  - verdict: deny
```

YAML. Not a policy document. `apply` / validate → invalid.

## Authoring

```
rv policy draft --english "never allow force-push to main"
```

Preview (pretty):

```
Always block force-push to main
id typed.git:force-push-main deny gitPush force=force branch=main
allowedToSave true
```

`--save` writes the TOML example at the top of this section (compiler may choose the id slug; tests pin FakeEnglishCompiler's id).

# 10. Validation Criteria

1. `tools/gate.sh` on Domain, Policy, Engine, Service, and policy CLI filters is green.
2. AC-001 through AC-017 pass.
3. Live temp-HOME smokes in §6 pass.
4. `rg -n "Yams|yaml|\\.yml" Sources Tests` does not add a policy-document parser.
5. `rg scratch/english-review Sources Package.swift` has no hits.
6. `git reset --hard` still pack-denies (wall). Typed allow force-push main still hard-denies (wall).
7. Hook / evaluate does not call `EnglishCompiler`.
8. A staff review of the TOML dialect matches allowlist style (no new package).
9. `docs/architecture/english-compile.md` still says the matcher is the saved form; this spec is linked as the shareable document.

# 11. Related Specifications / Further Reading

- `docs/architecture/english-compile.md` — three products, compile pipeline, Ask beats allow, module placement
- `docs/architecture/MODULES.md` — hexagon
- `docs/architecture/02.md` — Host Ask / Auto-review **when** (not this program)
- `planning/2026-09-04-english-compile-implementable-program.md` — W1–W3
- `spec/spec-architecture-product-takes.md` — custom YAML packs remain out of v1 wall
- `docs/factory/specs/phase-3-allow.md` — allowlist TOML; repo allowlist inert
- `CONTEXT.md` — English compile vocabulary
- `docs/dev/SWIFT.md` — toolchain / gate
