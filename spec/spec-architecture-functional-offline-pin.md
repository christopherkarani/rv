---
title: Offline scan facts and analysis-backed pin/pending
version: 1.0
date_created: 2026-09-13
last_updated: 2026-09-13
owner: rv
tags:
  - architecture
  - design
  - functional-core
  - scan
  - policy
---

# Introduction

This specification implements the two Strong candidates from the 2026-09-13 functional-evolution review (HTML: `/var/folders/ns/xmz0zmpj7p148vdgr4bwzp8h0000gn/T/swift-functional-evolution-rv-20260913-000839.html`).

1. **C1:** `ScanClassify` injects explicit unprobed filesystem facts into `evaluateWithSemantics`. Pack-allow writes must not become `builtin.action:unresolved-path` because nobody probed. Live evaluate with a probe that cannot decide stays fail-closed.
2. **C2:** Host Ask pending rows and `RulePinning` read `SemanticAnalysis` values. Keep the host-door fingerprint. Delete toy argv parsers and the `Deny`-only pin list.

Do not implement OPE-156 (IR + fingerprint through every HostCodec). Do not fold hook miss into `HookDoor`. Do not expand `PolicyPredicate` beyond `gitPush`. Do not retire `EvaluateSession.evaluate` or `apply*(pack:command:)` (Worth exploring; not this spec).

# 1. Purpose & Scope

## Purpose

Complete the evaluation door’s injection contract for offline scan, and stop reconstructing pin/preview from empty codec shells after analysis already ran.

## Audience

Implementers of rv (Swift 6.3.3, language mode 6, macOS 26 Apple Silicon, Linux aarch64/x86_64) using `tools/gate.sh` and `tools/swift-6.3.3`. Warm `.build`. Do not wipe `.build`.

## In scope

- `FilesystemScope.unprobed` distinct from live `.unknown`.
- `FilesystemAnalysisContext.unprobed(...)` factory. Empty context stays **live** fail-closed.
- Engine classification and `ActionPolicyEngine.filesystemHit` honor unprobed (no unresolved hard deny).
- Catalog / protected-path still classifies on lexical paths when unprobed.
- `ScanClassify` passes unprobed context into `evaluateWithSemantics`.
- Analysis-backed `ProposedAction` for pending record: same `ActionFingerprint.make(host:session:cwd:command)` identity, effects/resources from git or filesystem analysis.
- `PendingApproval` carries `SemanticAnalysis` so unwrap-limited and pin preview do not re-tokenize argv.
- `RulePinning.hardStop` / preview use analysis + catalog `firstMatch`. Delete `unwrapLimitedCommand` and the private path-candidate loop.
- `RulePinning.blocksAllowOverride(Deny)` deleted. `RebaseRecovery` keeps the working-tree-discard exception locally.

## Out of scope

- OPE-156 HostCodec IR / changing fingerprint spelling.
- `FilesystemLiveProbe` moving into RVScan or RVEngine.
- RVScan importing RVPolicy, RVService, RVHooks, RVCLI, RVTUI.
- Scan Policy gate / allow-once honor.
- Injecting typed `EffectiveActionPolicy` into scan (allowed later; this spec may pass `.empty`).
- Live HOME tests.
- New SPM modules, new dependencies, toolchain bumps.
- `LiveEvaluation` as the only in-process type.
- Doctor baked `rv-cli` re-parse.
- English compile / new `PolicyPredicate` cases.

## Assumptions

- `evaluateWithSemantics` is the product door (#202). Pack deny / indeterminate is a floor.
- Live `GatedEvaluate` injects `FilesystemLiveProbe`. Missing cwd after a live probe still fail-closes as unresolved.
- `HostCodec.proposedAction` default empty-effect shell remains valid for fingerprint identity.
- `HookDoor.clearPending` matches identity + fingerprint only. Fingerprint must not change.
- `UnlockableDeny.isPinned(EvaluationResult)` remains the spend / Ask pin.
- Hexagonal graph in `docs/architecture/MODULES.md` is law.

# 2. Definitions

| Term | Meaning |
|---|---|
| **Live probe** | `FilesystemLiveProbe` ran. Uncertain resolution / missing repo root is `.unknown` and fail-closes. |
| **Unprobed** | Caller injected no path/repo facts. Not the same as live-uncertain. Pack verdict stands for ordinary writes. |
| **Offline facts** | Values `ScanClassify` passes into the Engine door: unprobed filesystem context, empty git context, empty policy unless a later ticket injects rules. |
| **Host-door fingerprint** | `ActionFingerprint.make(host:session:cwd:command)`. Pending identity. |
| **Semantic fingerprint** | `GitAction` / `FilesystemAction` fingerprint strings. Must not replace host-door fingerprint in this spec. |
| **Toy parser** | `RulePinning`’s `unwrapLimitedCommand` / whitespace token secret loop. |
| **Working-tree exception** | Rebase recovery may lift `builtin.action:working-tree-discard` when rebase is in progress. Secrets, protected-path, unwrap-limited stay pinned. |

# 3. Requirements, Constraints & Guidelines

## Unprobed filesystem (C1 / T1)

- **REQ-001**: Add `FilesystemScope.unprobed` to the closed enum. Codable raw value `unprobed`.
- **REQ-002**: `FilesystemAnalysisContext` shall expose `public static func unprobed(homeDirectory: String? = nil, catalog: SecretPathCatalog = .dayOne) -> FilesystemAnalysisContext` that sets an explicit unprobed mode. `FilesystemAnalysisContext.empty` and the default memberwise empty value remain **live**.
- **REQ-003**: `analyzeFilesystem` with unprobed context shall classify catalog hits as `.protectedPath`. Non-catalog targets with no repository root shall be `.unprobed`, not `.unknown`.
- **REQ-004**: `FilesystemAction.effectKinds` shall append `.unresolvedFilesystem` for `.unknown` or `.uncertain` live targets. It shall **not** append that kind solely because a target is `.unprobed`.
- **REQ-005**: `ActionPolicyEngine.filesystemHit` shall hard-deny unresolved for `.unresolvedFilesystem`, `.unknown`, or nil scope. Scope `.unprobed` without protected/outside hits shall be semantically uncovered (pack fallback), not `Builtin.unresolvedFilesystem`.
- **REQ-006**: Protected-path mutation on unprobed lexical catalog hits remains `Builtin.protectedPath` hard deny (same as live).
- **REQ-007**: `applyFilesystemSemantics(pack:command:)` with default empty context (`missingRepositoryRoot_isFailClosed`) shall still deny. Unprobed is opt-in via the factory, never via forgetting to pass context.
- **CON-001**: Do not change `FilesystemLiveProbe` behavior for nil cwd.
- **CON-002**: Do not add a second evaluate function. Callers keep `evaluateWithSemantics(..., filesystemProbe:)`.
- **GUD-001**: Prefer one probe-mode flag or the new scope case, not both overlapping booleans.
- **PAT-001**: Functional core: shell chooses live vs unprobed values; Engine stays pure.

## ScanClassify (C1 / T2)

- **REQ-008**: `ScanClassify.classify` shall call `evaluateWithSemantics` with `filesystemProbe` returning `FilesystemAnalysisContext.unprobed(homeDirectory:)` (home may be nil).
- **REQ-009**: Pack-allow commands that are ordinary writes (`echo hi > file`, `rm file`) shall **not** produce a finding with `ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID`.
- **REQ-010**: `git reset --hard` remains a `core.git:reset-hard` finding. Unwrap-limited (`python -c "mystery(payload)"`) remains a finding.
- **REQ-011**: Catalog-shaped mutating paths (`rm ~/.ssh/config`) may still deny via protected-path or pack/secret rules without FileManager.
- **REQ-012**: `SessionScan` may pass `ScanHome`’s home string into `ScanClassify` for `~` expansion. Classify still must not import RVService or call `FilesystemLiveProbe`.
- **CON-003**: RVScan must not import RVPolicy, RVHistory, RVService, RVCLI, RVTUI, RVHooks.
- **CON-004**: Scan still must not honor allow-once or write ledger files (existing ClassifyTests).
- **GUD-002**: Typed rules stay `.empty` in this spec.

## Analysis-backed pending and pin (C2 / T3)

- **REQ-013**: After evaluate on first-call, `recordHostAsk` shall receive a `ProposedAction` whose fingerprint is `ActionFingerprint.make(host:session:cwd:command)` and whose `effects` / `resources` come from `result.analysis.gitAction` or `result.analysis.filesystemAction` when present.
- **REQ-014**: `PendingApproval` (and the create request used by `HookDoor.recordPending`) shall carry `analysis: SemanticAnalysis` (decode missing as `.unknown` for old JSON).
- **REQ-015**: `RulePinning.hardStop(in: ProposedAction)` may remain for tests that plant effects, but preview/save shall prefer `hardStop` that sees `PendingApproval.analysis` + action. Unwrap-limited is `.unwrapLimited` when `analysis.innermost == .unwrapLimited`, not via a bash `-c` tokenizer.
- **REQ-016**: Secret-path hard stop uses `SecretPathCatalog.dayOne.firstMatch` (or `SecretPathMatching`) on path-shaped operands / analysis targets. Do not keep a private duplicate matcher loop.
- **REQ-017**: Delete `blocksAllowOverride(_ deny: Deny)`. `blocksAllowOverride(_ result: EvaluationResult)` stays as `UnlockableDeny.isPinned(result)` (or inline equivalent).
- **REQ-018**: `RebaseRecovery.isUnoverridableHardStop` shall not call a Deny-only pin table. Working-tree-discard remains eligible for rebase lift. Unwrap-limited, protected-path, core.secrets, outside-repo, unresolved live path stay ineligible.
- **REQ-019**: `emptyEffectsWithBranchName` stays: gitPush predicate is not inferred from argv when effects are empty **and** analysis is not `.git(.push...)`.
- **REQ-020**: Spend `clearPending` still matches the host-door fingerprint. Do not switch pending identity to semantic fingerprints.
- **CON-005**: Do not implement OPE-156. Do not change `HostCodec.proposedAction` default fingerprint spelling.
- **CON-006**: Do not fold ServiceClient miss closures into `HookDoor`.
- **PAT-002**: One helper, e.g. `AnalysisBackedAction.shell(host:session:cwd:command:analysis:)`, in RVDomain. HookDispatch / HookDoor call it; they do not copy effects ad hoc.

# 4. Interfaces & Data Contracts

```swift
public enum FilesystemScope: String, Sendable, Equatable, Codable {
    case insideRepository
    case outsideRepository
    case protectedPath
    case unknown
    case unprobed
}

extension FilesystemAnalysisContext {
    public static func unprobed(
        homeDirectory: String? = nil,
        catalog: SecretPathCatalog = .dayOne
    ) -> FilesystemAnalysisContext
}

// PendingApproval / PendingApprovalRequest
public var analysis: SemanticAnalysis // default .unknown
```

`evaluateWithSemantics` signature does not change.

# 5. Acceptance Criteria

- **AC-001**: Given `FilesystemAnalysisContext.empty` and pack-allow `echo hi > file`, When `applyFilesystemSemantics`, Then deny `builtin.action:unresolved-path` (live default unchanged).
- **AC-002**: Given `FilesystemAnalysisContext.unprobed()`, When `applyFilesystemSemantics` on pack-allow `echo hi > file`, Then decision stays allow (or pack deny if a pack hit), never unresolved-path.
- **AC-003**: Given unprobed `rm ~/.ssh/config` (or equivalent catalog shape), When apply filesystem semantics with `core.filesystem` enabled, Then protected-path hard deny still fires.
- **AC-004**: Given `ScanClassify().classify` of pack-allow `echo hi > file`, When classify, Then no finding with unresolved-path rule id.
- **AC-005**: Given `ScanClassify().classify` of `git reset --hard`, Then one finding `core.git:reset-hard`.
- **AC-006**: Given unwrap-limited python one-liner, When classify, Then unwrap-limited finding remains.
- **AC-007**: Given first-call Ask record after semantic git discard, When `PendingApproval.action.effects` is inspected, Then it contains `.workingTreeDiscard` and fingerprint equals `ActionFingerprint.make`.
- **AC-008**: Given pending with `analysis == .unwrapLimited` and empty effects, When always-allow preview, Then `allowedToSave == false` and kind is unwrap (no bash tokenizer required).
- **AC-009**: Given `RulePinning.swift`, When searched, Then `unwrapLimitedCommand` and `blocksAllowOverride(_ deny: Deny)` do not exist.
- **AC-010**: Given rebase in progress and builtin working-tree-discard with `.git(.discardWorktree)`, When `PolicyGate.decide`, Then override is rebaseRecovery. Same deny without rebase stays pinned.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | Unprobed filesystem scope in Domain + Engine | none | `Sources/RVDomain/FilesystemAction.swift`, `Sources/RVDomain/SemanticAnalysis.swift`, `Sources/RVDomain/ActionPolicyEngine.swift`, `Sources/RVEngine/AnalyzeFilesystem.swift`, `Sources/RVEngine/ApplyFilesystemSemantics.swift` (only if needed for comments/tests helpers), `Tests/RVDomainTests/FilesystemActionTests.swift`, `Tests/RVDomainTests/ActionPolicyEngineTests.swift`, `Tests/RVEngineTests/ApplyFilesystemSemanticsTests.swift`, `Tests/RVEngineTests/AnalyzeFilesystemTests.swift` | AC-001, AC-002, AC-003 | 101–1499 |
| T2 | ScanClassify uses unprobed context | T1 | `Sources/RVScan/Classify/ScanClassify.swift`, `Sources/RVScan/SessionScan.swift`, `Tests/RVScanTests/ClassifyTests.swift` | AC-004, AC-005, AC-006 | 101–1499 |
| T3 | Analysis-backed pending + pin | none | `Sources/RVDomain/PendingApproval.swift`, `Sources/RVDomain/AnalysisBackedAction.swift` (new), `Sources/RVHooks/HookDispatch.swift`, `Sources/RVService/HookDoor.swift`, `Sources/RVPolicy/RulePinning.swift`, `Sources/RVPolicy/RebaseRecovery.swift`, `Tests/RVPolicyTests/RulePinningTests.swift`, `Tests/RVPolicyTests/RebaseRecoveryTests.swift`, `Tests/RVHooksTests/` (only tests that assert recorded ProposedAction effects), `Tests/RVServiceTests/` pending record tests if they assert empty effects | AC-007, AC-008, AC-009, AC-010 | 101–1499 |

T1 and T3 are the frontier (parallel). T2 starts when T1 is merged to its branch (T2 branches from T1 HEAD).

Specialist: T1 `swift-type-system-architecture` + `swift-testing-pro`. T2 `swiftify-codebase-architecture` + `swift-evaluate-parity`. T3 `swift-type-system-architecture` + `swift-testing-pro`.

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing in the matching `*Tests` target. RVScanTests must not import RVPolicy/RVService.
- **Frameworks**: Swift Testing (`import Testing`). No XCTest.
- **Test Data**: Temp directories already used in ClassifyTests. No live HOME.
- **CI/CD**: PR workflow `swift test` on official 6.3.3 Linux tarball. Local gate: `tools/gate.sh RVDomainTests`, `RVEngineTests`, `RVScanTests`, `RVPolicyTests`, `RVHooksTests`, `RVServiceTests` as touched.
- **Coverage**: Prove AC-001–AC-010. Do not weaken `missingRepositoryRoot_isFailClosed`.

# 7. Rationale & Context

#202 made scan share `evaluateWithSemantics`. The door defaults are the live fail-closed world. Scan has no probe, so it was silently applying unresolved-path to pack-allow writes.

Pin/preview reconstructs from codec empty shells even though evaluate already bound analysis. Toy parsers drift from `unwrapCommand` / `SecretPathCatalog.firstMatch`. Rebase recovery’s Deny-only list duplicates `UnlockableDeny` except for the working-tree exception, which belongs in `RebaseRecovery` itself.

# 8. Dependencies & External Integrations

### Technology Platform Dependencies
- **PLT-001**: Swift 6.3.3, language mode 6, macOS 26, Linux aarch64/x86_64.

### Data Dependencies
- **DAT-001**: Pending JSONL may omit `analysis`; decode as `.unknown`.

No new packages.

# 9. Examples & Edge Cases

```swift
// Live default (unchanged)
applyFilesystemSemantics(pack: allowed, command: ShellCommand(rawValue: "echo hi > file"))
// deny unresolved-path

// Offline
applyFilesystemSemantics(
    pack: allowed,
    command: ShellCommand(rawValue: "echo hi > file"),
    context: .unprobed()
)
// allow

// Scan
ScanClassify().classify([ExtractedEvent(..., command: ShellCommand(rawValue: "echo hi > file"))])
// no unresolved-path finding
```

# 10. Validation Criteria

- `tools/gate.sh` green for touched test targets.
- No `RV_BYPASS`. No allow-because-XPC-missed.
- No command text in `os_log`.
- No live-HOME tests.
- `FilesystemLiveProbe` still used only from RVService.

# 11. Related Specifications / Further Reading

- `docs/architecture/MODULES.md`
- `docs/architecture/02.md` (do not start OPE-156)
- `docs/architecture/english-compile.md` (PolicyPredicate remains gitPush)
- `spec/spec-architecture-session-scan.md`
- `spec/spec-architecture-hook-bound-review.md`
- HTML report: `swift-functional-evolution-rv-20260913-000839.html`
