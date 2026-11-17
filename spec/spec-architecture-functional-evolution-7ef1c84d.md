---
title: Typed guard config and a pure workspace publish planner
version: 1.0
date_created: 2026-11-17
owner: rv architecture run 7ef1c84d
tags: [architecture, functional-core, rv]
---

# Introduction

Two independent refactors from the 2026-11-17 functional-evolution report. Both move a decision away from the effects around it. Neither changes observable behaviour.

- **Part A**: the guard settings in `~/.config/rv/config.json` (`guard.mode`, `guard.hosts`, `judge.engine`) become one typed value, `GuardConfig`. Guard-mode resolution becomes a pure function. `[String: Any]` leaves the observe/enforce path.
- **Part B**: `WorkspaceInodeBoundary.planPublish` becomes a pure planner. It reads the filesystem only through a `PublishFacts` seam, calling it in the same order as today.

## 1. Purpose & Scope

Audience: implementer and reviewer agents. Base: `origin/main` @ `245aa9b1`. Toolchain: swift-tools 6.4. No new dependencies, no deployment-target change, no change to any config-file write path.

Out of scope:
- config writers (`MachineConfigJSON`, `HostModeStore.save*`, `SafetyStore.saveMachine`)
- the analytics, denial-ledger, safety and bless-path readers
- `HostModeRun.effectiveMode` display rules
- `SelfProtectionGuard`'s private `HostModeWord` (PRs #570 and #578 own that file)
- `commitPublish`, the resumable publish, recovery
- any new fuzz target

## 2. Definitions

- **Guard config**: the three owner-config keys that decide guard posture and judge engine: `guard.mode`, `guard.hosts.<host>`, `judge.engine`.
- **Nested form / flat form**: `{"guard": {"mode": "observe"}}` versus `{"guard.mode": "observe"}`.
- **Ladder**: today's precedence, `RV_GUARD_MODE=enforce` › `guard.hosts.<host>` › `guard.mode` › `enforce`. The environment can only tighten. The organization pin (`ManagedGate.guardMode`) is applied afterwards by callers.
- **Facts seam**: `PublishFacts`, a struct of closures that answers the planner's filesystem questions.
- **Respelled stamps**: the snapshot (`[String: WorkspaceInodeStamp]`) after `planCaseRenames` renames case-only variants. Today it is written to `mutable.publishStamps` during planning.

## 3. Requirements, Constraints & Guidelines

### Part A: typed guard config

- **REQ-A01**: Move `GuardMode` (from `RVService/JudgeGate.swift`), `HostMode` (from `RVPolicy/HostModeStore.swift`, including `isLooser(than:)`) and `JudgeEngine` (from `RVService/JudgeGate.swift`) into RVDomain. Raw values, cases and public API stay unchanged. Add no typealiases at the old locations; fix import sites instead.
- **REQ-A02**: Add `public struct GuardConfig: Sendable, Equatable` in RVDomain with `mode: GuardMode?`, `hosts: [HookHost: HostMode]`, `judgeEngine: JudgeEngine?`, `static let empty`, and `init(_ root: JSONValue)`. A non-object root is `.empty`.
- **REQ-A03**: `GuardConfig.init` preserves today's per-key rules exactly:
  - `mode` and `judgeEngine`:
    - Take the nested string if it is non-empty, else the flat string if it is non-empty.
    - Then lowercase the chosen raw value and parse it.
    - An unparseable chosen value yields `nil`. It does NOT fall back to the other form. (Today `configGuardMode` returns the nested raw, and `GuardMode(rawValue:)` fails on it.)
  - `hosts`:
    - Read the nested form only (`guard.hosts`).
    - Skip any key that is not a `HookHost` raw value.
    - Lowercase each value. Skip non-strings and unknown modes.
- **REQ-A04**: Add `public enum GuardModeResolution` in RVDomain:
  - `static func resolve(_ config: GuardConfig, host: HookHost?, environment: [String: String]) -> GuardMode`
  - It is the ladder, identical to today's `JudgeRuntime.guardMode(environment:config:host:)`.
  - Add a convenience `GuardConfig.machineMode` (`resolve(self, host: nil, environment: [:])`).
- **REQ-A05**: Add one shell reader in RVPolicy: `GuardConfig.read(configDirectory: URL) -> GuardConfig` (missing or unparseable file → `.empty`), plus `GuardConfig.read(home: HomeDirectory?)` using `RVPolicyPaths.configDirectory`. Decode with `JSONDecoder` into `JSONValue`, as `MachineConfigJSON.load` does.
- **SEC-A01**: For every input, the new path must resolve the same `GuardMode` as the old `JSONSerialization` + `[String: Any]` path. Where the two parsers legitimately differ (for example, `JSONValue` decodes integers beyond 2^53 as digit strings), the new result must be `enforce`. A new `observe` that the old path did not produce is a blocking defect.
- **SEC-A02**: The hook daemon-down fallback (`HookObserveFallback.applies`) keeps every check it makes today:
  - `O_NOFOLLOW` open
  - regular file
  - owner uid
  - no group or other write
  - size ≤ 1 MiB
  - full read
  - managed directory absent

  Only the bytes→mode step changes, to `GuardConfig(JSONValue)` + `resolve(host: host, environment: [:])`.
- **SEC-A03**: `RV_GUARD_MODE` handling is unchanged: only `enforce` (case-insensitive) is honoured. CLI callers that pass `environment: [:]` today keep passing `[:]`.
- **REQ-A06**: After T2, nothing in `Sources/` reads `guard.mode`, `guard.hosts` or `judge.engine` through `[String: Any]`. These are deleted:
  - `JudgeRuntime.loadConfigDict`, `configGuardMode`, `configEngine`, `guardMode(environment:config:host:)`, `configuredGuardMode(config:host:)`
  - `HostModeStore.modes(inConfig:)`

  `bundleProblems` (bundle `config.json`, a different file) is out of scope.
- **REQ-A07**: `JudgeRuntime.bundleHealth` and `resolvedJudge` read the guard config at most once per call.
- **CON-A01**: Public entry points `JudgeRuntime.guardMode(home:)` and `JudgeRuntime.configuredGuardMode(home:)` may be removed if every caller migrates to `GuardConfig.read(home:)` + `GuardModeResolution`. Their semantics must be kept at each call site: `guardMode(home:)` reads the process environment; `configuredGuardMode(home:)` passes `[:]`. Both pass `host: nil`.

### Part B: pure publish planner

- **REQ-B01**: Add `Sources/RVIsolation/WorkspacePublishPlanner.swift` containing `enum WorkspacePublishPlanner` with `static func plan(volumeEntries: [String: TreeEntry], special: [String], snapshot: [String: WorkspaceInodeStamp], facts: PublishFacts) -> PublishPlanResult`. Move `PublishStep` and `PublishPlan` out of the class to internal file scope. `PublishPlanResult` pairs the `PublishPlan` with the final respelled stamps.
- **REQ-B02**: `PublishFacts` is an internal `struct` of non-escaping-capable closures (stored `@Sendable` or plain, at the implementer's discretion; the planner is synchronous). Fields:
  - `volumeLink(relative) -> String?`
  - `savedStamp(relative, stamps) -> WorkspaceInodeStamp?`
  - `savedLink(relative) -> String?`
  - `savedFoldsCase() -> Bool?` (nil = clock stop)
  - `removedSubtreeOwned(relative, removed) -> Bool?`
  - `shouldStop() -> Bool`
  - `publishStampsChanged(stamps)`, a callback that reproduces today's writes to `mutable.publishStamps` at the same points, so `savedParent` keeps seeing respelled stamps mid-plan

  If the implementer can prove `savedParent` reads stamps only through a parameter the planner passes, this callback may be dropped, and the result's stamps are written back once. The reviewer verifies that proof.
- **REQ-B03**: The planner calls facts in exactly the order and multiplicity of today's code, for every input. Concretely, the planner is a mechanical lift of `planPublish`, `planCaseRenames`, `caseVariantNames` and the pure part of `stageNameIsFree`, with `self.` reads replaced by facts or parameters. No reordering, no batching, no eager gathering.
- **REQ-B04**: `WorkspaceInodeBoundary` builds the live facts (`savedStamp`, `readVolumeLink`, `readSavedLink`, `savedTreeIsCaseInsensitive`, `removedSubtreeIsOwned`, `cancelClockAllowsTreeCopy`) and calls the planner from the same site (`:473`). Its outcome handling is unchanged.
- **CON-B01**: Do not change `commitPublish`, `publishAndRestore`, `discardAndRestore`, `WorkspacePublishRejection.Reason`, or the planned step order (renames + makes + stages + updates + installs + retires + modes.reversed()).

### Shared

- **GUD-001**: Swift Testing (`import Testing`) for new tests; parameterized tables where natural.
- **GUD-002**: Small commits, one per passing step. Conventional commit messages (`refactor(domain): …`, `test(isolation): …`).
- **PAT-001**: Functional core, imperative shell: decode/plan pure, read/write in named shell functions.

## 4. Interfaces & Data Contracts

```swift
// RVDomain
public enum GuardMode: String, Sendable { case enforce, observe }
public enum HostMode: String, Sendable, Equatable, CaseIterable { case block, observe, off
    public func isLooser(than current: HostMode) -> Bool }
public enum JudgeEngine: String, Sendable { case ft, laya }

public struct GuardConfig: Sendable, Equatable {
    public var mode: GuardMode?
    public var hosts: [HookHost: HostMode]
    public var judgeEngine: JudgeEngine?
    public static let empty: GuardConfig
    public init(mode: GuardMode? = nil, hosts: [HookHost: HostMode] = [:], judgeEngine: JudgeEngine? = nil)
    public init(_ root: JSONValue)
    public var machineMode: GuardMode { GuardModeResolution.resolve(self, host: nil, environment: [:]) }
}

public enum GuardModeResolution {
    public static func resolve(_ config: GuardConfig, host: HookHost?, environment: [String: String]) -> GuardMode
}

// RVPolicy
extension GuardConfig {
    public static func read(configDirectory: URL) -> GuardConfig
    public static func read(home: HomeDirectory?) -> GuardConfig
}

// RVIsolation (internal)
struct PublishFacts { /* REQ-B02 */ }
struct PublishPlanResult { let plan: PublishPlan; let stamps: [String: WorkspaceInodeStamp] }
enum WorkspacePublishPlanner {
    static func plan(volumeEntries: [String: TreeEntry], special: [String],
                     snapshot: [String: WorkspaceInodeStamp], facts: PublishFacts) -> PublishPlanResult
}
```

## 5. Acceptance Criteria

- **AC-A01**: Given any JSON document D, any `host ∈ HookHost.allCases ∪ {nil}`, and `environment ∈ {[:], RV_GUARD_MODE=enforce, =ENFORCE, =observe, =bogus}`: `GuardModeResolution.resolve(GuardConfig(JSONValue(D)), …)` equals the old `JudgeRuntime.guardMode(environment:config:host:)` on `JSONSerialization(D)`, or is `.enforce`. The equivalence test asserts this over a corpus that includes:
  - each key in nested-only, flat-only and both forms
  - an unknown nested value shadowing a valid flat one
  - empty strings
  - mixed case
  - non-string values (number, bool, null, object, array)
  - unknown host keys
  - `guard` as a non-object
  - top-level non-object
  - duplicate keys
  - integers beyond 2^53
  - a UTF-8 BOM
  - invalid JSON
- **AC-A02**: Given the same corpus, `GuardConfig.judgeEngine` equals the old `JudgeRuntime.explicitEngine(config:)`, or is `nil` where the parsers differ.
- **AC-A03**: Given the same corpus, `GuardConfig.hosts` equals the old `HostModeStore.modes(inConfig:)`, or omits an entry where the parsers differ.
- **AC-A04**: After T2, `grep -rn '\[String: Any\]' Sources/RVService/JudgeGate.swift Sources/RVPolicy/HostModeStore.swift Sources/RVCLI/Service/HookDaemonFallback.swift` matches only `bundleProblems`.
- **AC-A05**: These suites pass unchanged in assertions: `GuardModeCharacterizationTests`, `HostGuardModeTests`, `EvaluationInputsTests`, `GatedEffectCharacterizationTests`, `HookDaemonFallbackTests`, `HostModeStoreTests`, `SetupObserveTests`, `HostCommandTests`. Edits are allowed only where a test called a deleted helper.
- **AC-B01**: The planner has value tests covering:
  - each `WorkspacePublishRejection.Reason` it can emit (`unsupportedFileType`, `unreadable`, `caseCollision`, `kindChanged`, `symlinkEscapesWorkspace`, `inodeChanged`, `unexpectedNameInRemovedDirectory`)
  - a case-only rename
  - refusal to retire a removed name whose inode another spelling claims
  - an unchanged symlink being skipped
  - `.stopped` on each `shouldStop` point
  - the exact step order of a mixed plan
- **AC-B02**: A recording fake asserts the facts call sequence for at least one mixed fixture: symlinks, a case rename, a create, an update and a removed directory. The sequence is written out by hand from the pre-change code and committed in the test.
- **AC-B03**: `WorkspacePublishAtomicityTests` and `WorkspacePublishCaseTests` pass unchanged.

## 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | Typed `GuardConfig` + pure `GuardModeResolution` in RVDomain, equivalence-tested against the old path | none | `Sources/RVDomain/GuardConfig.swift` (new); type moves touching `Sources/RVService/JudgeGate.swift`, `Sources/RVPolicy/HostModeStore.swift` and their import sites; `Sources/RVPolicy/GuardConfigFile.swift` (new); `Tests/RVDomainTests/GuardConfig*Tests.swift`, `Tests/RVServiceTests/GuardConfigEquivalenceTests.swift` (new) | AC-A01, AC-A02, AC-A03; all existing suites green | 101–1499 |
| T2 | Migrate every guard-config reader to `GuardConfig` and delete the `[String: Any]` helpers | T1 | `Sources/RVService/{JudgeGate,EvaluationInputs,GatedEvaluate,DoctorSnapshotBuilder}.swift`, `Sources/RVPolicy/HostModeStore.swift`, `Sources/RVCLI/Service/HookDaemonFallback.swift`, `Sources/RVCLI/Setup/{SetupRun,ServiceRestart,HostLifecycle,HostModeRun}.swift`, `Sources/RVCLI/Commands/SetupCommand.swift`, tests that call deleted helpers; equivalence test frozen to a golden table | AC-A04, AC-A05, REQ-A07 | 101–1499 |
| T3 | Pure `WorkspacePublishPlanner` behind `PublishFacts` | none | `Sources/RVIsolation/WorkspacePublishPlanner.swift` (new), `Sources/RVIsolation/WorkspaceInodeBoundary.swift`, `Tests/RVIsolationTests/WorkspacePublishPlannerTests.swift` (new) | AC-B01, AC-B02, AC-B03 | ≥1500 |

Frontier at start: T1, T3 (disjoint writes). T2 stacks on T1's branch. In T2, `GatedEvaluate.swift` changes only `runFile` lines ~89–94. Open PR #582 edits other hunks of that file; do not touch them.

## 6. Test Automation Strategy

- Frameworks: Swift Testing.
- Build: `swift build --build-tests`, using `--scratch-path` if another process holds `.build`.
- Run the touched suites with `timeout`: `swift test --skip-build --filter '<Suite>'`. Build the test product before trusting a failure (stale bundles; see repo quirks).
- Known local baselines that are not regressions:
  - `RVServiceTests` can die with SIGPIPE (signal 13) under `swift test --filter RVServiceTests`. Run narrower suite filters.
  - RVIsolation `WorkspaceSessionTests` `workspaceInodeBoundaryFailed` failures under load.
  - Doctor/setup tests in RVCLITests can exceed timeouts under load.
  - Never add `captureStdout` tests.
- T1's equivalence test keeps the old functions callable (they still exist in T1). In T2 that test becomes a golden table of `(document, host, environment) → GuardMode`, generated from T1's run and committed verbatim.

## 7. Rationale & Context

- `config.json` is parsed by three different parsers. The nested/flat rule is restated per key. `GuardMode` lives in a judge file and RVCLI imports RVService to ask whether rv is observing. The guard path is security-critical, and every new guard feature (per-host modes, org pin, observe floor) was layered onto string-keyed `as?` chains.
- `planPublish` is the last decision before agent writes reach the real project, yet its rejection taxonomy is testable only through mounted disk images. Its helpers are already pure; the loop that combines them is not.
- Keeping fact-call order in Part B preserves the TOCTOU window and cancellation points. An eager snapshot was considered and rejected for that reason.

## 8. Dependencies & External Integrations

- **PLT-001**: swift-tools 6.4, Darwin and Linux. `GuardConfig` must build on Linux (RVDomain is cross-platform). The publish planner is Darwin-only only if `TreeEntry`/`WorkspaceInodeStamp` already are; match the existing `#if` guards.

## 9. Examples & Edge Cases

```json
{"guard": {"mode": "bogus"}, "guard.mode": "observe"}      // → mode nil → enforce (nested shadows flat)
{"guard": {"mode": ""}, "guard.mode": "OBSERVE"}            // → observe (empty nested falls through)
{"guard": {"hosts": {"claude": "Observe", "nope": "off"}}}  // → hosts [claude: observe]
{"guard.hosts": {"claude": "observe"}}                      // → hosts [:] (flat hosts unsupported)
{"guard": {"mode": 9007199254740993}}                       // JSONValue: digit string → nil → enforce; old: NSNumber → flat/none → enforce
```

## 10. Validation Criteria

- All ACs met; the touched suites are green locally (excluding the documented baselines) and on CI.
- Part A: the equivalence test from T1 passed before the old helpers were deleted (T1 PR CI green).
- Part B: the disk-image publish suites are green; the planner suite runs without disk images.

## 11. Related Specifications / Further Reading

- Report: `$TMPDIR/swift-functional-evolution-rv-20261117-165714.html`
- `CONTEXT.md` (Guard: host mode, observe floor; Isolation: publish)
- `Sources/RVIsolation/README.md`
- `spec/spec-architecture-functional-evolution-643e16.md` (earlier run)
