---
title: Type-System Hardening — HOME newtype, ClassifyRisk derivation, DoctorCheckID
version: 1.0
date_created: 2026-08-22
owner: rv factory
tags: [architecture, type-system, refactor]
---

# Introduction

Three compiler-checked hardening refactors selected by the swift-type-system-architecture review
(report: `$TMPDIR/swift-type-system-review-rv-20260822-172115.html`). Each removes one class of runtime
ambiguity that the type system can prove away. No behavior change is intended anywhere; wire formats and
on-disk formats are frozen.

## 1. Purpose & Scope

Replace weakly typed coordination points found in exploration:

1. Operator HOME travels as raw `String` with an empty-string "absent" sentinel re-defended at every layer.
2. `Severity` → `ClassifyRisk` bridged by rawValue strings with silent `?? .medium` / `?? .high` fallbacks.
3. Doctor check ids coordinated by magic string literals between producer and consumer.

Audience: implementer/reviewer subagents. Assumption: base commit `2f380ec` (origin/main).

## 2. Definitions

- **HOME**: the operator home directory from the process environment; root of `~/.config/rv`.
- **Sentinel**: `String("")` meaning "no usable HOME"; every consumer must re-check it today.
- **Total mapping**: a function whose exhaustiveness the compiler enforces (no `default`, no `??` fallback).

## 3. Requirements, Constraints & Guidelines

- **REQ-001**: After TH1 exactly one production site reads `ProcessInfo.processInfo.environment["HOME"]`: `HomeDirectory.process()`.
- **REQ-002**: `HomeDirectory(validating:)` returns nil for `""`; no other API may construct an empty home.
- **REQ-003**: Absence of HOME is expressed as `HomeDirectory?`/`nil`, never as an empty string.
- **REQ-004**: Behavior is preserved: unset HOME ⇒ day-one packs fallback; mutation paths still throw `configUnwritable`; allow-once store unavailable path unchanged.
- **REQ-005**: TH2 must remove both `ClassifyRisk(rawValue:) … ?? .medium/.high` bridges; derivation is one exhaustive switch with no `default`.
- **REQ-006**: TH2 encoded JSON for `ClassifyReply.risk` is unchanged (`"safe"`, `"low"`, `"medium"`, `"high"`, `"critical"`); unknown strings fail decode exactly as today.
- **REQ-007**: TH3 introduces closed `enum DoctorCheckID: String, Codable, Hashable, Sendable` with cases `xpc, protocol, packs, launchd, lastError, grok, pi, opencode`; `DoctorCheck.id` becomes `DoctorCheckID`; wire JSON unchanged (string raw value).
- **CON-001**: Swift 6 language mode; value types only outside XPC edge.
- **CON-002**: Wire protocol `rv.ipc.v1` additive-only; on-disk config/TOML/JSONL formats unchanged.
- **CON-003**: No live-HOME tests; tests inject `HomeDirectory(validating:)` values or nil explicitly.
- **CON-004**: No `try!`/`!` on production paths; typed errors stay typed.
- **GUD-001**: Verify with `tools/gate.sh` (+ explicit filters); never clean `.build`.
- **GUD-002**: Surgical edits — do not improve adjacent code.

## 4. Interfaces & Data Contracts

```swift
// TH1 — Sources/RVPolicy/HomeDirectory.swift
public struct HomeDirectory: Hashable, Sendable, RawRepresentable, Codable {
    public let rawValue: String
    /// Fails on "" (the current sentinel). Non-empty strings pass unchanged.
    public init?(validating rawValue: String)
    /// The single sanctioned environment read. nil when HOME is unset or empty.
    public static func process() -> HomeDirectory?
}

// Call-site shape changes (mechanical):
PacksConfigStore.configURL(home: HomeDirectory) / load(_:home:) / save(_:home:)
RVPolicyPaths.configDirectory(home: HomeDirectory) -> URL
PacksFacade.list/home/info/effectiveIDs/makeCatalog(home:) // HomeDirectory or HomeDirectory? per current semantics
EnabledPacks.resolve(home: HomeDirectory?) -> [PackID]     // nil ⇒ dayOnePackIDs
GatedEvaluate.run(..., home: HomeDirectory?) ; makeRequest(command:home:)
ServiceClient.init(home: HomeDirectory?) ; CommandRun.* (home: HomeDirectory?)
AllowOnceStore.live() uses HomeDirectory.process()
```

```swift
// TH2 — Sources/RVIPC/IPCMethods.swift
public enum ClassifyRisk: Sendable, Equatable {
    case safe
    case rated(Severity)
}
extension ClassifyRisk: Codable { /* encode "safe" | Severity rawValue; decode unknown ⇒ dataCorrupted */ }
extension ClassifyRisk {
    /// Total derivation. Exhaustive over Decision × matched-severity; adding a Severity case must break compile here.
    public static func derive(decision: Decision, matched: RuleMatch?) -> ClassifyRisk
}
```

Derivation law (preserve today's outputs): allow + match ⇒ `.rated(match.severity)`; allow w/o match ⇒ `.safe`;
deny ⇒ `.rated(matched?.severity ?? .high)`; indeterminate ⇒ `.rated(.high)`.

```swift
// TH3 — Sources/RVIPC/IPCMethods.swift
public enum DoctorCheckID: String, Codable, Hashable, Sendable {
    case xpc, `protocol`, packs, launchd, lastError, grok, pi, opencode
}
public struct DoctorCheck { public var id: DoctorCheckID … }   // JSON key/value unchanged
```

Note: host-name cases mirror `RVHooks.HookHost` identity because RVIPC cannot depend on RVHooks;
this duplication is accepted and intentional.

## 5. Acceptance Criteria

- **AC-001**: `rg 'environment\["HOME"\]' Sources` returns exactly one site after TH1 (`HomeDirectory.process()`).
- **AC-002**: `rg 'home\.isEmpty|isEmpty == false' Sources/RVService/PacksFacade.swift` returns nothing after TH1; absence handled via Optional at one boundary.
- **AC-003**: All affected module tests green via `tools/gate.sh` after each ticket (no skipped tests).
- **AC-004**: `rg 'ClassifyRisk\(rawValue' Sources` empty after TH2; existing classify round-trip tests pass unmodified expectations.
- **AC-005**: Existing doctor JSON fixtures/tests keep identical bytes (id strings unchanged) after TH3.
- **AC-006**: No test relies on live process HOME (repo rule) in any touched file.

## 5b. Tickets (task graph)

Serialized chain — exclusive-write overlap forces ordering:
TH1 ∩ TH2 share `Sources/RVService/ServiceRuntime.swift`; TH2 ∩ TH3 share `Sources/RVIPC/IPCMethods.swift`.

### TH1 — Type operator HOME end-to-end

| Field | Value |
|---|---|
| id | TH1 |
| title | `HomeDirectory` newtype + single resolution door |
| depends-on | none |
| exclusive-writes | `Sources/RVPolicy/**`, `Sources/RVService/{PacksFacade,EnabledPacks,EvaluateSession,GatedEvaluate,ServiceRuntime}.swift`, `Sources/RVCLI/{CommandRun,ServiceClient,Commands/PacksCommand}.swift`, matching Tests files, this spec file (first commit adds it) |
| acceptance | AC-001, AC-002, AC-003, AC-006 |
| review-hint | 101–1499 |

Evidence map (12 env reads / sentinels to eliminate):
`Sources/RVService/ServiceRuntime.swift:33,408` · `Sources/RVService/EnabledPacks.swift:11–18` ·
`Sources/RVService/EvaluateSession.swift:30,89–91` · `Sources/RVPolicy/PacksConfig.swift:23–59` ·
`Sources/RVPolicy/AllowOnceStore.swift:19` · `Sources/RVService/PacksFacade.swift:38–119,122,137` ·
`Sources/RVService/GatedEvaluate.swift:27,41–49` · `Sources/RVCLI/CommandRun.swift:35,52,71,90` ·
`Sources/RVCLI/Service/ServiceClient.swift:21–34` · `Sources/RVCLI/Commands/PacksCommand.swift:24,93,129`.

### TH2 — Derive ClassifyRisk totally from Decision + match

| Field | Value |
|---|---|
| id | TH2 |
| title | Kill rawValue bridge + silent risk fallbacks |
| depends-on | TH1 |
| exclusive-writes | `Sources/RVIPC/IPCMethods.swift`, `Sources/RVService/ServiceRuntime.swift` (classify path only), `Tests/RVIPCTests/*`, `Tests/RVServiceTests/*` |
| acceptance | AC-004, AC-003 |
| review-hint | 101–1499 |

### TH3 — Typed doctor check identifiers

| Field | Value |
|---|---|
| id | TH3 |
| title | `DoctorCheckID` closed enum replaces magic strings |
| depends-on | TH2 |
| exclusive-writes | `Sources/RVIPC/IPCMethods.swift`, `Sources/RVService/DoctorSnapshotBuilder.swift`, `Sources/RVCLI/Service/ServiceHealth.swift`, doctor-related Tests files |
| acceptance | AC-005, AC-003 |
| review-hint | 101–1499 |

## 6. Test Automation Strategy

- Frameworks: Swift Testing (`@Test`, `#expect`) — repo standard.
- Levels: unit tests per module; gate runs preflight + filtered suites via `tools/gate.sh [filters…]`.
- Hermeticity: temp directories / injected values only; never process HOME (CON-003).
- Coverage: no threshold gate; behavior-preservation proven by untouched expectations plus targeted new tests (empty-home rejection, risk derivation table, check-id round trip).

## 7. Rationale & Context

Exploration found the codebase already heavily hardened; these three sites are the remaining places where a
closed relationship is enforced at runtime instead of compile time. Full analysis and rejected alternatives
(phantom-typed IPC frames, AllowOnceRecord lifecycle enum, PackIndex `[PackID]`) live in the HTML report.

## 8. Dependencies & External Integrations

None new. Only package-internal dependency: RVIPC imports RVDomain (existing). Toolchain pinned by repo
(`tools/swift-6.3.3`, tools-version 6.3, macOS 26 arm64).

## 9. Examples & Edge Cases

```swift
// Empty sentinel stops being representable:
HomeDirectory(validating: "")            // nil
EnabledPacks.resolve(home: nil)          // dayOnePackIDs (explicit fallback)
PacksFacade.enable(home: nil, tokens: []) // fatal-free: precondition-free design ⇒ mutate takes non-optional
                                          // HomeDirectory; CLI guards nil before calling (same error text).
```

Risk derivation truth table (must hold):

| decision | matched severity | risk |
|---|---|---|
| allow | some s | .rated(s) |
| allow | none | .safe |
| deny | some s | .rated(s) |
| deny | none | .rated(.high) |
| indeterminate | any | .rated(.high) |

## 10. Validation Criteria

Per ticket: `tools/gate.sh <affected filters>` green + AC list checked + `git diff --stat` confined to the
ticket's exclusive-writes.

## 11. Related Specifications / Further Reading

- `docs/factory/specs/phase-5-size-speed.md` (current board context)
- Review report: `$TMPDIR/swift-type-system-review-rv-20260822-172115.html`
