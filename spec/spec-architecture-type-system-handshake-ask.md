---
title: Type-system pass — HelloAck handshake enum, EvaluationOutcome projections, pack vs bound Ask doors
version: 1.0
date_created: 2026-08-27
last_updated: 2026-08-27
owner: rv
tags:
  - architecture
  - type-system
  - ipc
  - hooks
  - ask
---

# Introduction

Execute the three Strong candidates from `$TMPDIR/swift-type-system-review-rv-20260827-210539.html` (HEAD `fe66584`, branch `worktree/calm-river-cc81`).

1. **T1** — Close `HelloAck` / `HelloAckView` as `ok` | `skew(SkewReason)`. Wire JSON frozen.
2. **T2** — One total projection from `EvaluationOutcome` for explain, classify, and `ExplainViewModel`. Depends on T1 (`ServiceRuntime.swift`).
3. **T3** — Split pack-door `Decision` from bound-door `BoundReview` so `HostAskVerdict.ask` is uninhabited on the pack path. Parallel with T1.

Do not implement Worth-exploring C4 (`RuleMatch` derived `packID`). Do not revive unmerged `arch/d874c57d/TS-C1` `IPCRoute`.

Audience: fresh-context implementer and reviewer subagents. Toolchain: Swift 6.3.3 (`tools/swift-6.3.3`), language mode 6, macOS 26. Gate: `tools/gate.sh`. Warm `.build`. Never `swift package clean`.

# 1. Purpose & Scope

Make three illegal programs unrepresentable:

- Handshake `ok:true` with a skew reason, or `ok:false` with no reason.
- Explain/classify/TTY projecting different rule identities from one `EvaluationOutcome`.
- Passing pack `Decision` into an API whose result type includes Ask.

## In scope

- In-memory `HelloAck.status` / `HelloAckView.status` plus Codable that preserves golden frames in `Tests/RVIPCTests/SkewReasonTests.swift`.
- `EvaluationOutcome` projections used by `ExplainReply`, `ClassifyReply`, `ClassifyRisk.derive`, `explainViewModel`, `ServiceRuntime.explain` / `classify`, `ScanClassify` pack/rule fields.
- `PackDoorVerdict` and two `HostNativeAsk.verdict` overloads; `HookMapper.encodeFirstCall` call sites.

## Out of scope

- `IPCRoute` / generic `serve<R>`.
- Merging `ScanHostID` into `HookHost`.
- `PackID(rawValue:)` failable, `PacksConfig` `[String]`, `SelectionToken.unknown`.
- SemVer newtype (`ProtocolVersion.isMajorSkew` fail-open is a one-line product bug, not this spec).
- `DoctorCheckID` host cases, `AllowOnceConsumeParams`, `ExplainStage.name`, analytics `Any`, `ApprovalBridge` collapse, leftoverAskIsPermit.
- `RuleMatch` stored `packID` / `patternName` (C4).
- Wire key names. C `rv` hook. `Decision` remaining a three-case enum (Ask is not a Decision case).

# 2. Definitions

| Term | Meaning |
|---|---|
| HandshakeStatus | Closed `ok` or `skew(SkewReason)`. The in-memory handshake result. |
| Golden frame | Exact UTF-8 JSON in `SkewReasonTests.goldenFramesEncodeByteIdenticalToLegacyStringWire`. |
| Outcome projection | Total function from `EvaluationOutcome` to explain/classify identity (rule, pack, classify risk). |
| Pack door | Hook first-call path when `BoundReview` is absent. Pack `Decision` only. Cannot Ask. |
| Bound door | Hook first-call path when `BoundReview` is present. May Ask on spend-first + `mandatoryHuman`. |
| rv.ipc.v1 freeze | JSON keys and healthy/skewed HelloAck byte strings stay identical. Decode of illegal combos may become stricter. |

# 3. Requirements, Constraints & Guidelines

## T1 — HelloAck handshake enum

- **REQ-101**: Replace `HelloAck.ok: Bool` + `HelloAck.skewReason: SkewReason?` with `public var status: HandshakeStatus` where `HandshakeStatus` is `ok` | `skew(SkewReason)`. Put the enum in `Sources/RVIPC/IPCEnvelope.swift` (or `SkewReason.swift` if that keeps IPCEnvelope smaller). `Sendable`, `Equatable`.
- **REQ-102**: Delete `HelloAck.init(..., ok: Bool, skewReason: SkewReason? = nil)`. Construction is `HelloAck(..., status: .ok)` or `HelloAck(..., status: .skew(.protocolSkew))`. No memberwise soup initializer.
- **REQ-103**: Custom `Codable` on `HelloAck` keeps keys `protocol`, `serviceSemver`, `ok`, `skewReason`. Encode `.ok` as `"ok":true` and omit `skewReason` (byte-identical to current healthy golden frame). Encode `.skew(r)` as `"ok":false` plus `"skewReason"` using existing `SkewReason` raw values.
- **REQ-104**: Decode `"ok":true` with a present `skewReason` throws `DecodingError`. Decode `"ok":false` with missing/null `skewReason` throws `DecodingError`. Decode `"ok":false` with unknown reason string still throws (existing `unknownReasonStringFailsDecodeInsteadOfYieldingNil`). Replace `missingReasonDecodesAsNil` with a throw expectation.
- **REQ-105**: `HelloAckView` stores the same `status` (not `ok` + optional reason). `init(_ ack: HelloAck)` copies `status`. `ServiceTransport.hello` still returns `HelloAckView`.
- **REQ-106**: `ServiceRuntime.acknowledge` returns `.skew(.protocolSkew|.majorVersion|.corePacksUnavailable)` or `.ok`. `handleIncoming` uses `status` (not `ack.ok`). `handleUnreadyIncoming` switches `ack.status`; delete `ack.skewReason ?? .protocolSkew`.
- **REQ-107**: `ServiceClient.skewReason(_:)` switches `ack.status`. Mapping: `.ok` plus protocol/semver checks as today; `.skew(.corePacksUnavailable)` → `.corePacksUnavailable`; `.skew(.majorVersion)` → `.majorVersionMismatch`; `.skew(.protocolSkew)` and `.skew(.handshakeRequired)` → `.rejected`. Keep the existing protocol-name and major-semver checks that run even when status is `.ok` (defense in depth; do not drop them).
- **CON-101**: No generics, no phantom handshake state, no `ProtocolName` / `SemVer` newtypes in this ticket.
- **CON-102**: Do not edit `Sources/rv-c/**`. Do not change `SkewReason` raw values.
- **GUD-101**: Follow `EvaluationResult` composing-decode: illegal wire combo is `DecodingError`, not a defaulted Bool.

## T2 — EvaluationOutcome is the only projection

- **REQ-201**: Add a package-visible or public total projection on `EvaluationOutcome` in RVDomain (`EvaluationResult.swift` or `ExplainStep.swift`). Suggested shape (names may match file style):

  ```swift
  public var explainRuleID: RuleID? { get }
  public var explainPackID: PackID? { get }
  ```

  Exhaustive switch:

  | Outcome | `explainRuleID` | `explainPackID` |
  |---|---|---|
  | `.hit(match, _)` | `match.ruleID` | `match.packID` |
  | `.safeOnly(safe)` | `nil` | `safe.packID` |
  | `.deny(deny, _)` | `deny.ruleID` | `deny.ruleID.pack` |
  | `.quickRejected`, `.plain`, `.indeterminate` | `nil` | `nil` |

  Deny always uses `Deny.ruleID`, never `matched?.ruleID`. That is the TTY law and the leftover-ask/secret-path law.

- **REQ-202**: `ClassifyRisk.derive` takes `EvaluationOutcome` (or `EvaluationResult`). Delete the `Decision` × `RuleMatch?` pair as the production API. Implementation:

  | Outcome | Risk |
  |---|---|
  | `.quickRejected`, `.plain`, `.safeOnly` | `.safe` |
  | `.hit(match, _)` | `.rated(match.severity)` |
  | `.deny(_, .some(match))` | `.rated(match.severity)` |
  | `.deny(_, .none)` | `.rated(.high)` |
  | `.indeterminate` | `.rated(.high)` |

  Keep Codable for `ClassifyRisk` unchanged. A deprecated shim `derive(decision:matched:)` is forbidden — update tests.

- **REQ-203**: `ExplainReply` public production initializer takes `result`, `normalized`, `suggestion`, `stages` and sets `ruleID` / `packID` from the projection. Do not keep a public memberwise init that accepts independent `ruleID`/`packID` lying about `result`. Codable stored keys stay `result`, `normalized`, `ruleID`, `packID`, `suggestion`, `stages`. Decode may re-derive from `result.outcome` and ignore lying sibling fields, or throw if siblings disagree. Prefer **re-derive and ignore siblings** so old frames with XPC `match?.ruleID` still load; encoded output then follows REQ-201 (deny uses `Deny.ruleID`).
- **REQ-204**: `ClassifyReply` production initializer takes `result` plus `reasons`/`suggestions` (or derives reasons from the outcome). `decision` is `result.decision`. `risk` is `ClassifyRisk.derive(outcome)`. `ruleID`/`packID` from the same projection as explain. Codable keys unchanged. Same decode policy as REQ-203 (re-derive).
- **REQ-205**: `ServiceRuntime.explain` and `classify` construct replies only through those initializers. Delete the local `switch result.outcome` that filled `ruleID`/`packID` by hand.
- **REQ-206**: `explainViewModel(from:command:normalized:)` uses the same projection for `packID`/`ruleID`. Safe-only allow may now expose `packID` (XPC law). Deny uses `deny.ruleID`. Match-backed display fields (`patternName`, `severity`, `explanation`, `regex`) still come from `outcome.matched` (hit or deny's optional `RuleMatch`).
- **REQ-207**: `ScanClassify.classify` sets `packID` from the projection (`explainPackID ?? deny.ruleID.pack` is redundant after REQ-201 — use `explainPackID!` only if you still have a deny; prefer `deny.ruleID.pack` on the deny case you already matched).
- **CON-201**: Do not change `EvaluationOutcome` cases. Do not flatten it back into optionals. Do not add generics.
- **CON-202**: `ExplainReply` / `ClassifyReply` JSON keys unchanged. Robot schemas `rv.explain.v1` keys unchanged (`pack_id` / `rule_id` still strings).
- **GUD-201**: One function in RVDomain; IPC and Presentation call it. Do not copy the switch.

## T3 — Pack door vs bound door

- **REQ-301**: Add `public enum PackDoorVerdict: Sendable, Equatable { case allow, case deny }`.
- **REQ-302**: Replace `HostNativeAsk.verdict(host:decision:)` with `HostNativeAsk.verdict(_ decision: Decision) -> PackDoorVerdict`. No `HookHost` parameter. `.allow` → `.allow`; `.deny` and `.indeterminate` → `.deny`. Cannot return Ask.
- **REQ-303**: Keep `verdict(host:bound:continuation:) -> HostAskVerdict` as the only pause door. Default `continuation: .hostNative` may stay.
- **REQ-304**: `encodeFirstCall` in `HookMapper.swift`: `bound == nil` uses `PackDoorVerdict` then `encodeAllow` / `encodeDeny`. `bound != nil` uses `HostAskVerdict` then allow / deny / ask. The existing “deny result must never become silent allow” guard stays on the bound `.allow` arm.
- **CON-301**: Do not add `Decision.ask`. Do not change `HostAskCapability`, Claude leftover-ask-as-permit, or `ApprovalBridge`.
- **CON-302**: Do not rename `HostAskVerdict`.

## Shared

- **CON-001**: Swift 6.3.3, language mode 6, value types only in Domain/Engine/Packs/Presentation.
- **CON-002**: Exclusive writes per ticket. T2 may edit `ServiceRuntime.swift` only after T1 is on its branch (depends-on T1). T3 must not edit IPC or ServiceRuntime.
- **CON-003**: No `try!` / IUO on production paths. No live-HOME tests. No `RV_BYPASS`. No command text in `os_log`.
- **CON-004**: `tools/gate.sh` with warm `.build`. Do not wipe `.build`.
- **PAT-001**: Closed enums + exhaustive switches. Codable at the wire door. Same pattern as `EvaluationOutcome` / `EvaluationResult`.
- **GUD-001**: TDD: failing decode / projection tests first, then types, then callers.
- **PAT-002**: Specialist: `swift-type-system-architecture` (types only as specified), `swift-testing-pro`, `.grok/skills/swift-hook-xpc` if T3/T1 touch hook encoding.

# 4. Interfaces & Data Contracts

```swift
// RVIPC
public enum HandshakeStatus: Sendable, Equatable {
    case ok
    case skew(SkewReason)
}

public struct HelloAck: Sendable, Equatable, Codable {
    public var protocolName: String
    public var serviceSemver: String
    public var status: HandshakeStatus
}

// Golden encode (unchanged bytes)
// {"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}
// {"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0","skewReason":"core packs unavailable"}

// RVDomain — projection (names flexible if tests/docs match)
extension EvaluationOutcome {
    public var explainRuleID: RuleID? { get }
    public var explainPackID: PackID? { get }
}

extension ClassifyRisk {
    public static func derive(_ outcome: EvaluationOutcome) -> ClassifyRisk
}

// RVDomain — Ask doors
public enum PackDoorVerdict: Sendable, Equatable {
    case allow
    case deny
}

public enum HostNativeAsk {
    public static func verdict(_ decision: Decision) -> PackDoorVerdict
    public static func verdict(
        host: HookHost,
        bound: BoundReview,
        continuation: ApprovalContinuation = .hostNative
    ) -> HostAskVerdict
}
```

# 5. Acceptance Criteria

- **AC-101**: `HelloAck` golden frames in `SkewReasonTests` remain byte-identical for healthy ok and for `ok:false` + `core packs unavailable`.
- **AC-102**: Decode of `{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}` throws. Decode of `ok:true` plus a `skewReason` key throws.
- **AC-103**: `rg -n 'HelloAck(ok:' Sources Tests` matches nothing. `rg -n 'var ok: Bool' Sources/RVIPC/IPCEnvelope.swift Sources/RVCLI/Service/XPCClient.swift` matches nothing on HelloAck/HelloAckView.
- **AC-104**: `ServiceRuntime` contains no `ack.skewReason ??`. `ServiceClient.skewReason` contains no `nil:` arm on `skewReason`.
- **AC-105**: Existing fallback/skew CLI tests keep observable diagnostics (`protocol mismatch`, `major version mismatch`, `core packs unavailable`, `handshake rejected`).
- **AC-201**: `ExplainReply` / `ClassifyReply` production inits do not accept independent `ruleID` that can disagree with `result.outcome`.
- **AC-202**: Deny projection: `EvaluationOutcome.deny(Deny(ruleID: leftover), matched: nil).explainRuleID == leftover`. ServiceRuntime explain for that outcome encodes that rule id.
- **AC-203**: `ClassifyRisk.derive` has no `Decision` × `RuleMatch?` production entry. Unmatched deny is `.rated(.high)` via the `.none` arm, not `??`.
- **AC-204**: `explainViewModel` deny `ruleID` equals `deny.ruleID` (already true) and ServiceRuntime explain matches it.
- **AC-301**: `HostNativeAsk.verdict(_ decision:)` return type is `PackDoorVerdict`. `rg -n 'verdict(host:.*decision:' Sources Tests` matches nothing.
- **AC-302**: Pi/OpenCode `mandatoryHuman` still `HostAskVerdict.ask(.hostNative)`. Claude/Grok/OpenClaw/Hermes still `.deny`. Pack `Decision.deny` still cannot pause.
- **AC-303**: `encodeFirstCall` compiles only by switching the matching verdict type per bound presence.
- **AC-401** (all): No new `as!` / `try!` / `TODO`/`FIXME`. Gate per ticket green.

# 5b. Tickets (task graph)

## T1

| Field | Value |
|---|---|
| `id` | T1 |
| `title` | HelloAck HandshakeStatus enum |
| `depends-on` | none |
| `exclusive-writes` | `spec/spec-architecture-type-system-handshake-ask.md` (no content edits unless a REQ is wrong), `Sources/RVIPC/IPCEnvelope.swift`, `Sources/RVIPC/SkewReason.swift` (only if HandshakeStatus is placed here), `Tests/RVIPCTests/SkewReasonTests.swift`, `Tests/RVIPCTests/EnvelopeRoundTripTests.swift` (HelloAck fixtures only), `Sources/RVCLI/Service/XPCClient.swift` (`HelloAckView` only), `Sources/RVCLI/Service/ServiceClient.swift` (`skewReason` / Route handshake only), `Sources/RVService/ServiceRuntime.swift` (`acknowledge`, `handleIncoming`, `handleUnreadyIncoming` only — do not rewrite `explain`/`classify`), `Tests/RVCLITests/FallbackSkewTests.swift`, `Tests/RVCLITests/ServiceDiagnosticRoutingTests.swift`, `Tests/RVCLITests/HookCommandTests.swift`, `Tests/RVCLITests/OneShotEvaluateTests.swift`, `Tests/RVCLITests/FallbackDownTests.swift`, `Tests/RVCLITests/AllowOnceGrantHonorTests.swift`, `Tests/RVCLITests/LazyFallbackTests.swift`, `Tests/RVCLITests/ServiceStatusTests.swift`, `Tests/RVServiceTests/OneShotEvaluateTests.swift`, `Tests/RVServiceTests/LinuxUnixSocketTests.swift`, `Tests/RVServiceTests/FakeXPCUnixSocketTests.swift` (HelloAck JSON assertions only) |
| `acceptance` | AC-101…105, AC-401 |
| `review-hint` | `101–1499` (`IPCEnvelope.swift` / `ServiceRuntime.swift`) → `swift-pr-review` |
| `gate` | `tools/gate.sh RVIPCTests` then `RVCLITests` `RVServiceTests` |
| `skill` | `swift-type-system-architecture`, `swift-testing-pro` |

## T2

| Field | Value |
|---|---|
| `id` | T2 |
| `title` | EvaluationOutcome projections for explain and classify |
| `depends-on` | T1 |
| `exclusive-writes` | `Sources/RVDomain/EvaluationResult.swift`, `Sources/RVDomain/ExplainStep.swift` (only if projection lives there), `Tests/RVDomainTests/**` (projection tests; add a file if needed), `Sources/RVIPC/IPCMethods.swift` (`ExplainReply`, `ClassifyReply`, `ClassifyRisk.derive` only), `Tests/RVIPCTests/EnvelopeRoundTripTests.swift` (explain/classify fixtures), `Sources/RVService/ServiceRuntime.swift` (`explain` / `classify` only), `Tests/RVServiceTests/ExplainDispatchTests.swift`, `Sources/RVPresentation/ExplainViewModel.swift`, `Tests/RVPresentationTests/DenyViewModelTests.swift` (explainViewModel cases), `Tests/RVPresentationTests/RobotPayloadTests.swift`, `Sources/RVScan/Classify/ScanClassify.swift`, `Tests/RVScanTests/ClassifyTests.swift` |
| `acceptance` | AC-201…204, AC-401 |
| `review-hint` | `101–1499` (`IPCMethods.swift` / `ServiceRuntime.swift`) → `swift-pr-review` |
| `gate` | `tools/gate.sh RVDomainTests` `RVIPCTests` `RVServiceTests` `RVPresentationTests` `RVScanTests` |
| `skill` | `swift-type-system-architecture`, `swift-testing-pro` |

## T3

| Field | Value |
|---|---|
| `id` | T3 |
| `title` | PackDoorVerdict vs HostAskVerdict |
| `depends-on` | none |
| `exclusive-writes` | `Sources/RVDomain/HostNativeAsk.swift`, `Tests/RVDomainTests/HostNativeAskTests.swift`, `Sources/RVHooks/HookMapper.swift`, `Tests/RVHooksTests/HookMapperTests.swift`, `Tests/RVHooksTests/PiHookTests.swift` (only if they call `verdict(host:decision:)`), `Tests/RVHooksTests/**` that construct the pack-door overload |
| `acceptance` | AC-301…303, AC-401 |
| `review-hint` | `≤100` or `101–1499` (`HostNativeAsk.swift` / `HookMapper.swift`) → size-route after implement |
| `gate` | `tools/gate.sh RVDomainTests` `RVHooksTests` |
| `skill` | `swift-type-system-architecture`, `swift-testing-pro`, `.grok/skills/swift-hook-xpc` |

Parallel-safe: **T1 ∥ T3**. T2 starts only on T1’s commit. T3 must not edit `ServiceRuntime.swift`. T1 must not rewrite `explain`/`classify`. T2 must not edit HelloAck types.

# 6. Test Automation Strategy

- Framework: Swift Testing (`@Test`, `#expect`). Fixtures stay in `Tests/`.
- T1: rewrite `SkewReasonTests.missingReasonDecodesAsNil` to expect throw; add `ok:true` plus `skewReason` throw; keep golden byte tests.
- T2: Domain tests for deny-without-match `explainRuleID`; IPC round-trip still decodes old flattened frames; classify risk table.
- T3: `packDecisionDenyStaysDeny` uses `PackDoorVerdict.deny`; spend-first tests unchanged on the bound overload.
- Gate: `tools/gate.sh` / `tools/swift-6.3.3`. Do not clean `.build`.

# 7. Rationale & Context

`EvaluationOutcome` and `SkewReason` already closed their spaces. HelloAck kept Bool + optional, and a test (`missingReasonDecodesAsNil`) documents the illegal decode. ServiceRuntime still writes `ack.skewReason ?? .protocolSkew`. That is the same class of hole TH1/`WorkingDirectory` removed.

Explain/classify re-flatten the outcome. XPC deny used `match?.ruleID`; TTY used `deny.ruleID`. Leftover-ask decode produces a `Deny` with no walker match. Those identities must be one function.

`HostNativeAsk.verdict(host:decision:)` ignores `host` and cannot Ask. After OPE-264 that overload is a footgun on the Ask path. A two-case pack door is smaller than phantom states.

Prior pass-7 `IPCRoute` stayed off origin/main. Do not reintroduce it.

# 8. Dependencies & External Integrations

None new. Foundation JSON via `IPCJSON`. No new packages.

# 9. Examples & Edge Cases

```swift
// T1 decode
{"ok":true,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}           // .ok
{"ok":false,...,"skewReason":"core packs unavailable"}              // .skew(.corePacksUnavailable)
{"ok":false,"protocol":"rv.ipc.v1","serviceSemver":"1.0.0"}         // throw
{"ok":true,...,"skewReason":"protocol"}                             // throw

// T2 deny without walker match
EvaluationOutcome.deny(HostNativeAsk.leftoverAskDeny, matched: nil)
// explainRuleID == leftoverAskDeny.ruleID

// T3
HostNativeAsk.verdict(.deny(packDeny))            // PackDoorVerdict.deny
HostNativeAsk.verdict(host: .pi, bound: .mandatoryHuman(askDeny))  // .ask(.hostNative)
```

- Healthy HelloAck JSON must not contain `"skewReason":null`.
- `HelloAckView(..., status: .ok)` replaces `ok: true` in CLI test fakes.
- Classify `.safeOnly` stays `.safe` (not rated from SafeMatch).

# 10. Validation Criteria

- Ticket gate green.
- `rg` acceptance lines hold.
- Golden HelloAck bytes unchanged for the two frames in REQ-103.
- `git diff` stays inside exclusive-writes.

# 11. Related Specifications / Further Reading

- `spec/spec-architecture-type-system-honor-host.md` (WorkingDirectory, HookHost)
- `docs/factory/specs/type-system-hardening.md` (TH1–TH3)
- `docs/architecture/02.md` (Ask is not a Decision case)
- HTML report: `$TMPDIR/swift-type-system-review-rv-20260827-210539.html`
