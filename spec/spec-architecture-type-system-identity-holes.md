---
title: Type-system identity holes — HomePath, protected scope, shared branch, GitAction flags, unlock mint
version: 1.0
date_created: 2026-09-15
last_updated: 2026-09-15
owner: rv
tags: [architecture, type-system, domain, engine, hooks]
---

# Introduction

Execute the five Strong candidates from `$TMPDIR/swift-type-system-review-rv-20260915-212332.html` (HEAD `add6883`, branch `worktree/rapid-meadow-3c2e`).

1. **T4** — Domain `HomePath`. Top recommendation. Policy `HomeDirectory` and Scan `ScanHome` become this identity. Engine stops taking `home: String?`.
2. **T3** — `FilesystemScope.protectedPath(SecretPathMatch)`. Parallel `protectedMatch` optional goes away on `FilesystemTarget`.
3. **T2** — `isSharedBranch` is derived from `currentBranch`, not a stored bool.
4. **T1** — `GitRestoreDestination` + drop `deleteBranch.remote`. Independent.
5. **T5** — Mint returns `AllowOnceUnlockCode`. Move the type to RVDomain. Depends on T4 (`GatedEvaluate.swift`).

Do not revive ProposedAction IR (OPE-156). Do not add `Decision.ask`. Do not unify `PacksConfig.enabled: [String]`. Do not introduce `GitBranchConstraint`, `ActionResources` sum types, `ApparentPath`/`CanonicalPath`, chmod `FileMode`, HostCodec enum, or IPC method/result generics.

Audience: fresh-context implementer and reviewer subagents. Toolchain: Swift 6.3.3 (`tools/swift-6.3.3`), language mode 6, macOS 26 / Linux. Gate: `tools/gate.sh`. Warm `.build`. Never `swift package clean`. After the first compile in a worktree, `git restore Package.resolved` unless this ticket owns dependency changes.

# 1. Purpose & Scope

Make five illegal programs unrepresentable:

- `evaluate(..., home: "")` and `lexicalFilesystemPath(..., workingDirectory: home, homeDirectory: cwd.rawValue)`.
- `FilesystemTarget(scope: .protectedPath, protectedMatch: nil)` and `scope: .protectedPath, resolution: .uncertain`.
- `GitAnalysisContext(isSharedBranch: true)` with `currentBranch == nil`.
- `GitAction.deleteBranch(..., remote: true)` and `restore(staged: false, worktree: false, ...)`.
- `generateAllowOnceCode() -> "ABCDE"` that encode later drops.

## In scope

- RVDomain `HomePath`, `FilesystemScope`, `GitAnalysisContext` / `RepositoryReviewContext`, `GitAction`, `AllowOnceUnlockCode`.
- RVEngine evaluate doors, `lexicalFilesystemPath`, `AnalyzeGit` restore/branch parse.
- RVPolicy `HomeDirectory` alias + `process()`, `AllowOnceStore` mint return type.
- RVScan `ScanHome` alias.
- RVService `GatedEvaluate` `home?.rawValue` removal and mint unlock type.
- RVHooks encode doors: delete `unlockCode: String?` convenience overloads.
- RVHistory `DenialPathRedaction.redact(home:)`.

## Out of scope

- PacksConfig `[String]`.
- ProposedAction / `ActionResources` redesign.
- PolicyPredicate.gitPush branch constraint.
- `Decision.ask`. LiveEvaluation phantoms. GitAnalysisWorld / FilesystemAnalysisWorld (already landed).
- Host deny JSON keys. C `rv` hook. Analytics `Any`.

# 2. Definitions

| Term | Meaning |
|---|---|
| HomePath | Nonempty operator / injectable HOME. Absence is `HomePath?`. `""` is not representable. Distinct from `WorkingDirectory` (honor-key cwd) and `RepositoryRoot`. |
| Protected scope | `FilesystemScope.protectedPath(SecretPathMatch)`. A catalog hit is the associated value. |
| Shared branch | `currentBranch` is `main` or `master`. Not a stored bool. |
| Restore destination | Closed `worktree` / `index` / `worktreeAndIndex`. Git `--staged --worktree` is the third case. |
| Unlock code | Six lowercase hex characters. Type already exists in RVHooks; mint must return it. |

# 3. Requirements, Constraints & Guidelines

## T1 — GitAction leftover bools (C04)

- **REQ-101**: Add in `GitAction.swift`:

  ```swift
  public enum GitRestoreDestination: String, Sendable, Equatable, Codable {
      case worktree
      case index
      case worktreeAndIndex
  }
  ```

  `GitAction.restore(pathspecs: [String], destination: GitRestoreDestination, source: String?)`.
- **REQ-102**: `deleteBranch(name: String, force: Bool)` — drop `remote`. Remote deletes stay `deleteRemoteRef`.
- **REQ-103**: `AnalyzeGit.parseRestore`: `false/false` → `.worktree`; staged only → `.index`; both → `.worktreeAndIndex`. Delete the bool rewrite.
- **REQ-104**: `parseBranch` returns `.deleteBranch(name:force:)` with no remote flag. `-r` / `--remotes` stay skip flags.
- **REQ-105**: `effectScope` / `explainAction` / fingerprint / `effectKinds` lose the `remote: true` arm. Restore both-true is working-tree discard (today: `if worktree`).
- **REQ-106**: Tests that spelled `staged:`/`worktree:`/`remote: false` compile against the new cases. A Domain or Engine test proves `deleteBranch(name:force:remote:)` does not compile.
- **CON-101**: No generics. Do not parse `git branch -d -r` in this ticket. Do not change `GitAction.clean` flags.
- **GUD-101**: Failing test first: restore both-false is unrepresentable; analyzer `git restore file` is `.worktree`.

## T2 — Shared branch from name (C03)

- **REQ-201**: `GitAnalysisContext` stores `currentBranch: String?` only. `isSharedBranch` is a computed `Bool` true iff `currentBranch` is `main` or `master` (same set as `ActionPolicyEngine` `sharedBranchNames`).
- **REQ-202**: `RepositoryReviewContext` matches. `GitAnalysisContext.reviewContext` stays a projection.
- **REQ-203**: `GitAnalysisContext(isSharedBranch:)` and `RepositoryReviewContext(isSharedBranch:)` stored-parameter inits do not compile.
- **REQ-204**: `ActionPolicyEngine.isSharedTarget` does not dual-consult a bool on world and ReviewContext. It uses the name (`currentBranch` and/or `resources.branchName`) against the shared set. Unprobed world still must not consult implicit HEAD (existing unprobed law).
- **REQ-205**: `GitLiveProbe` stops passing a separate `shared` flag; name is enough.
- **REQ-206**: Tests that stubbed `GitAnalysisContext(isSharedBranch: true)` pass `currentBranch: "main"` (or `"master"`).
- **CON-201**: No `GitHead` enum, no phantom `Attached<Shared>`. Do not distinguish detached vs unknown unless a caller already needed it (live probe treats both as no name).
- **CON-202**: Do not edit `FilesystemAnalysisContext` in this ticket (T4).
- **GUD-201**: First failing test: `GitAnalysisContext(isSharedBranch: true)` does not compile; `currentBranch: "main"` is shared; `currentBranch: "feature"` is not.

## T3 — FilesystemScope.protectedPath(match) (C02)

Depends on T2 (`ActionPolicyEngine.swift`).

- **REQ-301**:

  ```swift
  public enum FilesystemScope: Sendable, Equatable, Codable {
      case insideRepository
      case outsideRepository
      case protectedPath(SecretPathMatch)
      case unknown
  }
  ```

- **REQ-302**: Remove `FilesystemTarget.protectedMatch` as a stored parallel field. Match is the associated value. `explainCategory` / `resources.protectedMatch` read it from scope.
- **REQ-303**: `classifiedTarget` / `filesystemScopeForResolution` / `protectedMatch` helper: uncertain → `.unknown` with no match; catalog hit → `.protectedPath(match)`; never `.protectedPath` without a match.
- **REQ-304**: `UnlockableDeny` pin and `FilesystemAction.effectKinds` switch on `protectedPath`. Write + protected still adds `.protectedPathMutation` only when resolution is not uncertain (uncertain is `.unknown`, so the extra test `resolution != .uncertain` on a protected scope should become unreachable — drop it if exhaustive).
- **REQ-305**: `ActionPolicyEngine.filesystemHit` dual check can read scope’s associated match. Do not expand `ProposedAction` cases. `ActionResources.protectedMatch` may remain a copy of the associated value (IR freeze).
- **REQ-306**: Tests: `FilesystemTarget(scope: .protectedPath, ...)` without a match does not compile. `uncertainProtected_doesNotAddExtraDenyEffect` uses `.unknown` (analyzer truth), not fake-protected+uncertain.
- **CON-301**: No `ApparentPath`/`CanonicalPath` newtypes. No HomePath in this ticket. No ProposedAction.file.
- **CON-302**: Do not edit `lexicalFilesystemPath` signatures (T4). You may still assign `.protectedPath(match)` inside `classifiedTarget`.
- **GUD-301**: Failing test first on Domain `FilesystemActionTests`.

## T4 — Domain HomePath (C01, top)

Depends on T2 (`SemanticAnalysis.swift`) and T3 (`AnalyzeFilesystem.swift`).

- **REQ-401**: Add `Sources/RVDomain/HomePath.swift` modeled on `WorkingDirectory`:

  ```swift
  public struct HomePath: RawRepresentable, Hashable, Sendable, Codable {
      public let rawValue: String
      public init?(validating rawValue: String) // fails on ""
      public var path: String { rawValue }      // Scan call-site alias
  }
  ```

- **REQ-402**: RVPolicy: `public typealias HomeDirectory = HomePath`. Keep `HomeDirectory.process()` in Policy (ProcessInfo). Do not put env reads in Domain.
- **REQ-403**: RVDomain: `public typealias ScanHome = HomePath` (or ScanHome becomes HomePath). Session adapters keep compiling (`roots(home:)`).
- **REQ-404**: Engine/Domain doors take `HomePath?`, not `String?`: `evaluate`, `evaluateWithSemantics`, `evaluateFileTool`, `SecretAllowPathSet.exempts` / `normalize`, `FilesystemAnalysisContext.homeDirectory`, `EvaluateSession`, `DenialPathRedaction.redact`.
- **REQ-405**: `lexicalFilesystemPath(_ apparent: String, workingDirectory: WorkingDirectory?, homeDirectory: HomePath?)`. Callers that already have newtypes stop dropping to `String`. Internal symlink follow may still use `String` hops.
- **REQ-406**: `GatedEvaluate` passes `home` as `HomePath?` / `HomeDirectory?` into Engine and `FilesystemLiveProbe`, not `home?.rawValue`.
- **REQ-407**: `SecretAllowPathSet.normalize` and `DenialPathRedaction.redact` drop `home.isEmpty == false` once the type forbids empty.
- **REQ-408**: Tests: `HomePath(validating: "") == nil`; `evaluate(..., home: "")` does not compile; a `WorkingDirectory` cannot be passed as `home:`.
- **CON-401**: Domain stays pure (no `ProcessInfo`, no `FileManager`). Do not merge HOME with `WorkingDirectory`. Do not change PacksConfig `[String]`.
- **CON-402**: Codable JSON for `FilesystemAnalysisContext.homeDirectory` may stay a string key; the Swift type is `HomePath?`.
- **GUD-401**: First failing test in RVDomainTests for empty HomePath. Then Engine/Service signatures.

## T5 — Mint AllowOnceUnlockCode (C05)

Depends on T4 (`GatedEvaluate.swift`).

- **REQ-501**: Move `AllowOnceUnlockCode` to RVDomain (same validation: exactly six lowercase hex). RVHooks keeps `unlockLine`, `HookVoiceNext.minted`, voice helpers importing Domain.
- **REQ-502**: `generateAllowOnceCode() throws -> AllowOnceUnlockCode`. `AllowOnceStore.mint` / `mintFromDeny` return `AllowOnceUnlockCode?` (or the existing optional shape with this type).
- **REQ-503**: `GatedEvaluate.mintUnlockCode` / `LiveEvaluateWorld.mintUnlockCode` / `HookDispatch` pass `AllowOnceUnlockCode?` without `flatMap(init(validating:))`.
- **REQ-504**: Delete `hookWire(..., unlockCode: String?)` and `hostDenyLine(..., unlockCode: String?)` and `hookUnlockNext(code: String?)` overloads. Typed doors stay.
- **REQ-505**: A test proves `generateAllowOnceCode()`’s return is `AllowOnceUnlockCode` and `hookWire(..., unlockCode: "ABC")` does not compile.
- **CON-501**: jsonl still does not store plaintext codes. Host JSON still prints the six hex characters. Do not change deny JSON keys.
- **CON-502**: Do not edit HomePath / evaluate `home:` in this ticket.
- **GUD-501**: Failing test on mint return type first.

# 3b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | GitRestoreDestination + drop deleteBranch.remote | none | `Sources/RVDomain/GitAction.swift`; `Sources/RVEngine/AnalyzeGit.swift`; `Tests/RVEngineTests/AnalyzeGitTests.swift`; `Tests/RVPolicyTests/RebaseRecoveryTests.swift`; `Tests/RVServiceTests/GatedEvaluateRebaseRecoveryTests.swift`; any other test that constructs `restore(pathspecs:` or `deleteBranch(` | Analyzer `git restore file` is `.worktree`; `deleteBranch(remote:)` does not compile; `tools/gate.sh RVDomainTests` and `RVEngineTests` green (plus rebase-recovery targets if those files moved) | 101–1499 (`AnalyzeGit.swift`) |
| T2 | Derive isSharedBranch from currentBranch | none | `Sources/RVDomain/SemanticAnalysis.swift` (GitAnalysisContext only — do not change FilesystemAnalysisContext); `Sources/RVDomain/ActionReviewer.swift`; `Sources/RVDomain/ActionPolicyEngine.swift`; `Sources/RVService/GitLiveProbe.swift`; tests that pass `isSharedBranch:` (`Tests/RVDomainTests/ActionPolicyEngineTests.swift`, `ActionPolicyEngineTypedRuleTests.swift`, `TypedRuleExplainTests.swift`, `HostNativeAskTests.swift`, `Tests/RVEngineTests/ApplySemanticsTests.swift`, `ApplySemanticsPrefixTests.swift`, `EvaluateWithSemanticsTests.swift`, `Tests/RVPolicyTests/ActionPolicyEngineShadowTests.swift`, `Tests/RVDomainTests/Fakes/StubActionReviewer.swift`) | `GitAnalysisContext(isSharedBranch: true)` does not compile; `currentBranch: "main"` is shared; unprobed law unchanged; `tools/gate.sh RVDomainTests` and `RVEngineTests` | 101–1499 (`ActionPolicyEngine.swift`) |
| T3 | FilesystemScope.protectedPath(match) | T2 | `Sources/RVDomain/FilesystemAction.swift`; `Sources/RVEngine/AnalyzeFilesystem.swift` (classifiedTarget / scope helpers only — do not change `lexicalFilesystemPath` signature); `Sources/RVDomain/UnlockableDeny.swift`; `Sources/RVDomain/ActionPolicyEngine.swift`; `Tests/RVDomainTests/FilesystemActionTests.swift`; Engine/Policy tests that construct `FilesystemScope.protectedPath` or `FilesystemTarget(... protectedMatch:` | Protected without match does not compile; uncertain is `.unknown`; `tools/gate.sh RVDomainTests` and `RVEngineTests` | 101–1499 (`AnalyzeFilesystem.swift`) |
| T4 | Domain HomePath through evaluate | T2, T3 | `Sources/RVDomain/HomePath.swift` (new); `Sources/RVDomain/ScanTypes.swift`; `Sources/RVPolicy/HomeDirectory.swift`; `Sources/RVDomain/SecretAllowPathSet.swift`; `Sources/RVDomain/SemanticAnalysis.swift` (FilesystemAnalysisContext.homeDirectory); `Sources/RVEngine/Evaluate.swift`; `Sources/RVEngine/EvaluateWithSemantics.swift`; `Sources/RVEngine/FileToolEvaluate.swift`; `Sources/RVEngine/AnalyzeFilesystem.swift` (`lexicalFilesystemPath` + home expansion); `Sources/RVService/FilesystemLiveProbe.swift`; `Sources/RVService/EvaluateSession.swift`; `Sources/RVService/GatedEvaluate.swift` (home pass only — not mint); `Sources/RVHistory/DenialPathRedaction.swift`; `Sources/RVScan/ScanHome.swift`; tests that pass `home:` / `homeDirectory:` as `String?` into those doors | `HomePath(validating: "") == nil`; Engine `home: String?` gone; GatedEvaluate does not `home?.rawValue` into Engine; `tools/gate.sh` Domain, Engine, Policy, Service, Scan, History as touched | 101–1499 (`AnalyzeFilesystem.swift` / `GatedEvaluate.swift`) |
| T5 | Mint returns AllowOnceUnlockCode | T4 | `Sources/RVDomain/AllowOnceUnlockCode.swift` (new, moved); `Sources/RVHooks/HostDenyText.swift`; `Sources/RVPolicy/AllowOnceStore.swift`; `Sources/RVHooks/HookMapper.swift`; `Sources/RVHooks/HookDispatch.swift`; `Sources/RVService/GatedEvaluate.swift` (mint only); `Sources/RVService/LiveEvaluateWorld.swift`; tests for mint / hookWire unlock | `generateAllowOnceCode() -> AllowOnceUnlockCode`; String unlock overloads gone; `tools/gate.sh RVPolicyTests`, `RVHooksTests`, `RVServiceTests` | 101–1499 (`GatedEvaluate.swift` / `AllowOnceStore.swift`) |

Independent: T1 ∥ T2. Then T3 (after T2). Then T4 (after T2 and T3). Then T5 (after T4).

If a test file constructs a type this ticket owns and was omitted from exclusive-writes, the ticket still owns it — grep the old spelling and include it (exclusive-writes are a collision fence, not a compile set). Do not edit another ticket’s production files; stack on that ticket’s branch instead.

# 4. Interfaces & Data Contracts

```swift
// T1
public enum GitRestoreDestination: String, Sendable, Equatable, Codable {
    case worktree, index, worktreeAndIndex
}
// GitAction.restore(pathspecs:destination:source:)
// GitAction.deleteBranch(name:force:)

// T2
public struct GitAnalysisContext {
    public var currentBranch: String?
    public var isSharedBranch: Bool { /* main/master */ }
}

// T3
public enum FilesystemScope {
    case insideRepository, outsideRepository
    case protectedPath(SecretPathMatch)
    case unknown
}

// T4
public struct HomePath: RawRepresentable {
    public let rawValue: String
    public init?(validating rawValue: String)
}

// T5
public struct AllowOnceUnlockCode: Hashable, Sendable {
    public let rawValue: String
    public init?(validating rawValue: String)
}
public func generateAllowOnceCode() throws -> AllowOnceUnlockCode
```

Host deny JSON keys unchanged. policy.toml unchanged. blocks.jsonl unchanged.

# 5. Acceptance Criteria

- **AC-101**: Given `git restore file`, When analyzed, Then destination is `.worktree`. `deleteBranch(remote:)` does not type-check.
- **AC-201**: Given `GitAnalysisContext(currentBranch: "main")`, When `isSharedTarget`, Then shared. Given `currentBranch: "feature"`, Then not shared. Given no `currentBranch` and unprobed world, Then implicit HEAD is not consulted.
- **AC-301**: Given a catalog hit, When `classifiedTarget`, Then `scope` is `.protectedPath(match)`. Given uncertain resolution, Then `.unknown`. Hand-built protected-without-match does not compile.
- **AC-401**: Given `HomePath(validating: "")`, Then nil. Given GatedEvaluate with `HomeDirectory?`, When evaluate/probe, Then no `String?` home on the Engine door.
- **AC-501**: Given a successful mint, When hook encode, Then `HookVoiceNext.minted` without re-validation. `unlockCode: String?` hookWire overload does not exist.

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit in the ticket’s module tests.
- **Frameworks**: Swift Testing. No XCTest. No live HOME.
- **CI**: `tools/gate.sh <Target>Tests` for every module whose production file this ticket changed.
- **Coverage**: see AC-* and REQ-*-test bullets. Prefer compile-fail evidence (`#expect(compiles:)` is not required; a test file that would not type-check if the old API remained is enough, plus green analyzer tests).

# 7. Rationale & Context

Prior type-system work closed Decision/outcome, probe worlds, HookRequest, ApprovalIdentity, GitPushForceConstraint, DenialLedgerRecord, and push vs deleteRemoteRef. Remaining holes are misplaced erasure of HOME, parallel optionals on filesystem scope, a stored shared-branch bool the live probe never sets independently, leftover GitAction flags after the remote-delete split, and unlock mint that still returns String after CON-201 froze JSON.

HomePath is the top recommendation because Policy already has the nonempty newtype and Engine reopens `String?` (`GatedEvaluate` `home?.rawValue`). That is Lens D (erasure too early), not a generic design.

# 8. Dependencies & External Integrations

- **PLT-001**: Swift 6.3.3, language mode 6, macOS 26, Linux aarch64/x86_64.
- **DAT-001**: Host deny JSON keys frozen. blocks.jsonl keys frozen. policy.toml unchanged.
- **COM-001**: No `RV_BYPASS`. No command text in os_log. Domain/Engine/Packs/Presentation stay value types.

# 9. Examples & Edge Cases

```swift
// T1
GitAction.restore(pathspecs: ["."], destination: .worktree, source: nil)
GitAction.deleteBranch(name: "stale", force: true)
// GitAction.deleteBranch(name: "stale", force: true, remote: false) // does not compile

// T2
GitAnalysisContext(currentBranch: "main") // isSharedBranch == true
GitAnalysisContext(workingDirectory: cwd) // isSharedBranch == false
// GitAnalysisContext(isSharedBranch: true) // does not compile

// T3
FilesystemScope.protectedPath(SecretPathMatch(pattern: "home-ssh", category: .ssh))
// FilesystemTarget(..., scope: .protectedPath, protectedMatch: nil) // does not compile

// T4
HomePath(validating: "") == nil
evaluate(request, ..., home: homePath, engine: engine, compiled: compiled)
lexicalFilesystemPath(apparent, workingDirectory: cwd, homeDirectory: homePath)

// T5
let code: AllowOnceUnlockCode = try generateAllowOnceCode()
hookWire(..., intent: .firstCall(verdict: verdict, unlockCode: code))
```

# 10. Validation Criteria

Each ticket: `tools/gate.sh` for that ticket’s test targets green. No new `TODO`/`FIXME` in production. No `RV_BYPASS`. `git restore Package.resolved` if the first worktree resolve rewrote it. Specialist skills: `swift-testing-pro`, `swift-hexagonal-spm` (module arrows), `swift-evaluate-parity` if evaluate types move, `swift-hook-xpc` for T5 voice/mint.

# 11. Related Specifications / Further Reading

- `spec/spec-architecture-type-system-remaining-holes.md` (landed; CON forbade HomePath then)
- `spec/spec-architecture-type-system-remaining-closures.md`
- `docs/architecture/MODULES.md`
- `docs/dev/SWIFT.md`
- HTML: `swift-type-system-review-rv-20260915-212332.html`
