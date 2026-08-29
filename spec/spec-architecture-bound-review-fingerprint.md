---
title: Preserve BoundReview through evaluate→hook door; own ActionFingerprint construction
version: 1.0
date_created: 2026-08-29
owner: architecture-pipeline
tags: [architecture, functional-evolution, OPE-156]
---

# Introduction

Stop erasing `HardPolicyDecision.mandatoryHuman` into bare `Decision.deny` without a recoverable `BoundReview`, and stop building host `ProposedAction` fingerprints via string interpolation duplicated across codecs. This is the Strong pair from the 2026-08-29 functional-evolution report (C01 top, C02 sibling).

## 1. Purpose & Scope

**Audience:** implement-spec agents on `rv` (Swift 6.3.3, language mode 6, macOS 26).

**In scope:**

1. Carry `BoundReview` from semantic apply into the hook door so Host Ask can pause on `mandatoryHuman`.
2. Own `ActionFingerprint` construction behind a pure builder; introduce `SessionID`; delete Codex/Cursor `proposedAction` overrides that only re-spell the default.

**Out of scope:**

- Full hard-policy-before-packs strangler.
- Fingerprint-keyed grants (OPE-158).
- Changing `Decision` cases; Ask must not become a `Decision` case.
- `RuleMatch.packID` derivation, UninstallWorkPlan, SetupWorkPlan, HelloAck, Elm TUI, ScanRun thinning, PacksConfig `[PackID]`.
- Wiring live git branch / shared-branch probe into `ReviewContext` (existing gap; do not expand).

## 2. Definitions

| Term | Meaning |
|---|---|
| `BoundReview` | `allow` / `deny(Deny)` / `mandatoryHuman(Deny)` after hard policy (+ optional review bind). |
| `HardPolicyDecision` | Pure `ActionPolicyEngine` verdict including `mandatoryHuman` and `reviewEligible`. |
| `Decision` | Pack/evaluate public verdict: `allow` / `deny` / `indeterminate`. Ask is uninhabited. |
| Hook door | `HookDispatch.hookBody` → `hookWire` path after gated evaluate. |
| ActionFingerprint | Stable grant/audit identity string newtype. |

## 3. Requirements, Constraints & Guidelines

### T1 — BoundReview on EvaluationResult (C01)

- **REQ-101**: Add `public var boundReview: BoundReview?` on `EvaluationResult`. Default `nil`. Omit from Codable `CodingKeys` (IPC wire unchanged; in-process only).
- **REQ-102**: `applyGitSemantics` / `applyFilesystemSemantics`: on `.hardDeny(d)` set `boundReview = .deny(d)` and keep `outcome = .deny(d, matched: nil)`. On `.mandatoryHuman(d)` set `boundReview = .mandatoryHuman(d)` and keep the same deny outcome (pack/IPC floor still `Decision.deny`).
- **REQ-103**: On `.hardAllow` / `.reviewEligible` leave `boundReview` nil (hook door may still compute via `hookBound` for pack-fallback Ask).
- **REQ-104**: `HookDispatch.hookBody` (first-call, non-spend): `let bound = result.boundReview ?? HostNativeAsk.hookBound(result:action:context:)` using existing codec `proposedAction` + `ReviewContext(repository: RepositoryReviewContext())` only as fallback when `boundReview` is nil.
- **REQ-105**: Do not call `ActionPolicyEngine` a second time when `result.boundReview != nil`.
- **CON-101**: Ask is not a `Decision` case. Pack deny / indeterminate floors unchanged. Secret-path and `builtin.action` hard denies stay fail-closed.
- **CON-102**: Do not edit fingerprint construction in T1.
- **GUD-101**: Prefer the smaller cut (carry BoundReview) over reordering evaluate vs hard policy.
- **PAT-101**: Same pattern as prior ReviewBind / HostNativeAsk work — values at the door, effects outside.

### T2 — ActionFingerprint ownership (C02)

- **REQ-201**: Add `SessionID` newtype (`RawRepresentable`, `Hashable`, `Sendable`, `Equatable`, `Codable`) in RVDomain. Validating init rejects `""`.
- **REQ-202**: `HookRequest.session` becomes `SessionID?` (not `String?`). Codecs map nonempty session/turn ids through `SessionID(validating:)` / equivalent; empty → nil.
- **REQ-203**: Add pure `ActionFingerprint.make(host:session:cwd:command:)` (name may match file style) that owns the spelling currently inlined as `"\(host):\(session):\(cwd):\(command)"` with nil session/cwd as empty field slots only inside the builder (callers pass optionals).
- **REQ-204**: Default `HostCodec.proposedAction` uses `ActionFingerprint.make`. Delete `proposedAction` overrides on `CodexHostCodec` and `CursorHostCodec` when identical to the default.
- **REQ-205**: Update `ProposedAction.swift` comment: IR owns host-door fingerprint construction; semantic `GitAction`/`FilesystemAction` fingerprints remain distinct until a later IR composition ticket.
- **CON-201**: Do not migrate AllowOnce / matchingView grants to fingerprints (OPE-158). Do not change GitAction fingerprint alphabet.
- **CON-202**: Depends on T1 merge base so HookDispatch / hook tests stay coherent; T2 must not revert T1 `boundReview` behavior.

## 4. Interfaces & Data Contracts

```swift
// EvaluationResult (in-process additive)
public var boundReview: BoundReview?  // not Codable

// SessionID
public struct SessionID: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String
    public init?(validating rawValue: String) // rejects ""
}

// ActionFingerprint
public static func make(
    host: HookHost,
    session: SessionID?,
    cwd: WorkingDirectory?,
    command: ShellCommand
) -> ActionFingerprint
```

IPC `EvaluateReply` / Codable `EvaluationResult` bytes unchanged (no new keys).

## 5. Acceptance Criteria

- **AC-101**: Given applyGitSemantics yields `mandatoryHuman(remoteBranchAsk)`, When `EvaluationResult` is inspected in-process, Then `boundReview == .mandatoryHuman(remoteBranchAsk)` and `decision` is still `.deny(remoteBranchAsk)`.
- **AC-102**: Given that result on a spend-first host with cwd + nonempty matching view, When `hookWire`/`HostNativeAsk.verdict` runs, Then product Ask pauses (`.ask`), not hard deny-only.
- **AC-103**: Given `boundReview != nil`, When hookBody binds, Then `HostNativeAsk.hookBound(result:action:context:)` is not required for that bind (fallback path unused).
- **AC-201**: `ActionFingerprint.make` unit tests cover nil session, nil cwd, and host raw values.
- **AC-202**: `rg -n 'proposedAction\\(from' Sources/RVHooks/CodexHostCodec.swift Sources/RVHooks/CursorHostCodec.swift` matches nothing (overrides removed).
- **AC-203**: `HookRequest.session` is `SessionID?`; empty string cannot round-trip as a session.

## 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | Carry BoundReview from apply*Semantics through HookDispatch | none | `Sources/RVDomain/EvaluationResult.swift`, `Sources/RVEngine/ApplyGitSemantics.swift`, `Sources/RVEngine/ApplyFilesystemSemantics.swift`, `Sources/RVHooks/HookDispatch.swift`, `Tests/RVDomainTests/` (EvaluationResult / BoundReview carry only), `Tests/RVEngineTests/` (apply*Semantics BoundReview), `Tests/RVHooksTests/` (hook Ask on mandatoryHuman carry) | AC-101, AC-102, AC-103; `tools/gate.sh RVDomainTests RVEngineTests RVHooksTests` | 101–1499 |
| T2 | SessionID + ActionFingerprint.make; delete codec fingerprint dupes | T1 | `Sources/RVDomain/ProposedAction.swift`, `Sources/RVDomain/SessionID.swift` (new) or colocated file, `Sources/RVHooks/HostCodec.swift`, `Sources/RVHooks/CodexHostCodec.swift`, `Sources/RVHooks/CursorHostCodec.swift`, all HostCodec decode sites that set `session:`, `Tests/RVDomainTests/` (fingerprint/SessionID), `Tests/RVHooksTests/` (codec session typing) | AC-201, AC-202, AC-203; `tools/gate.sh RVDomainTests RVHooksTests` | ≤100 or 101–1499 |

Specialists: T1 → `swift-functional-architecture` + `.grok/skills/swift-hook-xpc` + `swift-testing-pro`. T2 → `swift-type-system-architecture` + `swift-hook-xpc` + `swift-testing-pro`.

## 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit tests in module test targets.
- **Frameworks**: Swift Testing (`import Testing`). No XCTest. No live-HOME.
- **Commands**: `tools/gate.sh RVDomainTests`, `RVEngineTests`, `RVHooksTests` as listed per ticket. Warm `.build`; do not `swift package clean`.
- **Coverage**: New BoundReview carry + fingerprint builder paths.

## 7. Rationale & Context

`ActionPolicyEngine` already emits `mandatoryHuman`, but `apply*Semantics` flattens it to `Decision.deny` and `HookDispatch` re-evaluates an empty-effect `ProposedAction`, so `BoundReview.mandatoryHuman` never reaches Ask. Builtin.action denies are not unlockable pack denies, so Ask cannot recover via the pack-deny path. Carrying `BoundReview` in-process restores the value without IPC churn.

Fingerprint string concat and Codex/Cursor clones block OPE-156 IR ownership; a pure builder + `SessionID` is the small Strong sibling.

## 8. Dependencies & External Integrations

### Technology Platform Dependencies
- **PLT-001**: Swift 6.3.3 / language mode 6 / macOS 26 — no toolchain bump.

### Compliance Dependencies
- **COM-001**: AGENTS.md functional core / no `RV_BYPASS` / Ask not a Decision case.

## 9. Examples & Edge Cases

```swift
// T1 — carry
case .mandatoryHuman(let deny):
    return EvaluationResult(
        outcome: .deny(deny, matched: nil),
        matchingView: pack.matchingView,
        analysis: analysis,
        boundReview: .mandatoryHuman(deny)
    )

// T1 — hook bind
let bound = result.boundReview ?? HostNativeAsk.hookBound(
    result: result,
    action: codec.proposedAction(from: request),
    context: ReviewContext(repository: RepositoryReviewContext())
)

// T2 — fingerprint
ActionFingerprint.make(
    host: .pi,
    session: SessionID(validating: "s1"),
    cwd: WorkingDirectory(validating: "/repo"),
    command: ShellCommand(rawValue: "git status")
)
```

Edge: `reviewEligible` from apply* stays nil `boundReview`; hook fallback may still project `.allow` on hook door per existing `HostNativeAsk.hookBound` (reviewEligible → allow). Do not change that mapping in this spec.

## 10. Validation Criteria

- Ticket gates green.
- No new `Decision` case.
- Codable EvaluationResult golden / round-trip tests unchanged for wire keys.
- Codex/Cursor deny honor paths unchanged (only `proposedAction` override removal).

## 11. Related Specifications / Further Reading

- `docs/architecture/02.md` (OPE-156 order)
- `docs/architecture/MODULES.md`
- `spec/spec-architecture-hook-bound-review.md`
- HTML: `TMPDIR/swift-functional-evolution-rv-20260829-154717.html`
