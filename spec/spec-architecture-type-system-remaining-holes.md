---
title: Type-system remaining holes — gitPush force constraint, denial ledger, filesystem world
version: 1.0
date_created: 2026-09-14
last_updated: 2026-09-14
owner: rv
tags: [architecture, type-system, policy, history, filesystem]
---

# Introduction

Execute the three Strong candidates from `$TMPDIR/swift-type-system-review-rv-20260914-193635.html` (HEAD `466c1e6`, branch `main`).

1. **T1** — `PolicyPredicate.gitPush` force is `GitPushForceConstraint` (`any` | `exactly(GitPushForce)`). Top recommendation.
2. **T3** — `FilesystemAnalysisWorld` is `unprobed` | `probed(FilesystemAnalysisContext)`. Context loses the defaulted `probe` flag.
3. **T2** — `DenialLedgerRecord` host / tool / ruleID / category are closed types. jsonl keys frozen. Depends on T3 (`GatedEvaluate.swift`).

Do not execute worth-exploring C04 (`HookRequest` sum). Do not revive ProposedAction IR (OPE-156). Do not add `Decision.ask`. Do not change host deny JSON keys. Do not unify `PacksConfig.enabled: [String]`. Do not derive `RuleMatch.packID`.

Audience: fresh-context implementer and reviewer subagents. Toolchain: Swift 6.3.3 (`tools/swift-6.3.3`), language mode 6, macOS 26. Gate: `tools/gate.sh`. Warm `.build`. Never `swift package clean`. After the first compile in a worktree, `git restore Package.resolved` unless this ticket owns dependency changes.

# 1. Purpose & Scope

Make three illegal programs unrepresentable:

- `PolicyPredicate.gitPush(force: .none, branch: "main")` meaning unspecified and matching `--force`.
- `DenialLedgerRecord(host: "grep", ruleID: "not-a-rule", category: "ssh", ...)`.
- `FilesystemAnalysisContext(workingDirectory: cwd)` silently unprobed, skipping unresolved-path tighten.

## In scope

- RVDomain `PolicyPredicate` / `PolicyMatch` / `GitPushForceConstraint`.
- RVPolicy TOML mapper and English-compiler / pin call sites that bind `force` as `GitPushForce?`.
- RVDomain `FilesystemAnalysisWorld` + `FilesystemAnalysisContext` without `probe`.
- RVEngine analyze/apply/evaluate door using the world.
- RVScan `ScanClassify` probe mapping.
- RVService `FilesystemLiveProbe`, `EvaluateSession`, `GatedEvaluate` probe closures.
- RVHistory `DenialLedgerRecord` in-memory types + jsonl custom Codable.
- GatedEvaluate ledger append + `host`/`tool` parameters after T3.

## Out of scope

- HookRequest product → sum (C04).
- DoctorCheckID T7 host cases.
- ScanFinding.packID derived (RuleMatch C4 sibling).
- UnlockableDeny pin-order bugfix (two-line, not this spec).
- HomePath newtype / `lexicalFilesystemPath` String swap.
- SessionIdentity empty.
- SemVer / ProtocolName newtypes.
- HostCodec as enum.
- C `rv` hook. Host adapter templates. Analytics `Any`.

# 2. Definitions

| Term | Meaning |
|---|---|
| Force constraint | Whether a gitPush matcher is unspecified (any force) or pinned to one `GitPushForce`. |
| Unspecified force | TOML omitted `force`. In-memory `.any`. Matches `--force`, `--force-with-lease`, and non-force. |
| Non-force | TOML `force = "none"`. In-memory `.exactly(.none)`. Does not match `--force`. |
| Filesystem world | Whether path I/O was injected. Unprobed: pack deny is the floor; unresolved-path does not tighten an allow. Probed: missing cwd/root stays fail-closed unknown. |
| Ledger host | `tty` (operator / TTY test) or a `HookHost`. |
| Ledger tool | `Bash` (shell) or `FileToolKind.ledgerName` (`Read` / `Edit` / `Write`). |
| Ledger category | Either the deny pack or a `SecretPathCategory` when the matched text hit the catalog. |
| jsonl freeze | Keys `host`, `tool`, `rule_id`, `category`, `path`, `timestamp` stay strings. |

# 3. Requirements, Constraints & Guidelines

## T1 — GitPushForceConstraint

- **REQ-101**: Add in RVDomain:

  ```swift
  public enum GitPushForceConstraint: Sendable, Equatable {
      case any
      case exactly(GitPushForce)
  }
  ```

  `PolicyPredicate.gitPush(force: GitPushForceConstraint, branch: String?)`.
- **REQ-102**: `PolicyMatch.matchesGitPush`: `.any` does not compare force; `.exactly(want)` requires `want == action.force`. Branch nil stays unspecified. `GitPushForce.none` is non-force, not unspecified.
- **REQ-103**: `PolicyPredicate.gitPush(force: .none, …)` and `force: nil` do not compile. Tests that used `force: nil` use `.any`. Tests that used `GitPushForce.none` use `.exactly(.none)`. Tests that used `.force` use `.exactly(.force)`.
- **REQ-104**: policy.toml unchanged: omitted `force` ↔ `.any`; `force = "none"` ↔ `.exactly(.none)`; `force = "force"` ↔ `.exactly(.force)`; `force = "forceWithLease"` ↔ `.exactly(.forceWithLease)`. Unknown force still refuses the file.
- **REQ-105**: JSON Codable for `PolicyPredicate`: omit or null force encodes/decodes as `.any`. String force uses existing `GitPushForce` raw values. A golden test pins omit ≠ `"none"`.
- **REQ-106**: `RulePinning`, `PolicyDocumentTOML`, `FoundationModelsEnglishCompiler`, `PolicyDraftCommand`, `FakeEnglishCompiler` bind `GitPushForceConstraint`, not `GitPushForce?`.
- **CON-101**: No generics. No phantom `Predicate<ForceState>`. Do not change `GitAction.push`’s `force: GitPushForce` (that is the action, not the matcher).
- **GUD-101**: First failing tests: PolicyMatch any-force matches `--force`; exactly-none does not. Then change the type. Do not paper over compile errors with `.rawValue`.

## T3 — FilesystemAnalysisWorld

- **REQ-301**: Add in `SemanticAnalysis.swift`:

  ```swift
  public enum FilesystemAnalysisWorld: Sendable, Equatable {
      case unprobed
      case probed(FilesystemAnalysisContext)
  }
  ```

- **REQ-302**: Delete `FilesystemProbeState` and `FilesystemAnalysisContext.probe`. Delete the default `probe: .unprobed`. `FilesystemAnalysisContext.empty` remains the empty probed payload (no cwd, no facts) used only inside `.probed` when a live probe ran with missing cwd — or callers pass `.unprobed` when no world was injected. **Nil store cwd / default evaluate door is `.unprobed`, not `.probed(.empty)`.**
- **REQ-303**: `evaluateWithSemantics`’s `filesystemProbe` returns `FilesystemAnalysisWorld`, default `{ _ in .unprobed }`.
- **REQ-304**: `applyFilesystemSemantics` / `applySemantics` take `FilesystemAnalysisWorld` (or `filesystemContext` renamed). Unprobed: do not apply unresolved-path tighten; pack floor still holds. Probed: today’s probed behavior (missing cwd/root fail-closed unknown; protected-path still tightens).
- **REQ-305**: `analyzeSemantics` must not rebuild `FilesystemAnalysisContext(...)` omitting probe. Pass the world (or the probed context fields) through. The current rebuild at `AnalyzeSemantics.swift` (~49–55) is the footgun.
- **REQ-306**: `ScanClassify.lexicalFilesystemContext`: nil event cwd → `.unprobed`; non-nil cwd → `.probed(FilesystemAnalysisContext(workingDirectory:cwd, catalog:.dayOne, facts:[]))`.
- **REQ-307**: `FilesystemLiveProbe.context` returns `.probed(...)`. Always probed, including missing cwd (facts may be uncertain). GatedEvaluate / EvaluateSession pass that world into the door.
- **REQ-308**: A test proves `FilesystemAnalysisContext(workingDirectory: cwd)` (no probe argument) does not compile, or if the memberwise init remains, that apply with `.unprobed` does not unresolved-deny a pack-allow write. Prefer the enum so the dangerous combo is unrepresentable.
- **CON-301**: No `Context<Probed>` phantom. No HomePath newtype in this ticket.
- **CON-302**: Exclusive writes listed below. T1 must not edit these files.
- **GUD-301**: Engine tests that built `FilesystemAnalysisContext(probe: .probed)` construct `.probed(FilesystemAnalysisContext(...))`.

## T2 — Denial ledger types (depends on T3)

- **REQ-201**: Add in RVHistory (or RVDomain if History would otherwise import nothing new — History already imports Foundation only; HookHost / RuleID / FileToolKind / PackID / SecretPathCategory are RVDomain). RVHistory already depends on RVDomain. Put the ledger enums next to `DenialLedgerRecord`:

  ```swift
  public enum LedgerHost: Sendable, Equatable {
      case tty
      case hook(HookHost)
  }
  public enum LedgerTool: Sendable, Equatable {
      case bash
      case file(FileToolKind)
  }
  public enum LedgerCategory: Sendable, Equatable {
      case pack(PackID)
      case secret(SecretPathCategory)
  }
  ```

- **REQ-202**: `DenialLedgerRecord.host: LedgerHost`, `tool: LedgerTool`, `ruleID: RuleID`, `category: LedgerCategory`. `path` stays redacted `String`.
- **REQ-203**: jsonl keys unchanged. Encode: `tty` / HookHost raw value; `Bash` / `Read`/`Edit`/`Write`; `rule_id` as `RuleID.rawValue`; category as pack raw value or secret category raw value (same bytes as today). Decode unknown host/tool/rule/category: throw (ledger load already skips failed lines).
- **REQ-204**: `GatedEvaluate` run signatures take `host: LedgerHost = .tty`, `tool: LedgerTool = .bash` instead of `String`. `recordDenialIfNeeded` constructs the typed record. Secret-catalog matched text still selects `.secret(category)`; else `.pack(deny.ruleID.pack)`.
- **REQ-205**: `ServiceRuntime` / `ServiceClient` callers that pass `host: "tty"` use `.tty`. Hook miss/rvd that pass a host string use `.hook(host)` from the already-typed `HookHost`.
- **REQ-206**: Pretty `rv blocks` still prints the same string columns. Robot JSON may keep string fields via encode.
- **CON-201**: Do not persist command text. Do not change redaction. Do not log argv.
- **CON-202**: T2 owns `GatedEvaluate.swift` after T3; do not rebase-edit T3 probe lines except to keep them compiling if the merge requires it.
- **GUD-201**: Byte-identical jsonl for a grok Bash `core.git:reset-hard` row and a Read `core.secrets` row.

## Shared

- **CON-001**: Swift 6.3.3, language mode 6, value types only in Domain/Engine/Packs/Presentation/Policy/Hooks/IPC/Scan/History. `class` only at XPC edge.
- **CON-002**: Exclusive writes per ticket. No drive-by.
- **CON-003**: No `try!` / IUO on production paths. No live-HOME tests. No `RV_BYPASS`. No command text in `os_log`.
- **CON-004**: `tools/gate.sh` with warm `.build`. Do not wipe `.build`. Restore `Package.resolved` after first worktree resolve if it changes.
- **PAT-001**: Closed enums + exhaustive switches. Codable at the wire/jsonl door.
- **GUD-001**: TDD: failing tests first, then types, then callers.
- **PAT-002**: Specialist: `swift-type-system-architecture`, `swift-testing-pro`. T2 also product vocabulary in `CONTEXT.md` (block ledger).

# 4. Interfaces & Data Contracts

```swift
public enum GitPushForceConstraint: Sendable, Equatable {
    case any
    case exactly(GitPushForce)
}

public enum PolicyPredicate: Sendable, Equatable, Codable {
    case gitPush(force: GitPushForceConstraint, branch: String?)
}

public enum FilesystemAnalysisWorld: Sendable, Equatable {
    case unprobed
    case probed(FilesystemAnalysisContext)
}

public struct FilesystemAnalysisContext: Sendable, Equatable, Codable {
    public var workingDirectory: WorkingDirectory?
    public var repositoryRoot: RepositoryRoot?
    public var homeDirectory: String?
    public var catalog: SecretPathCatalog
    public var facts: [FilesystemPathFact]
    // no probe
}

public enum LedgerHost: Sendable, Equatable { case tty, hook(HookHost) }
```

TOML: `force` omitted ↔ `.any`. jsonl: `"host":"tty"` / `"host":"grok"`.

# 5. Acceptance Criteria

- **AC-101**: `PolicyMatch.matches(.gitPush(force: .any, branch: "main"), forcePushToMain)` is true. `matches(.gitPush(force: .exactly(.none), branch: "main"), forcePushToMain)` is false.
- **AC-102**: `PolicyPredicate.gitPush(force: nil, …)` and `force: .none` (Optional/unconstrained) do not compile. `force: GitPushForce.none` as the associated value does not compile.
- **AC-103**: policy.toml omit vs `force = "none"` round-trip as `.any` vs `.exactly(.none)`.
- **AC-301**: Default `evaluateWithSemantics` probe is `.unprobed`. ScanClassify with nil event cwd is `.unprobed` and does not unresolved-deny a pack-allow write.
- **AC-302**: Live `FilesystemLiveProbe` result is `.probed`. Missing cwd on a probed world still fail-closed unknown for mutating operations when `core.filesystem` is enabled (existing tests).
- **AC-303**: `analyzeSemantics` does not construct `FilesystemAnalysisContext` without passing through the caller’s world (no omitted-probe rebuild).
- **AC-201**: `DenialLedgerRecord(host: "tty", tool: "Bash", ruleID: "x", …)` does not compile.
- **AC-202**: jsonl for host tty + tool Bash + `core.git:reset-hard` matches today’s keys and string values.
- **AC-203**: Unknown jsonl host line is skipped (decode throw → existing skip), not stored as a raw string.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | GitPushForceConstraint | none | `Sources/RVDomain/PolicyPredicate.swift`, `Sources/RVDomain/PolicyMatch.swift`, `Sources/RVDomain/FakeEnglishCompiler.swift`, `Sources/RVPolicy/PolicyDocumentTOML.swift`, `Sources/RVPolicy/RulePinning.swift`, `Sources/RVPolicy/FoundationModelsEnglishCompiler.swift`, `Sources/RVCLI/Commands/PolicyDraftCommand.swift`, `Tests/RVDomainTests/PolicyPredicateTests.swift`, `Tests/RVDomainTests/PolicyMatchTests.swift`, `Tests/RVDomainTests/PolicyDocumentTests.swift`, `Tests/RVDomainTests/TypedRuleTests.swift`, `Tests/RVDomainTests/TypedRuleAskWinsTests.swift`, `Tests/RVDomainTests/TypedRuleExplainTests.swift`, `Tests/RVDomainTests/ActionPolicyEngineTypedRuleTests.swift`, `Tests/RVDomainTests/EnglishCompilerTests.swift`, `Tests/RVDomainTests/EnglishRefuseTests.swift`, `Tests/RVDomainTests/FakeEnglishCompilerTests.swift`, `Tests/RVPolicyTests/TypedRuleStoreTests.swift`, `Tests/RVPolicyTests/PolicyDocumentTOMLTests.swift`, `Tests/RVPolicyTests/RulePinningTests.swift`, `Tests/RVPolicyTests/RulePinStoreTests.swift`, `Tests/RVPolicyTests/FoundationModelsEnglishCompilerTests.swift`, `Tests/RVCLITests/PolicyCommandTests.swift`, `Tests/RVCLITests/PolicyDraftCommandTests.swift`, `Tests/RVEngineTests/ApplyGitSemanticsTests.swift`, `Tests/RVEngineTests/ApplyGitSemanticsTypedRuleTests.swift`, `Tests/RVServiceTests/PendingResolveGrantTests.swift`, `Tests/RVServiceTests/GatedEvaluateTypedRuleLoadTests.swift` | AC-101, AC-102, AC-103 | 101–1499 |
| T3 | FilesystemAnalysisWorld | none | `Sources/RVDomain/SemanticAnalysis.swift`, `Sources/RVEngine/AnalyzeSemantics.swift`, `Sources/RVEngine/AnalyzeFilesystem.swift`, `Sources/RVEngine/ApplyFilesystemSemantics.swift`, `Sources/RVEngine/ApplySemantics.swift`, `Sources/RVEngine/EvaluateWithSemantics.swift`, `Sources/RVScan/Classify/ScanClassify.swift`, `Sources/RVService/FilesystemLiveProbe.swift`, `Sources/RVService/EvaluateSession.swift`, `Sources/RVService/GatedEvaluate.swift`, `Tests/RVEngineTests/ApplyFilesystemSemanticsTests.swift`, `Tests/RVEngineTests/ApplySemanticsTests.swift`, `Tests/RVEngineTests/AnalyzeSemanticsTests.swift`, `Tests/RVEngineTests/EvaluateWithSemanticsTests.swift`, `Tests/RVEngineTests/ApplySemanticsSinkTests.swift`, `Tests/RVEngineTests/AnalyzeFilesystemTests.swift`, `Tests/RVScanTests/**` as needed for classify probe, `Tests/RVServiceTests/**` as needed for live probe compile | AC-301, AC-302, AC-303 | 101–1499 |
| T2 | Typed denial ledger | T3 | `Sources/RVHistory/DenialLedgerRecord.swift`, `Sources/RVHistory/DenialLedger.swift`, `Sources/RVService/GatedEvaluate.swift`, `Sources/RVService/ServiceRuntime.swift` (host/tool arguments only), `Sources/RVCLI/Service/ServiceClient.swift` (host argument only), `Sources/RVCLI/Commands/BlocksCommand.swift`, `Tests/RVHistoryTests/DenialLedgerTests.swift`, `Tests/RVCLITests/BlocksCommandTests.swift`, other tests that construct `DenialLedgerRecord` or pass `host: "tty"` into GatedEvaluate | AC-201, AC-202, AC-203 | 101–1499 |

T1 and T3 do not share exclusive-writes. Parallel. T2 starts from T3’s branch (`arch/<run>/T3`).

If a test file constructs `PolicyPredicate.gitPush` and was omitted above, T1 still owns it — grep `gitPush(force:` and include it rather than leaving the package unbuildable (exclusive-writes are a collision fence, not a compile set).

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit in RVDomainTests, RVPolicyTests, RVEngineTests, RVHistoryTests, RVScanTests, RVServiceTests, RVCLITests as listed.
- **Frameworks**: Swift Testing. No XCTest. No live HOME.
- **CI**: `tools/gate.sh RVDomainTests` (T1; then RVPolicyTests / RVCLITests / RVEngineTests / RVServiceTests as those files compile). T3: `RVEngineTests` then `RVScanTests` then `RVServiceTests`. T2: `RVHistoryTests` then `RVCLITests` then `RVServiceTests`.
- **Coverage**: any vs exactly-none match; TOML omit vs none; unprobed pack-allow write; probed missing-cwd fail-closed; jsonl skip unknown host.

# 7. Rationale & Context

Prior type-system specs closed Decision/outcome, HelloAck, pack-door vs Ask, WorkingDirectory, ScanTimeWindow, HookVoiceNext, AllowOnceLifecycle, leftover IPC consume. Remaining holes are a documented Optional.none trap on the English-compile form, a product denial list stored as strings, and a defaulted probe flag the Domain comment already calls a footgun.

# 8. Dependencies & External Integrations

- **PLT-001**: Swift 6.3.3, language mode 6, macOS 26.
- **DAT-001**: policy.toml force omit/`none` bytes unchanged. blocks.jsonl keys unchanged.
- **COM-001**: Host deny JSON is the block; do not change keys.

# 9. Examples & Edge Cases

```swift
// T1
PolicyMatch.matches(.gitPush(force: .any, branch: "main"), forcePush) // true
PolicyMatch.matches(.gitPush(force: .exactly(.none), branch: "main"), forcePush) // false
// PolicyPredicate.gitPush(force: .none, branch: "main") // does not compile

// T3
evaluateWithSemantics(request, packs:…, patterns:…, compiled:…) // unprobed
FilesystemLiveProbe.context(...) // .probed
ScanClassify nil cwd // .unprobed

// T2
DenialLedgerRecord(..., host: .tty, tool: .bash, ruleID: deny.ruleID, category: .pack(.coreGit), ...)
// json: {"host":"tty","tool":"Bash","rule_id":"core.git:reset-hard","category":"core.git",...}
```

# 10. Validation Criteria

Each ticket: `tools/gate.sh` for that ticket’s test targets green. No new `TODO`/`FIXME` in production. No `RV_BYPASS`. policy.toml / jsonl bytes as specified. `git restore Package.resolved` if the first worktree resolve rewrote it.

# 11. Related Specifications / Further Reading

- `spec/spec-architecture-type-system-remaining-closures.md` (landed)
- `spec/spec-architecture-policy-document.md` REQ-023
- `docs/architecture/english-compile.md`
- `docs/architecture/MODULES.md`
- HTML: `swift-type-system-review-rv-20260914-193635.html`
