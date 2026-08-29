---
title: Functional core depth — SessionScan, PendingApproval consume, ReviewBind purity
version: 1.0
date_created: 2026-08-29
last_updated: 2026-08-29
owner: rv
tags:
  - architecture
  - design
  - functional-core
  - scan
  - domain
---

# Introduction

This specification implements three Strong candidates from the 2026-08-29 functional-evolution + type-system review (HTML: `/var/folders/ns/xmz0zmpj7p148vdgr4bwzp8h0000gn/T/swift-functional-evolution-rv-20260829-044828.html`).

1. **FE-T3 / FE-T4:** `SessionScan` becomes the deep scan module; CLI stops owning extract/classify/dedupe.
2. **FE-T2:** `PendingApprovalState` absorbs consumption so `consumedAt` is not a parallel optional.
3. **FE-T1:** `ReviewBind` in RVDomain stays a pure `Result` bind; reviewer `await` leaves Domain.

Do not implement OPE-156 (ProposedAction through every HostCodec) or wire `ActionPolicyEngine` onto `GatedEvaluate`. Do not change `AllowOnceRecord`. Do not put setup nudge on `ScanReport`.

# 1. Purpose & Scope

## Purpose

Make three existing seams match the module law already written in `docs/architecture/MODULES.md` and `docs/dev/SWIFT.md`: scan orchestration lives in RVScan; Domain decisions are values; Domain does not await I/O.

## Audience

Implementers of rv (Swift 6.3.3, language mode 6, macOS 26, Apple Silicon) using `tools/gate.sh` and `tools/swift-6.3.3`.

## In scope

- Completing `SessionScan.run` so it performs walk + adapter extract + `ScanClassify` + time window + `ScanDedupe`.
- Returning event host IDs for CLI setup nudge without adding fields to `ScanReport`.
- Thinning `ScanRun` in RVCLI to parse/clock/HOME, call `SessionScan`, compute setup nudge, render.
- Folding pending-approval consumption into `PendingApprovalState`.
- Removing `ReviewBind.apply(hardDecision:request:reviewer:)` from RVDomain.

## Out of scope

- OPE-156 IR / fingerprint construction in every HostCodec.
- Analyzers (`analyzeGit` / `analyzeFilesystem`).
- Putting `ActionPolicyEngine` on the live hook door.
- Closing `hookWire(bound:afterSpend:)` into an enum (Worth exploring; not this spec).
- Typed Codable models for host session JSON (`[String: Any]` stays inside adapters).
- Folding `ActionReview.decision` + `rationaleCategory` (fail-closed conflict must remain representable).
- `AllowOnceRecord.kind` + `consumedAt` on-disk schema.
- Claude/OpenCode settings merge trees.
- ThemeProbe / OutputMode redesign.
- New SPM modules, new dependencies, toolchain bumps.
- Policy gate during scan. `EvaluateSession` / `GatedEvaluate` during scan.
- Live-HOME tests.

## Assumptions

- Hexagonal graph in `MODULES.md` is law. RVScan must not import RVCLI, RVTUI, RVService, RVHooks, RVPolicy.
- Classify calls `RVEngine.evaluate` with `RVPacks` snapshots. Secret catalog remains `SecretPathCatalog.dayOne`.
- Existing session-scan product spec: `spec/spec-architecture-session-scan.md` and factory fence `docs/factory/specs/phase-4-session-scan.md`. This spec does not reopen those product requirements; it relocates ownership.
- `ScanReport` has exactly `findings`, `warnings`, `filesScanned`, `eventsExtracted`.
- `ActionReviewer` protocol may remain in RVDomain as a capability. Foundation Models stay in RVPolicy.
- `class` only at RVService / XPC `NSObject`.

# 2. Definitions

| Term | Meaning |
|---|---|
| **Evaluate session** | Compiled day-one (or walked) packs + `evaluate`. Not used by scan classify. |
| **SessionScan** | RVScan entry that turns `SessionScanRequest` into findings. |
| **ScanRun** | RVCLI wrapper: flags, clock, HOME, setup nudge, pretty/robot. |
| **Setup nudge** | CLI-only hint from `HostAdapterInstallationSnapshot`. Not a ScanReport field. |
| **Known-host-roots mode** | `rootPath == nil`: walk registered adapter roots under `ScanHome`. Not a recursive HOME spider. |
| **Explicit-tree mode** | `rootPath` set: walk that tree for known layouts; `--include-glob` only here. |
| **Pure ReviewBind** | `ReviewBind.apply(hardDecision:review: Result<ActionReview, ActionReviewerError>)`. |
| **Consumed pending** | Terminal state after exactly-once delivery; cannot authorize later. |

# 3. Requirements, Constraints & Guidelines

## SessionScan (FE-T3)

- **REQ-001**: `SessionScan.run` shall implement the pipeline currently in `ScanRun.execute`: select adapters, walk, extract, `ScanClassify`, time-window filter, `ScanDedupe`. It shall not return a successful report with `findings: []` solely because extract/classify were skipped.
- **REQ-002**: When `SessionScanRequest.rootPath` is `nil`, run **known-host-roots mode** (REQ-002 of the session-scan spec): each selected adapter’s `roots(home:)`, then walk those directories. Do not throw `SessionScanError.missingRoot` for nil path. Missing individual roots are skipped (current CLI behavior).
- **REQ-003**: When `rootPath` is set, run **explicit-tree mode**. Missing path fails closed (`SessionScanError.pathNotFound` / equivalent). `--include-glob` / `includeGlobs` apply only in this mode. Empty `includeGlobs` with a path still scans known layouts under that path.
- **REQ-004**: `includeGlobs` non-empty with `rootPath == nil` is a caller error. SessionScan shall throw a typed error (map to today’s `ScanRun.Error.includeGlobRequiresPath`). CLI validation may remain as a second check.
- **REQ-005**: Adapter list lives in RVScan, not RVCLI. Same six adapters as today: Claude, Pi, Grok, OpenCode, OpenClaw, Hermes.
- **REQ-006**: Classify uses `ScanClassify(enabledPacks:)` / snapshots via PackRegistry as today. Never `EvaluateSession`, `GatedEvaluate`, or Policy gate. Packs unavailable → typed error (`ScanClassifyError.packsUnavailable` or SessionScan wrapper).
- **REQ-007**: Clock stays injected: `SessionScanRequest.now`. Do not call `Date()` in RVScan core.
- **REQ-008**: Return type shall carry `ScanReport` plus `eventHosts: Set<ScanHostID>` (hosts that produced extracted events, including allows that never become findings). Do not add setup-nudge fields to `ScanReport`.
- **REQ-009**: FileManager remains an explicit parameter (default `.default` is acceptable at the shell). Tests inject a real temp tree, never live HOME.
- **REQ-010**: Extend `SessionScanRequest` as needed (`includeGlobs`, `timeWindow` or keep `days`/`scanAll`). Preserve `Sendable` / `Equatable`.
- **CON-001**: Do not import RVPolicy, RVHooks, RVCLI, RVTUI, or RVService from RVScan.
- **CON-002**: Do not change robot/pretty schemas or CLI flag names.
- **GUD-001**: Prefer moving code over rewriting extractors. Adapter `extract` bodies stay as they are.
- **PAT-001**: Mirror EvaluateSession: assembly inside the module, one `run` for callers.

## CLI thinness (FE-T4)

- **REQ-011**: `ScanRun.execute` shall call `SessionScan().run` (or a package helper) and map errors. It shall not duplicate walk/extract/classify/dedupe.
- **REQ-012**: Setup nudge stays in RVCLI (`scanSetupNudgeRecommended`) using `eventHosts` from the scan result.
- **REQ-013**: `ScanRun.render` stays in RVCLI (Presentation/TUI). RVScan must not render.
- **REQ-014**: Existing CLI tests that prove auto-mode Claude deny, include-glob rules, path-not-found, and render stay green. Pipeline tests that only prove classify may move to RVScanTests.

## PendingApproval consume (FE-T2)

- **REQ-015**: Add `PendingApprovalState.consumed(ApprovalResolution, at: Date)` (associated-value names may match existing Codable style).
- **REQ-016**: Remove stored `PendingApproval.consumedAt`. A computed `consumedAt: Date?` is allowed for test/source compatibility (`nil` unless state is `.consumed`).
- **REQ-017**: `PendingApprovalLedger.consume` transitions `.resolved` → `.consumed`. Second consume still throws `.alreadyConsumed`. Consume of `.awaitingHuman` still throws `.notResolved`.
- **REQ-018**: `authorizes` is true only for unconsumed authorizing `.resolved` (not `.consumed`). Binding checks unchanged.
- **REQ-019**: `ensureAwaitingHuman` treats `.consumed` as `.alreadyConsumed` (same as today’s `consumedAt != nil`).
- **REQ-020**: Codable: encode the new case. Decode must accept previously written JSON that had `state.kind == resolved` plus a non-nil `consumedAt` on the parent `PendingApproval` and treat it as `.consumed`. Do not bump a global schema if a compatible decode works. Store actor in RVPolicy needs no behavior change if Domain decode is compatible.
- **CON-003**: Do not change `AllowOnceRecord`.
- **CON-004**: Do not wire PendingApproval onto the hook door (OPE-246 remaining work).

## ReviewBind purity (FE-T1)

- **REQ-021**: Delete `ReviewBind.apply(hardDecision:request:reviewer:)` from RVDomain.
- **REQ-022**: Keep `ReviewBind.apply(hardDecision:review:)`.
- **REQ-023**: Domain tests that need a reviewer call `try await reviewer.review` then the pure apply, or construct `Result` directly. Do not add a new Domain helper that awaits.
- **REQ-024**: `ShadowReviewRunner` already awaits in RVPolicy; do not start calling a Domain async apply. Optional: if duplicated catch mapping exists, leave it (out of FE-T1 exclusive writes) unless a one-line comment is required.
- **CON-005**: Do not move `ActionReviewer` protocol out of Domain in this spec.
- **CON-006**: Do not change `ReviewBind.apply` match semantics (hardDeny vs reviewer allow, confidence, conflicting rationale).

## Shared constraints

- **CON-007**: Swift 6.3.3, language mode 6, `tools/gate.sh` for touched test targets. Do not wipe `.build`.
- **CON-008**: No `try!` / IUO on production paths. No `isDenied`. Value types in Domain/Engine/Packs/Presentation.
- **CON-009**: Fixtures stay under `Tests/`. No live-HOME tests.
- **GUD-002**: Small diffs. Do not restyle unrelated files.

# 4. Interfaces & Data Contracts

## SessionScan result

```swift
public struct SessionScanResult: Sendable, Equatable {
    public var report: ScanReport
    public var eventHosts: Set<ScanHostID>
}
```

`SessionScan.run` returns `SessionScanResult` (throwing). CLI maps `report` + `eventHosts` onto today’s `ScanRunResult`.

## SessionScanRequest additions

| Field | Role |
|---|---|
| `rootPath: String?` | nil = known-host-roots; non-nil = explicit tree |
| `includeGlobs: [String]` | extra globs; illegal when `rootPath == nil` |
| `home`, `now`, `hostFilter`, `days`/`scanAll` or `timeWindow`, `packIDs`, `allEvents`, `bounds` | as today |

## PendingApprovalState

```text
awaitingHuman
resolved(ApprovalResolution)           // unconsumed
consumed(ApprovalResolution, at: Date) // terminal
expired(at: Date)
canceled(at: Date)
timedOut(ApprovalTimeoutEnding)
```

## ReviewBind

Only:

```swift
public static func apply(
    hardDecision: HardPolicyDecision,
    review: Result<ActionReview, ActionReviewerError>
) -> BoundReview
```

# 5. Acceptance Criteria

- **AC-001**: Given a temp HOME with the Claude reset-hard fixture, when `SessionScan.run` is invoked with `rootPath == nil` and injected `now`, then the report contains one `core.git:reset-hard` finding (same as `ScanRun` auto mode today).
- **AC-002**: Given `rootPath == nil`, when `SessionScan.run` is called, then it does not throw `missingRoot`.
- **AC-003**: Given `includeGlobs` non-empty and `rootPath == nil`, when `SessionScan.run` is called, then it throws a typed include-glob error.
- **AC-004**: `ScanReport` Mirror labels remain exactly findings, warnings, filesScanned, eventsExtracted.
- **AC-005**: `tools/gate.sh RVScanTests` is green after FE-T3.
- **AC-006**: After FE-T4, `tools/gate.sh RVCLITests` is green; `ScanRun.execute` does not contain DirectoryWalker / adapter extract / ScanClassify / ScanDedupe loops.
- **AC-007**: After consume, `PendingApproval.state` is `.consumed`; `authorizes` is false; second consume throws `.alreadyConsumed`.
- **AC-008**: A constructed `.awaitingHuman` cannot also be consumed without a transition (no stored `consumedAt` independent of state).
- **AC-009**: `tools/gate.sh RVDomainTests` is green after FE-T1 and after FE-T2.
- **AC-010**: `ReviewBind.apply(hardDecision:request:reviewer:)` does not exist. `nm`/grep of `Sources/RVDomain` shows a single `apply` on ReviewBind.
- **AC-011**: ActionReviewerTests still prove bindEligible allow/deny/abstain/conflict/low-confidence using the pure `Result` API.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint | specialist |
|---|---|---|---|---|---|---|
| FE-T1 | Remove effectful ReviewBind.apply from RVDomain | none | `Sources/RVDomain/HardPolicyDecision.swift`, `Tests/RVDomainTests/ActionReviewerTests.swift` | AC-009 (this ticket), AC-010, AC-011 | ≤100 | swift-functional-core, swift-testing-pro |
| FE-T2 | Fold PendingApproval consumption into state | none | `Sources/RVDomain/PendingApproval.swift`, `Sources/RVDomain/PendingApprovalLedger.swift`, `Tests/RVDomainTests/PendingApprovalLedgerTests.swift` | AC-007, AC-008, AC-009 (this ticket) | 101–1499 | swift-type-system-architecture, swift-testing-pro |
| FE-T3 | SessionScan owns walk/extract/classify/dedupe | none | `Sources/RVScan/SessionScan.swift`, new files only under `Sources/RVScan/` (adapter registry / result type), `Tests/RVScanTests/SessionScanTests.swift`, new tests only under `Tests/RVScanTests/`, `spec/spec-architecture-functional-core-depth.md` | AC-001, AC-002, AC-003, AC-004, AC-005 | 101–1499 | swiftify-codebase-architecture, swift-testing-pro |
| FE-T4 | Thin ScanRun to SessionScan | FE-T3 | `Sources/RVCLI/Commands/ScanCommand.swift`, `Tests/RVCLITests/ScanCommandTests.swift`, `Tests/RVCLITests/ScanNudgeTests.swift` | AC-006 | 101–1499 | swiftify-codebase-architecture, swift-testing-pro |

Frontier: FE-T1, FE-T2, FE-T3 in parallel. FE-T4 after FE-T3 commit is on its branch (stack on FE-T3).

# 6. Test Automation Strategy

- **Test levels**: Swift Testing unit/integration in the module’s `*Tests` target. RVScanTests prove scan pipeline without ArgumentParser. RVCLITests prove nudge + render + flag mapping. RVDomainTests prove ledger + bind.
- **Frameworks**: Swift Testing only (`import Testing`). No XCTest.
- **Fixtures**: `Tests/RVScanTests/Fixtures` remain the store layouts. Temp directories for HOME. No live `$HOME`.
- **Gate**: `tools/gate.sh <Target>Tests` via `tools/swift-6.3.3`. Warm `.build`. Do not `swift package clean`.
- **Coverage**: Table tests for ledger consume; at least one RVScanTests auto-mode deny matching today’s CLI Claude fixture.

# 7. Rationale & Context

`SessionScan.run` was left as a walk stub after scan T1–T10 put the real pipeline in RVCLI (`ScanRun`). MODULES.md already assigns that pipeline to RVScan. Completing the stub is a deepen, not a new product.

`PendingApprovalState` is a closed lifecycle that still allows `.awaitingHuman` + `consumedAt != nil`. Folding consume is a compiler win before OPE-246 is on the hook door.

`ReviewBind` async in Domain violates functional core / MODULES.md. Production never calls it; tests and a duplicated Policy await do. Deleting the overload is the smallest purity fix.

# 8. Dependencies & External Integrations

### External Systems

None.

### Third-Party Services

None.

### Infrastructure Dependencies

- **INF-001**: Apple Swift 6.3.3 toolchain via `tools/swift-6.3.3`.
- **INF-002**: Bundled `RVPacks` resources for classify.

### Data Dependencies

- **DAT-001**: Host session fixture JSONL under `Tests/RVScanTests/Fixtures`.

### Technology Platform Dependencies

- **PLT-001**: macOS 26, Apple Silicon, language mode 6.

### Compliance Dependencies

- **COM-001**: Scan must not persist command text to RVHistory. Analytics must not receive command text.

# 9. Examples & Edge Cases

```swift
// Known-host-roots (CLI: no path argument)
let result = try SessionScan().run(
    SessionScanRequest(home: scanHome, now: injectedNow),
    fileManager: fm
)
// result.report.findings may be non-empty
// result.eventHosts feeds CLI nudge only

// Illegal glob
// SessionScanRequest(home: home, now: now, includeGlobs: ["*.jsonl"])
// throws include-glob-requires-path

// Pending consume
guard case .consumed(let resolution, let at) = record.state else { return }
#expect(resolution.decision == .allowOnce)
#expect(record.consumedAt == at)
#expect(record.authorizes(fp, identity: id) == false)

// ReviewBind — Domain
let bound = ReviewBind.apply(hardDecision: eligible, review: .success(allowReview))
```

Nil `rootPath` plus a HOME with no adapter directories: empty findings, exit success at CLI (existing behavior).

# 10. Validation Criteria

- Module graph unchanged except intended ownership (no new RVScan imports).
- `tools/gate.sh RVDomainTests` (FE-T1, FE-T2), `RVScanTests` (FE-T3), `RVCLITests` (FE-T4).
- Grep: no `ReviewBind.apply` with `reviewer:` in `Sources/`.
- Grep: `ScanRun.execute` has no `DirectoryWalker` / `ScanClassify` / `ScanDedupe.apply`.
- `PendingApproval` has no stored `consumedAt` property (computed OK).

# 11. Related Specifications / Further Reading

- [spec/spec-architecture-session-scan.md](spec-architecture-session-scan.md)
- [docs/architecture/MODULES.md](../docs/architecture/MODULES.md)
- [docs/dev/SWIFT.md](../docs/dev/SWIFT.md)
- [docs/factory/specs/phase-4-session-scan.md](../docs/factory/specs/phase-4-session-scan.md)
- [CONTEXT.md](../CONTEXT.md)
- HTML review: `swift-functional-evolution-rv-20260829-044828.html` under TMPDIR
