---
title: Type-system — live vs wire evaluation and typed pack index
version: 1.0
date_created: 2026-09-01
last_updated: 2026-09-01
owner: rv
tags: [architecture, type-system, evaluation, packs]
---

# Introduction

Encode two invariants the compiler does not currently prove: (1) the live hook door always has a `BoundReview`, while the IPC wire never does; (2) in-memory pack index membership is `PackID`, not `String`.

Strong candidates executed: 01 (live/wire), 02 (pack index). Not executed: 03 HostID unify, 04 ProposedAction IR (blocked on OPE-156).

## 1. Purpose & Scope

Package-internal type split. No ABI / library-evolution. No Decision.ask case. Codable evaluate wire stays without `boundReview`.

## 2. Definitions

- **Live evaluation**: in-process `evaluate` / apply*Semantics / hook first-call.
- **Wire evaluation**: `EvaluateReply.result` Codable payload.
- **BoundReview**: hook-door authorization `{ allow | deny | mandatoryHuman }`.

## 3. Requirements, Constraints & Guidelines

- **REQ-001**: After JSON index decode, `PackIndex.packIDs` is `[PackID]`. `categories` / `presets` / `defaultEnabled` are `[PackID]` (or `[String: [PackID]]`). File DTO may stay `[String]`.
- **REQ-002**: `PackSet` / `SelectionToken.parse` / `PackCatalog.bundlingAll` membership uses `PackID` equality, not `contains(id.rawValue)` against `[String]`.
- **REQ-003**: Invalid index pack strings still throw `PackLoadError.invalidPackID` at decode (existing validate).
- **REQ-101**: Introduce a live result type whose `bound: BoundReview` is non-optional. Hook first-call (non-spend) takes that type and must not `?? hookBound` on empty `ProposedAction` when apply* already bound.
- **REQ-102**: `EvaluateReply` / `EvaluationResult` Codable continues to omit `boundReview`. Decode produces wire result with no bind. Assigning live bind onto a decoded wire value is not representable on the wire type.
- **REQ-103**: `applyGitSemantics` / `applyFilesystemSemantics` still set `boundReview` on hardDeny / mandatoryHuman. Allow / uncovered remain wire-compatible `Decision.allow` with live bind computed once at the evaluate door (GatedEvaluate / EvaluateSession), not re-derived in Hooks from empty shell when a live bind exists.
- **CON-001**: Do not add `Decision.ask`. Product Ask stays `HostAskVerdict`.
- **CON-002**: Do not persist command text. Do not change host deny JSON.
- **CON-003**: Do not unify `HookHost` / `ScanHostID` in this spec.
- **GUD-001**: Prefer two structs over `EvaluationResult<Phantom>`. Hide conversion at IPC encode/decode.
- **PAT-001**: File/JSON/TOML edges stay `String`. In-memory domain uses newtypes / closed enums.

## 4. Interfaces & Data Contracts

```swift
public struct PackIndex: Equatable, Sendable {
    public var defaultEnabled: [PackID]
    public var categories: [String: [PackID]]
    public var presets: [String: [PackID]]
    public var packIDs: [PackID] { categories.values.flatMap { $0 }.sorted { $0.rawValue < $1.rawValue } }
}

public struct LiveEvaluation: Sendable, Equatable {
    public var outcome: EvaluationOutcome
    public var matchingView: MatchingView
    public var analysis: SemanticAnalysis
    public var bound: BoundReview
}

// Wire remains EvaluationResult Codable without boundReview in CodingKeys.
```

Conversion: `LiveEvaluation.wire` → `EvaluationResult` (bound omitted). `LiveEvaluation.result` keeps the in-process bind. In-process hook maps `EvaluationResult` with non-nil `boundReview` to `LiveEvaluation` without calling `hookBound`, and encodes from `live.wire` plus `bound: live.bound`. Nil bind + allow still may call `hookBound` for uncovered pack-fallback Ask (REQ-103 uncovered).

## 5. Acceptance Criteria

- **AC-001**: Given a valid index JSON, When decoded, Then `packIDs` is `[PackID]` and `bundlingAll` does not call `PackID(validating:)` on already-typed IDs.
- **AC-002**: Given `PackSet.order`, When an unknown `PackID` is included, Then it is dropped via `Set<PackID>` membership.
- **AC-101**: Given applyGitSemantics `mandatoryHuman`, When inspected in-process, Then live bind is `.mandatoryHuman` and Codable JSON has no `boundReview` key.
- **AC-102**: Given hook first-call with non-nil `result.boundReview`, When encoding wire, Then `HostNativeAsk.hookBound(result:action:context:)` is not used for that bind.
- **AC-103**: Given XPC-decoded `EvaluationResult`, When hook maps, Then bind is computed (fallback) because wire has none — documented, not a silent allow.

## 5b. Tickets

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | PackIndex in-memory PackID | none | `Sources/RVPacks/PackIndex.swift`, `PackEnablement.swift`, `PackCatalog.swift`, `SelectionToken.swift`, `PackRegistry.swift`, `Tests/RVPacksTests/EnablementTests.swift`, `Tests/RVPacksTests/SelectionTokenTests.swift` | AC-001, AC-002 | 101–1499 |
| T2 | LiveEvaluation / hook bind required | none | `Sources/RVDomain/EvaluationResult.swift` (additive LiveEvaluation), `Sources/RVHooks/HookDispatch.swift`, `Tests/RVDomainTests/EvaluationResultBoundReviewTests.swift`, `Tests/RVHooksTests/**` only as needed for AC-102 | AC-101, AC-102, AC-103 | 101–1499 |

T1 and T2 do not share exclusive-writes. Parallel.

## 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit in RVPacksTests, RVDomainTests, RVHooksTests.
- **Frameworks**: Swift Testing. No live HOME.
- **CI**: `tools/gate.sh RVPacksTests` then `RVDomainTests` / `RVHooksTests`.
- **Coverage**: membership and hook bind fallback vs non-nil path.

## 7. Rationale & Context

`PackID` already exists; the index still speaks `String`, so `contains(rawValue)` is a type-system hole. `boundReview: BoundReview?` on one Codable type is why IPC drops Ask zone and why hook re-evals empty shell.

## 8. Dependencies & External Integrations

- **PLT-001**: Swift 6.3.3, language mode 6, macOS 26.
- **DAT-001**: Bundled pack index JSON unchanged on disk.

## 9. Examples & Edge Cases

```swift
// T1
known.contains(packID) // not known.contains(packID.rawValue)

// T2
let live = LiveEvaluation(..., bound: .mandatoryHuman(deny))
try JSONEncoder().encode(live.wire) // no boundReview key
```

## 10. Validation Criteria

`tools/gate.sh RVPacksTests` green after T1. T2: existing bound-review tests plus hook first-call does not empty-shell rebind when bind present.

## 11. Related Specifications / Further Reading

- `spec/spec-architecture-bound-review-fingerprint.md`
- `docs/architecture/MODULES.md`
- HTML type-system review 2026-09-01
