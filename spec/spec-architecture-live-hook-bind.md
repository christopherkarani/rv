---
title: Live hook bind — one BoundReview producer, encode phase enum
version: 1.0
date_created: 2026-09-10
last_updated: 2026-09-10
owner: rv
tags:
  - architecture
  - functional-core
  - hooks
  - ask
---

# Introduction

This specification implements the Strong candidate from the 2026-09-10 functional-evolution report (`/tmp/swift-functional-evolution-rv-20260910-042356.html`, HEAD `394b456`).

**One BoundReview producer on the live hook door.** `applyGitSemantics` / `applyFilesystemSemantics` already stamp `boundReview` on semantic `hardDeny` / `mandatoryHuman`. When that stamp is missing, `HookDispatch.hookBody` re-runs `ActionPolicyEngine` on `HostCodec.proposedAction` (empty effects, no typed rules). First-call vs post-spend is still `bound: BoundReview?` plus `afterSpend: Bool`.

Do not implement OPE-156 (codec IR effects). Do not stamp `boundReview = .deny` onto pack denials (`skipsPolicyGate` would then skip allow-once). Do not put `boundReview` on the Codable wire. Do not wire live Auto-review. Do not change `AllowOnceRecord`. Do not split SetupRun. Do not inject EvaluateContext (candidate 02, out of this spec).

# 1. Purpose & Scope

## Purpose

Make the live hook door a total function of the in-process `EvaluationResult`:

- stamped semantic bind wins
- otherwise map pack `Decision` to `BoundReview` without a second policy engine
- first-call encoding always has a `BoundReview`
- post-spend encoding cannot carry a bind or unlock code

## Audience

Implementers of rv (Swift 6.3.3, language mode 6, macOS 26, Apple Silicon) using `tools/gate.sh` and `tools/swift-6.3.3`. Warm `.build`. Never `swift package clean`.

## In scope

- `HostNativeAsk.bound(from:)` (name may match file style) as the only live-door bind.
- `HookDispatch.hookBody` stops calling `hookBound(result:action:context:)` with the codec ProposedAction.
- `hookWire` first-call vs post-spend as a closed phase (T2).
- Tests that prove pack deny still unlocks, typed/semantic hard deny still skips the gate, `git status` still allows, spend-first Ask still pauses on stamped `mandatoryHuman`.

## Out of scope

- OPE-156 filling codec `ProposedAction` effects.
- `GatedEvaluate` typed-rule / probe injection (evolution candidate 02).
- HookDoor absorbing mint/record/clear closures (evolution candidate 03).
- `HelloAck`, SessionScan, SetupWorkPlan, Elm TUI, FormatFlags, analytics `Any`.
- Putting `BoundReview` on IPC Codable `EvaluationResult`.
- Changing `skipsPolicyGate` to treat pack denials as hard-bind.
- New SPM modules, new dependencies, toolchain bumps.
- `RV_BYPASS`. Live-HOME tests. Command text in logs.

## Assumptions

- Hexagon in `docs/architecture/MODULES.md` is law.
- Pack deny / indeterminate is a floor. Semantic bind is an extra deny/ask on pack allow.
- `HostCodec.proposedAction` default remains empty-effect shell IR until a later ticket.
- `LiveEvaluation` stays the in-process type that requires a bound. IPC decode still yields `boundReview == nil`.
- Product Ask is `HostNativeAsk.verdict(host:result:cwd:bound:)`. Adapters honor `decision:ask` only.

# 2. Definitions

| Term | Meaning |
|---|---|
| Stamped bind | `EvaluationResult.boundReview` set by `applyGitSemantics` / `applyFilesystemSemantics` on semantic `hardDeny` / `mandatoryHuman`. |
| Pack-decision bound | `Decision.allow` → `BoundReview.allow`; `Decision.deny(d)` → `BoundReview.deny(d)`; `Decision.indeterminate` → `BoundReview.deny` using `ActionPolicyEngine.Builtin.packIncomplete`. No engine re-run. |
| Live-door bind | `result.boundReview ?? pack-decision bound`. The only bind `hookBody` may use on first call. |
| Hard-bind skip | `GatedEvaluate.skipsPolicyGate`: `boundReview == .deny` only. Pack denials keep `boundReview == nil` so allow-once still spends. |
| First call | Host event without `hostAsk: spend`. May Ask, mint unlock, record pending. |
| Post-spend | Host callback `hostAsk: spend`. Encode allow/deny only. No unlock code. No Ask. |

# 3. Requirements, Constraints & Guidelines

## T1 — Live-door bind from EvaluationResult only

- **REQ-101**: Add a total function on `HostNativeAsk` (suggested name `bound(from:)`):

```swift
public static func bound(from result: EvaluationResult) -> BoundReview
```

  If `result.boundReview` is non-nil, return it. Otherwise return the pack-decision bound (Definitions). Do not call `ActionPolicyEngine.evaluate`.

- **REQ-102**: `HookDispatch.hookBody` first-call (non-spend) must set `bound = HostNativeAsk.bound(from: result)` and pass that into `hookWire`. Delete the `LiveEvaluation(result)` / `hookBound(result:action:context:)` branch.

- **REQ-103**: `HostNativeAsk.hookBound(_ decision: HardPolicyDecision)` stays. It is the Engine→hook projection used by `apply*Semantics` callers and Domain tests of hard-policy cases.

- **REQ-104**: `HostNativeAsk.hookBound(result:action:context:)` must not be called from `Sources/RVHooks`. Keep the function in Domain if existing Domain tests use it; do not use it as the live-door fallback. Optionally retarget those Domain tests at `ActionPolicyEngine.evaluate` + `hookBound(_:)` — not required if the function remains.

- **REQ-105**: Do not assign `boundReview = .deny` on pack denials inside Engine or GatedEvaluate. `skipsPolicyGate` behavior is unchanged: only a stamped semantic `.deny` skips the gate.

- **REQ-106**: Codec `proposedAction` is still computed in `hookBody` for pending record/clear fingerprints. It is not policy input.

- **CON-101**: No `Decision.ask`. No BoundReview on Codable wire.

- **CON-102**: Spend-first Ask still requires `HostNativeAsk.verdict` → `.ask`. Unlockable pack deny (nil stamp, pack `Decision.deny`, cwd + matching view, not pinned) still Asks. Stamped `mandatoryHuman` still Asks. `git status` pack allow + nil stamp → `BoundReview.allow` → allow.

- **GUD-101**: Prefer one helper over duplicating the pack-decision switch in HookDispatch.

## T2 — Encode phase enum

- **REQ-201**: Replace `hookWire(..., bound: BoundReview? = nil, cwd: WorkingDirectory? = nil, afterSpend: Bool = false, unlockCode: String? = nil)` with a closed phase. Suggested shape:

```swift
public enum HookEncodePhase: Sendable, Equatable {
    case firstCall(bound: BoundReview, cwd: WorkingDirectory?, unlockCode: String?)
    case postSpend
}
```

  Exact associated-value names may match file style. `hookWire` takes `phase: HookEncodePhase` (or an overload pair `hookWire(firstCall:)` / `hookWire(postSpend:)`). There is no `afterSpend: Bool`. There is no optional `bound` on first call.

- **REQ-202**: First-call Claude allow with a missing bound is unrepresentable. Delete the `guard let bound else { encodeRichDeny }` branch on the allow arm; first-call always has a bound.

- **REQ-203**: Post-spend ignores unlock codes and never encodes Ask. Existing post-spend allow/deny/indeterminate behavior stays.

- **REQ-204**: Update `HookDispatch` call sites and `Tests/RVHooksTests/HostAskHookTests.swift` `afterSpend: true` call sites.

- **CON-201**: Do not change host JSON keys, exit codes, or leftover-ask-as-permit (never emit Claude `permissionDecision: "ask"`).

- **CON-202**: Do not edit `Sources/rv-c/**`.

## Shared constraints

- **CON-301**: Swift 6.3.3, language mode 6, `tools/gate.sh` for touched test targets. Do not wipe `.build`.
- **CON-302**: No `try!` / IUO on production paths. No `isDenied`. Value types in Domain/Engine/Packs/Presentation.
- **CON-303**: Fixtures stay under `Tests/`. No live-HOME tests.
- **GUD-301**: Small diffs. Do not restyle unrelated files.
- **GUD-302**: Swift Testing (`import Testing`). No XCTest.

# 4. Interfaces & Data Contracts

## Live-door bind

```swift
extension HostNativeAsk {
    public static func bound(from result: EvaluationResult) -> BoundReview {
        if let stamped = result.boundReview { return stamped }
        switch result.decision {
        case .allow:
            return .allow
        case .deny(let deny):
            return .deny(deny)
        case .indeterminate:
            return .deny(ActionPolicyEngine.Builtin.packIncomplete)
        }
    }
}
```

## Encode phase (T2)

First call: `phase: .firstCall(bound:bound, cwd:request.cwd, unlockCode:unlockCode)`.

Post-spend: `phase: .postSpend`.

Wire JSON unchanged.

# 5. Acceptance Criteria

- **AC-101**: Given pack allow (`outcome: .plain`) and `boundReview == nil`, when `HostNativeAsk.bound(from:)` runs, then the bind is `.allow`. `git status` first-call encodes allow on spend-first hosts.
- **AC-102**: Given pack deny `core.git:reset-hard` with cwd + matching view and `boundReview == nil`, when first-call runs on Pi, then product verdict is Ask (unlockable pack deny). `skipsPolicyGate` is false for that result.
- **AC-103**: Given stamped `boundReview == .deny` (typed/shared-branch/protected-path), when `GatedEvaluate` peeks/applies, then PolicyGate is skipped (no allow-once spend).
- **AC-104**: Given stamped `boundReview == .mandatoryHuman` and a spend-first host with cwd + nonempty matching view, when first-call encodes, then stdout is `{decision:ask}` (Claude: short ask, never `permissionDecision:ask`).
- **AC-105**: `Sources/RVHooks` does not call `hookBound(result:action:context:)`.
- **AC-106**: `tools/gate.sh RVDomainTests` is green after T1. `tools/gate.sh RVHooksTests` is green after T1.
- **AC-201**: `hookWire` has no `afterSpend: Bool` parameter. First-call requires `BoundReview`. Post-spend cannot pass `unlockCode`.
- **AC-202**: Existing `hookWire_afterFailedSpendStaysDeny` and `hookWire_claudeAfterSpendAllowIsEmpty` stay green, rewritten onto the phase API.
- **AC-203**: `tools/gate.sh RVHooksTests` is green after T2.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint | specialist |
|---|---|---|---|---|---|---|
| T1 | Live-door bind from EvaluationResult only | none | `Sources/RVDomain/HostNativeAsk.swift`, `Sources/RVHooks/HookDispatch.swift`, `Tests/RVDomainTests/HostNativeAskTests.swift`, `Tests/RVHooksTests/HostAskHookTests.swift` | AC-101, AC-102, AC-103, AC-104, AC-105, AC-106 | 101–1499 | swift-type-system-architecture, swift-functional-core, swift-testing-pro |
| T2 | Close hookWire first-call vs post-spend | T1 | `Sources/RVHooks/HookMapper.swift`, `Sources/RVHooks/HookDispatch.swift`, `Tests/RVHooksTests/HostAskHookTests.swift` | AC-201, AC-202, AC-203 | 101–1499 | swift-type-system-architecture, swift-testing-pro |

Frontier: T1. T2 after T1 commit is on its branch (stack on T1). Overlapping writes on `HookDispatch.swift` and `HostAskHookTests.swift` — do not parallelize.

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit tests in `RVDomainTests` and `RVHooksTests`. No live host, no live HOME.
- **Frameworks**: Swift Testing (`import Testing`). Gate: `tools/gate.sh RVDomainTests` / `tools/gate.sh RVHooksTests`.
- **Test Data Management**: Construct `EvaluationResult` values. Temp cwd via `WorkingDirectory(validating:)`.
- **CI/CD Integration**: Existing `tools/gate.sh`. Warm `.build`.
- **Coverage Requirements**: New tests for `bound(from:)` pack allow / pack deny / stamped bind / indeterminate. Existing Host Ask hook tests remain the product oracle.
- **Performance Testing**: Not required.

# 7. Rationale & Context

Typed rules now load at evaluate (`GatedEvaluate.evaluateWithSemantics`, #186). Semantic binds stamp `boundReview` from `ActionPolicyEngine` inside Engine. The hook-door fallback re-evaluates the engine on an empty-effect codec action, which cannot see typed rules or analyzer effects. That fallback is equivalent to mapping pack `Decision` for empty effects, and is a footgun once codecs grow IR.

`boundReview == .deny` is also the PolicyGate skip flag. Collapsing pack denials into that stamp would disable allow-once. The optional stays meaningful: nil means pack-only (gate may spend); `.deny` means semantic hard-bind (gate skipped). The live door still always has a `BoundReview` for Ask encoding, derived at the last moment without mutating the result.

# 8. Dependencies & External Integrations

### External Systems

None.

### Third-Party Services

None.

### Infrastructure Dependencies

- **INF-001**: Swift 6.3.3 toolchain via `tools/swift-6.3.3`. macOS 26 SDK.

### Data Dependencies

None.

### Technology Platform Dependencies

- **PLT-001**: Swift tools 6.3, language mode 6, Apple Silicon macOS 26.

### Compliance Dependencies

- **COM-001**: Factory hook-guard law: no `RV_BYPASS`, no allow-because-XPC-missed, no command text in `os_log`, leftover Ask is never a permit.

# 9. Examples & Edge Cases

```swift
// Pack allow, no stamp → first-call allow
HostNativeAsk.bound(from: EvaluationResult(outcome: .plain, matchingView: "git status"))
// .allow

// Pack deny, no stamp → BoundReview.deny(pack). UnlockableDeny may still Ask.
HostNativeAsk.bound(from: EvaluationResult(
    outcome: .deny(Deny(ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"), reason: "x"), matched: nil),
    matchingView: "git reset --hard"
))
// .deny(pack) — skipsPolicyGate is false because boundReview on the result is still nil

// Stamped semantic deny — skip gate, no Ask
var stamped = packAllow
stamped.boundReview = .deny(ActionPolicyEngine.Builtin.remoteSharedBranch)
HostNativeAsk.bound(from: stamped) // .deny(builtin)
```

Indeterminate pack evaluation: pack-decision bound is `.deny(packIncomplete)`. First-call encodes deny, never Ask (`encodesHostAsk` already skips indeterminate).

# 10. Validation Criteria

- `rg 'hookBound\\(result:' Sources/RVHooks` is empty after T1.
- `rg 'afterSpend' Sources/RVHooks` is empty after T2.
- `tools/gate.sh RVDomainTests` and `tools/gate.sh RVHooksTests` pass.
- `git reset --hard` on Pi still Asks when unlockable; Grok still deny-or-TTY.
- Shared-branch typed/semantic deny still cannot be spent.

# 11. Related Specifications / Further Reading

- `spec/spec-architecture-hook-bound-review.md` — original live BoundReview wiring (fallback to `hookBound(result:action:)` is what this spec removes from the door).
- `spec/spec-architecture-type-system-live-wire.md` — AC-102 already prefers stamped bind over the engine fallback.
- `spec/spec-architecture-bound-review-fingerprint.md` — REQ-104 documents today’s fallback; this spec replaces it.
- `docs/architecture/MODULES.md` — hexagon.
- `docs/architecture/02.md` — Host Ask before Auto-review; do not start OPE-156 here.
- HTML: `/tmp/swift-functional-evolution-rv-20260910-042356.html`
