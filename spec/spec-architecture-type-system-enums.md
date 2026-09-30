---
title: Type-system enums for rv — ShellAction, ResourceScope, JSONValue
version: 1.0
date_created: 2026-09-30
owner: swift-type-system-architecture pipeline
tags: [architecture, type-system, enums, rv, RVDomain, RVScan]
---

# Introduction

This spec turns three Strong Tier-1 candidates from the Swift type-system
review of `rv` (report:
`/tmp/swift-type-system-review-rv-20260930-034141.html`) into implementable
tickets. Each candidate closes a state space that today compiles in invalid
configurations and is enforced only by runtime checks, casts, or convention.

## 1. Purpose & Scope

Purpose: replace runtime ambiguity with compiler-checked design in three
places: `ShellAction` duality (C2, top recommendation), `ActionResources`
optional soup (C3), and the untyped `[String: Any]` JSON funnel (C1).

Scope: `RVDomain`, `RVScan`, `RVEngine/RuntimeAdmissionNormalize.swift`,
`RVHooks/HostCodec.swift`, `RVCLI/Setup`, `RVPolicy` JSON readers,
`RVAnalytics` JSON readers, `RVHistory/DenialLedgerPreferences.swift`,
`RVIsolation` JSON readers, and their tests. Out of scope: toolchain or
deployment-target migration, PacksConfig, Evaluation-door architecture,
wire-format redesign.

Audience: implement-spec subagents (fresh context, sparse pointers).

Assumptions: Swift 6.4, `swiftLanguageModes: [.v6]`, macOS 15 floor per
`Package.swift`, Linux aarch64/x86_64 CI. Base commit for all ticket branches:
`origin/main` at `9c546c99`.

## 2. Definitions

- **Effect-only shell**: a `ShellAction` carrying fingerprint/effects/
  resources/scope/evidence with no analyzed subject (`analysis == nil`).
- **Analyzed shell**: a `ShellAction` whose subject is `.git` or
  `.filesystem`; effects/resources are projections of the subject.
- **XOR labels**: the Codable keys `gitAction` / `filesystemAction`; at most
  one may be present.
- **Projection**: `SemanticAction.effects` / `.resources` derived from the
  subject. Today stored redundantly and equality-checked at decode.
- **Refspec**: a git refspec string (e.g. `HEAD:main`). Not a branch name.
- **JSONValue**: a lossless, `Sendable`+`Codable`+`Equatable` JSON enum.
- **DAG**: ticket dependency graph. Frontier = tickets whose `depends-on`
  are all merged.

## 3. Requirements, Constraints & Guidelines

- **REQ-001 (C2)**: `ShellAction` SHALL be an enum with two cases —
  effect-only and analyzed — so a stored bag disagreeing with its subject
  is unrepresentable. The three runtime decode throws (both-keys XOR,
  effects-disagree, resources-disagree) SHALL be deleted, not moved.
- **REQ-002 (C2)**: The analyzed case SHALL compute `effects`/`resources`
  from `analysis` (computed properties); it SHALL NOT store them.
- **REQ-003 (C2)**: All construction sites (4 current inits) and all read
  sites SHALL be migrated to exhaustive switching. No `analysis == nil`
  checks remain in production code.
- **REQ-004 (C3)**: `ActionResources`' 5-optional bag SHALL be replaced by a
  `ResourceScope` enum (`.git` / `.filesystem` / `.none`) so git subjects
  cannot carry paths and filesystem subjects cannot carry branches.
- **REQ-005 (C3)**: The refspec-vs-branch conflation (`GitAction.push`
  storing a refspec in `branchName`) SHALL be closed with a `GitRef` enum
  (`.branch(BranchName)` / `.refspec(String)` / `.tag(TagName)`) plus
  `BranchName`/`RemoteName` newtypes.
- **REQ-006 (C1)**: A `JSONValue` enum SHALL live in `RVDomain` and replace
  `[String: Any]` / `Any` as the in-memory JSON representation in RVScan,
  RVCLI-Setup, RVPolicy, RVAnalytics, RVHistory, and RVIsolation readers.
  `JSONParse` SHALL return `JSONValue`, never `Any`.
- **REQ-007**: Every ticket SHALL keep the package building with zero
  warnings and SHALL keep all existing tests passing (updated where the
  spec mandates behavior-preserving rewrites).
- **CON-001**: Codable wire keys are frozen. Renames keep keys:
  `gitAction`/`filesystemAction` XOR labels, omitted-unused-key rule,
  never encode `analysis`, and existing `branchName`/`remoteName`/`path`/
  `filesystemScope`/`resourceKind` key spellings where the wire shape is
  retained.
- **CON-002**: No new package dependencies. `RVAnalytics` MAY gain an
  `RVDomain` target dependency (needed for `JSONValue`); no other
  `Package.swift` graph changes.
- **CON-003**: Swift 6.4 only. No `~Copyable`, parameter packs, or macro
  machinery. No toolchain/deployment migration.
- **CON-004**: Ticket branches: T1/T3 off `origin/main`; T2 stacked on T1;
  T4 stacked on T3. One PR per ticket. No mega-PR. No `git add -A`.
- **CON-005**: Exclusive write sets are disjoint on the parallel frontier
  (T1 vs T3). Overlapping tickets serialize via `depends-on`.
- **CON-006**: Forbidden re-proposals: PacksConfig `[String]`,
  Evaluation-door / Policy-gate / Hook-mapper / EvaluationWorld /
  SessionScan designs. None of these tickets touch those areas.
- **GUD-001**: Prefer deleting code (`projectedBag`, redundant inits,
  cast chains) over deprecating it. No `// TODO`/`FIXME` left behind.
- **GUD-002**: New public types are `Sendable`, `Equatable`, `Codable`
  where the current bag is, and documented with one-line semantics.
- **PAT-001**: Follow the repo's legacy-tolerance decode pattern where a
  transition window is needed (cf. recent "legacy tolerance" merge).

## 4. Interfaces & Data Contracts

### 4a. ShellAction (T1, C2)

```swift
public enum ShellAction: Sendable, Equatable, Codable {
    case effectOnly(EffectShell)
    case analyzed(AnalyzedShell)
}
public struct EffectShell: Sendable, Equatable, Codable {
    public var fingerprint: ActionFingerprint
    public var effects: ActionEffects
    public var resources: ActionResources // then ResourceScope in T2
    public var scope: ActionScope
    public var supportingCommand: ShellCommand?
}
public struct AnalyzedShell: Sendable, Equatable, Codable {
    public var fingerprint: ActionFingerprint
    public var scope: ActionScope
    public var supportingCommand: ShellCommand?
    public var analysis: SemanticAction // non-optional
    public var effects: ActionEffects { analysis.effects }       // computed
    public var resources: ActionResources { analysis.resources } // computed
}
```

`ShellAction` keeps convenience projections (`effects`, `resources`,
`scope`, `supportingCommand`, `fingerprint`, `gitAction`,
`filesystemAction`) as computed properties switching on `self`, and custom
`Codable` preserving today's exact wire shape (flat keys incl. XOR labels).

### 4b. ResourceScope (T2, C3)

```swift
public enum ResourceScope: Sendable, Equatable, Codable {
    case git(remote: RemoteName?, ref: GitRef?)
    case filesystem(path: String, scope: FilesystemScope, kind: FilesystemResourceKind)
    case none
}
public enum GitRef: Sendable, Equatable, Codable {
    case branch(BranchName)
    case refspec(String)
    case tag(TagName)
}
public struct BranchName: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String
}
public struct RemoteName: RawRepresentable, Hashable, Sendable, Equatable, Codable { ... }
public struct TagName: RawRepresentable, Hashable, Sendable, Equatable, Codable { ... }
```

Wire: custom `Codable` keeps `remoteName`/`branchName`/`path`/
`filesystemScope`/`resourceKind` keys; `.refspec` encodes under a distinct
spelling documented in code; decode stays tolerant of the old shape.

### 4c. JSONValue (T3/T4, C1)

```swift
public enum JSONValue: Sendable, Equatable, Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double) // plus int accessor; see edge cases
    case bool(Bool)
    case null
}
```

Accessors: `subscript(key:)`, `subscript(index:)`, `.string`, `.int`,
`.double`, `.bool`, `.isNull`, `asObject`, `asArray`. `JSONParse.object`
returns `JSONValue?` (object-or-nil), `JSONParse.value` returns
`JSONValue?`. File: `Sources/RVDomain/JSONValue.swift` (new).

## 5. Acceptance Criteria

- **AC-001**: Given any `ShellAction` value, When inspected, Then it is
  either effect-only (no subject) or analyzed (bags computed from subject);
  no value can carry disagreeing bags. `projectedBag` does not exist.
- **AC-002**: Given the old wire JSON for analyzed/effect-only shells, When
  decoded, Then decode succeeds and re-encode is byte-identical in keys.
- **AC-003**: Given a `.push` action, When reading its resources, Then a
  refspec is never observable as `BranchName`.
- **AC-004**: Given any adapter JSON payload, When parsed via `JSONParse`,
  Then no `as?` cast on `Any` appears in the consumer; `grep 'as?'` in the
  migrated files returns only non-`Any` uses.
- **AC-005**: Given each ticket branch, When running `swift build` and the
  affected `swift test --filter` suites, Then zero warnings, zero failures.

## 5b. Tickets (task graph)

Base: `origin/main` @ `9c546c99`. Frontier 1 = T1 + T3 (parallel, disjoint
writes). Frontier 2 = T2 (on T1), T4 (on T3). Specialist skill for all
implementers: `swift-type-system-architecture` (design already fixed here —
implement, do not redesign).

### T1 — ShellAction enum (C2, TOP)

- `depends-on`: none. Branch `arch/26bf8ed6/T1-shell-action-enum` off base.
- `exclusive-writes`:
  - `Sources/RVDomain/ProposedAction.swift`
  - `Sources/RVDomain/GitAction.swift`
  - `Sources/RVDomain/FilesystemAction.swift`
  - `Sources/RVDomain/ActionPolicyEngine.swift`
  - `Sources/RVDomain/ReviewSanitizer.swift`
  - `Sources/RVDomain/AgentNormalization.swift`
  - `Sources/RVEngine/RuntimeAdmissionNormalize.swift`
  - `Sources/RVHooks/HostCodec.swift`
  - `Tests/RVDomainTests/ShellActionCodableTests.swift`
  - `Tests/RVDomainTests/PendingActionTests.swift`
  - `Tests/RVDomainTests/ActionPolicyEngineTypedRuleTests.swift`
  - `Tests/RVDomainTests/RuntimeAdmissionTests.swift`
  - `Tests/RVDomainTests/PendingApprovalLedgerTests.swift`
  - `Tests/RVDomainTests/LinuxResidualCoverageTests.swift`
  - `Tests/RVDomainTests/Fakes/StubActionReviewer.swift`
  - `Tests/RVEngineTests/` (only files referencing ShellAction ctors)
  - `Tests/RVHooksTests/` (only files referencing ShellAction ctors)
  - API-atomic fallout (mechanical ctor migrations ONLY, verified
    `ShellAction(` -> `ShellAction.effectOnly(EffectShell(` etc.):
    `Tests/RVDomainTests/ActionPolicyFixtures.swift`,
    `ActionReviewerTests.swift`, `AgentRequestTests.swift`,
    `HostNativeAskTests.swift`, all of `Tests/RVIsolationTests/`,
    `Tests/RVPolicyTests/`, `Tests/RVServiceTests/` files in the T1 diff.
    Reviewer MUST confirm these contain no assertion/behavior changes.
- `acceptance`:
  - `projectedBag` and the 4 old inits are gone; all callers switch
    exhaustively; AC-001 + AC-002 hold.
  - `swift build` zero warnings; RVDomain + RVEngine + RVHooks tests green.
  - Wire round-trip tests pin old-keys compatibility (extend
    `ShellActionCodableTests`, do not weaken existing assertions).
- `review-hint`: `101–1499` (ActionPolicyEngine.swift ~619 LOC).

### T2 — ResourceScope enum + GitRef newtypes (C3)

- `depends-on`: T1 (stacked branch `arch/26bf8ed6/T2-resource-scope` on T1).
- `exclusive-writes`:
  - `Sources/RVDomain/ProposedAction.swift` (resources region + payloads)
  - `Sources/RVDomain/GitAction.swift` (resources projection)
  - `Sources/RVDomain/FilesystemAction.swift` (resources projection)
  - `Sources/RVDomain/PolicyMatch.swift`
  - `Sources/RVDomain/SemanticAnalysis.swift` (GitSharedBranch)
  - `Sources/RVDomain/ActionPolicyEngine.swift` (resource reads)
  - `Sources/RVDomain/ResourceScope.swift` (new, or inside ProposedAction)
  - `Tests/RVDomainTests/` (files asserting resources/branch matching)
- `acceptance`:
  - 5-optional `ActionResources` gone (or typealiased shim ONLY if a
    consumer outside the write set needs it — none known); AC-003 holds.
  - Every PolicyMatch branch covered by a behavior-preserving test run.
  - `swift build` zero warnings; RVDomain tests green.
- `review-hint`: `101–1499`.

### T3 — JSONValue core + RVScan adoption (C1a)

- `depends-on`: none. Branch `arch/26bf8ed6/T3-json-value-core` off base.
- `exclusive-writes`:
  - `Sources/RVDomain/JSONValue.swift` (new)
  - `Sources/RVScan/JSONParse.swift`
  - `Sources/RVScan/Adapters/` (all)
  - `Sources/RVScan/ScanEngine/`
  - `Sources/RVScan/SessionStoreAdapter.swift`
  - `Tests/RVDomainTests/JSONValueTests.swift` (new)
  - `Tests/RVScanTests/` (all)
- `acceptance`:
  - Zero `as?`-on-`Any` in `Sources/RVScan`; AC-004 holds for RVScan.
  - New `JSONValueTests` cover accessors + number edge cases + Codable
    round-trip.
  - `swift build` zero warnings; RVScan + RVDomain tests green.
- `review-hint`: `101–1499`.

### T4 — JSONValue consumers (C1b)

- `depends-on`: T3 (stacked branch `arch/26bf8ed6/T4-json-value-consumers`
  on T3).
- `exclusive-writes`:
  - `Sources/RVCLI/Setup/` (HostHooksMergeEngine + *Merge.swift)
  - `Sources/RVPolicy/MachineConfigJSON.swift`
  - `Sources/RVPolicy/SafetyStore.swift`
  - `Sources/RVPolicy/SecretAllowPaths.swift`
  - `Sources/RVAnalytics/AnalyticsPreferences.swift`
  - `Sources/RVAnalytics/AnalyticsCoordinator.swift`
  - `Sources/RVAnalytics/AnalyticsSink.swift`
  - `Sources/RVHistory/DenialLedgerPreferences.swift`
  - `Sources/RVIsolation/RuntimeResourceManifest.swift`
  - `Sources/RVIsolation/WorkspaceInodeBoundary.swift`
  - `Sources/RVIsolation/EgressProxy.swift`
  - `Package.swift` (RVAnalytics gains `RVDomain` dep ONLY)
  - `Tests/RVCLITests/`, `Tests/RVPolicyTests/`,
    `Tests/RVAnalyticsTests/`, `Tests/RVHistoryTests/`,
    `Tests/RVIsolationTests/` (files covering the above)
- `acceptance`:
  - Zero `as?`-on-`Any` in the listed consumer files; AC-004 holds there.
  - `swift build` zero warnings; all affected suites green.
- `review-hint`: `101–1499`.

## 6. Test Automation Strategy

- **Test Levels**: Unit (enum semantics, Codable round-trips, accessors) +
  existing integration suites per module. No new E2E.
- **Frameworks**: Swift Testing (`@Suite`/`@Test`) and XCTest as already
  used per file. Do not migrate frameworks.
- **Test Data Management**: reuse existing fixtures
  (`Tests/*/Fixtures`, `ShellActionCodableTests` payloads). Add old-wire
  JSON vectors for T1/T2 transition tolerance.
- **CI/CD Integration**: `swift build` + `swift test` per affected target.
  Provision: full `swift test` before each PR leaves draft.
- **Coverage Requirements**: every new enum case + accessor + Codable
  path covered; every changed PolicyMatch branch re-run green.
- **Performance Testing**: none (no perf-sensitive paths touched).

## 7. Rationale & Context

Full analysis in the HTML report. Summary: RVDomain's core enums
(`ProposedAction`, `SemanticAction`, `SemanticAnalysis`) are already closed;
the defects sit in the bag structs between them (`ShellAction`'s stored
bags + optional subject; `ActionResources`' 5 optionals) and in the untyped
JSON funnel (`JSONParse -> Any`, ~142 `as?` sites). Each ticket moves one
erasure boundary outward so invalid states stop compiling. Genericity
spread is 1/5 everywhere: all three designs are concrete enums, no
associated types propagate. Alternatives rejected: validating factories
(dual representation survives), phantom-state generics (Tier-3 spread for
zero extra safety), per-adapter Codable structs (schema-loose payloads
would shatter), `some`/`any` churn (heterogeneity is real and already
correct), typed throws for adapters (open failure domain).

## 8. Dependencies & External Integrations

- **PLT-001**: Swift 6.4 toolchain, language mode v6, macOS 15+ / Linux.
  No version changes.
- No external systems, services, infrastructure, data, or compliance
  dependencies. No new SPM packages (CON-002).

## 9. Examples & Edge Cases

```swift
// T1: exhaustive switching replaces nil checks
switch shell {
case .effectOnly(let e): admit(e.effects, e.resources)
case .analyzed(let a): admit(a.analysis.effects, a.analysis.resources)
}

// T2: push refspec can no longer pose as a branch
GitAction.push(remote: "origin", refspec: "HEAD:main").resources
// == .git(remote: RemoteName("origin"), ref: .refspec("HEAD:main"))
// shared-branch match takes BranchName — .refspec does not typecheck there

// T3: typed access replaces cast chains
let ts: Double? = json["ts"]?.double  // handles int-or-double JSON numbers
```

Edge cases: T1 — old wire JSON with both XOR keys MUST still fail decode
(distinct error); missing bag keys on analyzed shells fill from projection
(keep today's defaulting). T2 — old wire with `branchName` holding a
refspec decodes tolerantly (document heuristic) but re-encodes distinctly.
T3 — JSON ints bigger than 2^53 and int-vs-double: `.number(Double)` with
`.int` failing closed when lossy; `UInt64` payloads preserved via string
fallback documented in code. Empty/missing keys yield nil, never trap.

## 10. Validation Criteria

- AC-001..AC-005 all hold per ticket (see ticket acceptance).
- `git diff --check` clean; no new warnings (`swift build`).
- Pre-delivery checklist from `swift-architecture-pipeline` satisfied.

## 11. Related Specifications / Further Reading

- Report: `/tmp/swift-type-system-review-rv-20260930-034141.html`
- Skill: `swift-type-system-architecture` (design rationale, lenses)
- Pipeline: `swift-architecture-pipeline` (execution contract)
- Prior work: HostWiring #251, typed RV slice #253, ApprovalRuntime #250

