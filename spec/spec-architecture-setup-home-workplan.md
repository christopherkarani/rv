---
title: Operator HomeDirectory and setup work plan
version: 1.0
date_created: 2026-08-25
last_updated: 2026-08-25
owner: rv
tags: [architecture, functional-swift, setup, types]
---

# Introduction

Execute the two Strong candidates from the 2026-08-25 functional-evolution
report (`$TMPDIR/swift-functional-evolution-rv-20260825-132741.html`):

1. **FE5-T1** — `HomeDirectory` through setup, doctor, and live policy stores.
   Delete the shared `/tmp/rv-allow-once-nohome` fallback.
2. **FE5-T2** — Setup inspect → `SetupWorkPlan` → interpreter. Uninstall already
   collects then deletes; setup still mutates `kinds` while writing.

Worth-exploring handshake enum is out of scope.

Base: `origin/main` (`4491857`). Do not start from `feat/packs-grouped-list`
(open PR #86). Toolchain: swift-tools 6.3 / 6.3.3 (`tools/swift-6.3.3`),
language mode 6, macOS 26 only. Gate: `tools/gate.sh`. Never wipe `.build`.

## 1. Purpose & Scope

**Audience:** fresh-context implementer and reviewer subagents on isolated
worktrees.

**In scope:**

- `SetupEnvironment`, `DoctorEnvironment`, and `OwnedPaths` take
  `HomeDirectory`.
- `SetupEnvironment.live` / `DoctorEnvironment.live` parse HOME through
  `HomeDirectory(validating:)` (or `HomeDirectory.process()` when reading the
  real process environment).
- `AllowOnceStore.live(home:)` requires a `HomeDirectory`. No shared temp
  fallback root.
- `SetupRun.perform` builds a `SetupWorkPlan` from inspection, then interprets
  it. `SetupReport` comes from interpreter results.

**Out of scope:**

- Handshake `HelloAck.ok` enum (candidate 03).
- `FormatFlags` / Packs HOME ×3 / `PacksCommand.swift` (PR #86).
- Hook malformed fail-closed (PR #84).
- Carrying `PolicyOverride` on `EvaluationResult`.
- Rewriting uninstall (already collect-then-delete).
- New SPM modules. No `Package.swift` target or language-mode edits.
- `Clock` protocol. `RV_BYPASS`. Live-HOME tests. Command text in logs.

**Assumptions:**

- TH1 already typed evaluate/policy HOME. This finishes the filesystem edge.
- `HostAdapterInstallation.setupPlan(force:)` stays the per-host law.
- Quiet second run, occupied skip, `--force` backup, hostless closer, and
  robot one-liners stay behavior-identical.
- `rv test` / `explain` with unset HOME remain day-one walk (FE4 nil-home
  law). They do not grow a “HOME is not set” failure.

## 2. Definitions

| Term | Meaning |
|---|---|
| Operator HOME | Validated `HomeDirectory`. Empty string is not representable. |
| Process edge | `rvd/main`, ArgumentParser `run()`, `ServiceRuntime.init` / `ServiceClient.init` defaults. Allowed to call `HomeDirectory.process()`. |
| Work plan | Ordered setup steps plus predicted slots, derived from inspection + `force` with no writes. |
| Interpreter | Executes a work plan via `FileOps` / `launchctl`. Returns `SetupReport` from what actually happened. |
| Shared fallback root | `AllowOnceStore`’s `fallbackRoot` (`…/rv-allow-once-nohome`). Forbidden after T1. |

## 3. Requirements, Constraints & Guidelines

### Shared

- **CON-001**: Value types except existing XPC `class`. No `try!` / `!` on
  production paths. Tests may use `try #require(HomeDirectory(validating:))`.
- **CON-002**: No `PacksCommand.swift`, packs renderers, or hook codecs.
- **CON-003**: Exclusive write paths below are hard. T2 depends on T1.
- **CON-004**: No live-HOME tests. No `RV_BYPASS`. No command text in logs.
- **GUD-001**: Prefer deepening existing types over new protocols.
- **PAT-001**: Specialist: `swift-type-system-architecture` (T1),
  `swiftify-codebase-architecture` (T2), `swift-testing-pro` (both).

### FE5-T1 — HomeDirectory through setup / doctor / live stores

- **REQ-101**: `SetupEnvironment.home`, `DoctorEnvironment.home`, and
  `OwnedPaths.home` are `HomeDirectory`. Path concatenation uses
  `home.rawValue`.
- **REQ-102**: `SetupEnvironment.live` and `DoctorEnvironment.live` must not
  read `environment["HOME"]` except by passing that string through
  `HomeDirectory(validating:)`. Empty or missing → `nil` (existing
  “HOME is not set” command outcomes).
- **REQ-103**: `LoginHome.matchesProcessHome` may keep a `String` parameter
  internally but production callers pass `home.rawValue` from a
  `HomeDirectory`.
- **REQ-104**: `AllowOnceStore.live(home: HomeDirectory)` is the only live
  constructor. It uses `RVPolicyPaths.configDirectory(home:)`. Delete
  parameterless `live()` and `fallbackRoot`.
- **REQ-105**: `AllowOnceCLI.store()` and `AllowlistCLI.store()` require a
  `HomeDirectory`. Missing HOME → exit 1 with an existing-style stderr line
  (`HOME is not set`). Do not write allow-once or allowlist files under
  `FileManager.default.temporaryDirectory` as a silent default.
- **REQ-106**: `CommandInvocation.emit` reads `HomeDirectory.process()` once.
  If present, pass that home to `CommandRun` and
  `AllowOnceStore.live(home:)`. If absent, pass `home: nil` (day-one walk)
  and an **instance-unique** ephemeral allow-once directory (not a shared
  well-known name). Peek/apply still function; there are no real grants.
- **REQ-107**: `ServiceRuntime` uses `AllowOnceStore.live(home:)` when
  `resolvedHome` is non-nil and no store/directory was injected. Nil home
  without an injected store/directory uses an instance-unique ephemeral
  directory, never the deleted shared fallback root.
- **REQ-108**: `InstallAnalytics.live` takes `HomeDirectory` (or keeps
  `String` only as `rawValue` stuffed into the analytics environment copy).
- **REQ-109**: `rg 'rv-allow-once-nohome|rv-allowlist-nohome'` in `Sources/`
  matches nothing.

### FE5-T2 — Setup work plan

- **REQ-201**: A package-visible (or `RVCLI`-internal) `SetupWorkPlan` is
  built from `HostAdapterInstallationSnapshot` + `OwnedPaths` + `force` +
  whether `rvd` is executable. Building the plan performs no writes, no
  `launchctl`, and no analytics.
- **REQ-202**: Plan steps cover: create config directory; write or skip
  launch agent; per-host skip undetected / skip occupied / force-clear-then-write /
  write. Host order remains `layout.hostAdapters`.
- **REQ-203**: `SetupRun.perform` interprets the plan sequentially. A
  force-clear or write failure still throws the current `SetupError` and
  must not run later host writes. Launchctl bootstrap still observes the
  plist just written (sequential interpreter, not a precomputed success
  report).
- **REQ-204**: `SetupReport` is built from interpreter results (`wrote`,
  observed slot kinds), not from predicted-success slots. Analytics
  `captureInstall` still sees post-write slots.
- **REQ-205**: Occupied skip, `--force` backup, hostless closer, quiet
  second run, and robot one-liners stay behavior-identical. Uninstall is
  not rewritten.
- **REQ-206**: `FileOps` stays private to the setup apply module (same
  file or an adjacent file under `Sources/RVCLI/Setup/`).
- **REQ-207**: Predicted slots (plan) are unit-testable without creating a
  temp HOME. Existing `SetupTests` FileOps cases remain the write contract.

## 4. Interfaces & Data Contracts

### T1

```swift
struct SetupEnvironment {
    var home: HomeDirectory
    // pathEntries, rvPath, rvdPath, fileManager, launchctl, touchLaunchd,
    // installAnalytics, uid unchanged
}

struct DoctorEnvironment {
    var home: HomeDirectory
    // …
}

struct OwnedPaths {
    var home: HomeDirectory
    var configDirectory: String { home.rawValue + "/.config/rv" }
    // other paths likewise
}

extension AllowOnceStore {
    nonisolated public static func live(home: HomeDirectory) -> AllowOnceStore {
        AllowOnceStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
    }
}
```

`SetupEnvironment.resolveRv` / `resolveRvd` take `HomeDirectory` or
`home.rawValue`; behavior unchanged.

### T2

```swift
struct SetupWorkPlan: Equatable, Sendable {
    var steps: [SetupWorkStep]
}

enum SetupWorkStep: Equatable, Sendable {
    case createConfigDirectory
    case writeLaunchAgent
    case skipLaunchAgent
    case skipUndetected(SetupHostKind)
    case skipOccupied(SetupHostKind)
    case forceClearThenWrite(SetupHostKind)
    case write(SetupHostKind, existingData: Data?)
}

enum SetupWorkPlanBuilder {
    static func make(
        installations: HostAdapterInstallationSnapshot,
        layout: OwnedPaths,
        force: Bool,
        rvdIsExecutable: Bool
    ) -> SetupWorkPlan
}
```

Names may vary. `Data` in `.write` is the existing owned-file bytes used by
today’s `.write(existingData:)` plan. Interpreter loads adapter resources and
renders `rvPath` at execute time (same as today).

## 5. Acceptance Criteria

- **AC-101**: Given `HomeDirectory(validating: "")`, when construction is
  attempted, then the result is `nil`. `OwnedPaths` cannot be created from
  an empty string.
- **AC-102**: Given unset HOME, when `rv allow-once` / `rv allowlist`
  run, then exit 1 and stderr mentions HOME is not set. No
  `rv-allow-once-nohome` / `rv-allowlist-nohome` directory is created.
- **AC-103**: Given unset HOME, when `CommandInvocation` runs `rv test`,
  then evaluation still proceeds (day-one walk). Store directory is not the
  deleted shared fallback name.
- **AC-104**: `rg 'environment\["HOME"\]' Sources/RVCLI/Setup Sources/RVCLI/Doctor`
  matches only through `HomeDirectory(validating:)` (or comments).
- **AC-201**: Given occupied grok and detected pi without `--force`, when
  `SetupWorkPlanBuilder.make` runs, then the plan contains skipOccupied(grok)
  and a write step for pi, and performs no filesystem writes.
- **AC-202**: Given occupied grok without `--force`, when `SetupRun.setup`
  runs against a temp HOME, then grok bytes are unchanged and the report
  slot is occupied (existing test).
- **AC-203**: Given `rvd` not executable, when the plan is built, then the
  launch-agent step is skip, not write.
- **AC-204**: Existing setup/uninstall closer, force-backup, and launchctl
  tests still pass.

## 5b. Tickets (task graph)

### FE5-T1 — HomeDirectory through setup / doctor / live stores

| Field | Value |
|---|---|
| id | FE5-T1 |
| title | HomeDirectory through setup, doctor, and live policy stores |
| depends-on | none |
| exclusive-writes | `Sources/RVCLI/Setup/SetupRun.swift` (SetupEnvironment type only; do not restack `perform`), `Sources/RVCLI/Setup/SetupFlow.swift`, `Sources/RVCLI/Setup/OwnedPaths.swift`, `Sources/RVCLI/Setup/LaunchctlApplying.swift`, `Sources/RVCLI/Setup/InstallAnalytics.swift`, `Sources/RVCLI/Doctor/DoctorRun.swift`, `Sources/RVCLI/CommandInvocation.swift`, `Sources/RVCLI/AllowOnceCommand.swift`, `Sources/RVCLI/AllowlistCommand.swift`, `Sources/RVCLI/Service/ServiceClient.swift`, `Sources/RVPolicy/AllowOnceStore.swift`, `Sources/RVService/ServiceRuntime.swift`, `Tests/RVCLITests/SetupTests.swift` (`env` / `OwnedPaths` constructors only), `Tests/RVCLITests/DoctorTests.swift`, `Tests/RVCLITests/HostAdapterInstallationTests.swift`, `Tests/RVCLITests/HostAdapterSetupPlanTests.swift`, `Tests/RVPolicyTests/AllowOnceStoreTests.swift`, `Tests/RVCLITests/AllowOnceTTYTests.swift` (only if they call `live()`), `Tests/RVServiceTests/` files that call `AllowOnceStore.live()` |
| acceptance | REQ-101–109; AC-101–104 |
| review-hint | `101–1499` (`SetupRun.swift` / `AllowOnceStore.swift`) |
| specialist | `swift-type-system-architecture`, `swift-testing-pro` |
| gate | `tools/gate.sh --quiet RVCLITests RVPolicyTests RVServiceTests` |

T1 may change `SetupEnvironment.home` in `SetupRun.swift` but must not
rewrite `perform` / `uninstallPerform`.

### FE5-T2 — Setup work plan interpreter

| Field | Value |
|---|---|
| id | FE5-T2 |
| title | Setup inspect → work plan → interpreter |
| depends-on | FE5-T1 |
| exclusive-writes | `Sources/RVCLI/Setup/SetupRun.swift`, `Sources/RVCLI/Setup/SetupWorkPlan.swift` (create), `Tests/RVCLITests/SetupTests.swift`, `Tests/RVCLITests/HostAdapterSetupPlanTests.swift` |
| acceptance | REQ-201–207; AC-201–204 |
| review-hint | `101–1499` (`SetupRun.swift`) |
| specialist | `swiftify-codebase-architecture`, `swift-testing-pro` |
| gate | `tools/gate.sh --quiet RVCLITests` |

## 6. Test Automation Strategy

- **Test levels**: Swift Testing. Plan builder tests need no temp HOME.
  Interpreter / FileOps tests keep `withTempHome`.
- **Frameworks**: Swift Testing (`import Testing`). No XCTest.
- **Test data**: `HomeDirectory(validating: url.path)` via `try #require`.
  No live `$HOME`.
- **CI**: `tools/gate.sh`. Do not `swift package clean`.
- **Coverage**: no numeric floor. T1 must pin deletion of the shared
  fallback name. T2 must pin plan contents for occupied + force + missing
  rvd.

## 7. Rationale & Context

Engine and PolicyGate.decide are already pure. The leftover operator surface
still has two HOME types (`String` vs `HomeDirectory`) and setup still
interprets per-host plans inside the write loop. Uninstall already shows the
target shape. Completing TH1 and extracting the work plan removes the last
plan-while-mutate loop without an effect algebra.

## 8. Dependencies & External Integrations

- **PLT-001**: Swift 6.3.3, macOS 26, Apple Silicon, language mode 6.
- **INF-001**: `tools/swift-6.3.3`, warm `.build`.
- **EXT-001**: `/bin/launchctl` via existing `LaunchctlApplying` (interpreter
  only).

No new third-party services.

## 9. Examples & Edge Cases

```swift
// T1 — empty home unrepresentable
#expect(HomeDirectory(validating: "") == nil)

// T1 — one process HOME read at CommandInvocation
let home = HomeDirectory.process()
let store = home.map { AllowOnceStore.live(home: $0) }
    ?? AllowOnceStore(baseDirectory: uniqueEphemeral())

// T2 — occupied without force does not write
let plan = SetupWorkPlanBuilder.make(
    installations: snapshot, // grok occupied, pi absentFile
    layout: layout,
    force: false,
    rvdIsExecutable: true
)
// contains skipOccupied(.grok) and write(.pi, …)
```

Mid-host `--force` clear failure: interpreter throws
`SetupError.hostHookClearFailed` and must not write later hosts (same as
today).

## 10. Validation Criteria

- `tools/gate.sh --quiet RVCLITests RVPolicyTests RVServiceTests` exits 0
  after T1.
- `tools/gate.sh --quiet RVCLITests` exits 0 after T2.
- `rg 'rv-allow-once-nohome|fallbackRoot' Sources` is empty after T1.
- `SetupRun.perform` after T2 does not assign `kinds[host] = .wired` inside
  the inspect switch; kinds come from interpreter results.

## 11. Related Specifications / Further Reading

- `spec/spec-architecture-evaluate-setup-doors.md` (SetupApply named, not
  fully extracted)
- `spec/spec-architecture-pack-coverage-policy-gate.md` (PC-T1/T2 landed)
- `docs/factory/PLAN.md` (setup mutations, occupied skip, hostless)
- HTML report: `$TMPDIR/swift-functional-evolution-rv-20260825-132741.html`
