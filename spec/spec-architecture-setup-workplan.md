---
title: Setup inspect → work plan → interpreter
version: 1.0
date_created: 2026-08-25
last_updated: 2026-08-25
owner: rv
tags: [architecture, functional-swift, setup]
---

# Introduction

Execute the remaining Strong candidate from the 2026-08-25 pass-6 functional-evolution report (`$TMPDIR/swift-functional-evolution-rv-20260825-152119.html`):

**T1 — Setup inspect → `SetupWorkPlan` → interpreter.**

FE5-T1 (`HomeDirectory` through setup/doctor) already landed. Honor-host T2 deleted `SetupHostKind`; every host identity in this ticket is `HookHost`. Do not resurrect `SetupHostKind`.

This ticket is the unimplemented FE5-T2 from `spec/spec-architecture-setup-home-workplan.md`, restated so implementers do not use the deleted host type. Uninstall is already collect-then-delete; do not rewrite it.

Base SHA: `17b8547` (`arch/eb3d3b2d/honor-host`). Toolchain: swift-tools 6.3 / 6.3.3 (`tools/swift-6.3.3`), language mode 6, macOS 26 only. Gate: `tools/gate.sh`. Never wipe `.build`.

Audience: fresh-context implementer and reviewer subagents on the isolated worktree.

# 1. Purpose & Scope

**Audience:** implementer/reviewer subagents.

**In scope:**

- Build a `SetupWorkPlan` from `HostAdapterInstallationSnapshot` + `OwnedPaths` + `force` + whether `rvd` is executable. Building the plan performs no writes, no `launchctl`, and no analytics.
- `SetupRun.perform` interprets the plan sequentially. `SetupReport` comes from interpreter results (`wrote`, observed slot kinds), not from predicted-success slots.
- Tests that assert plan contents without a temp HOME.

**Out of scope:**

- Uninstall (`uninstallPerform` stays collect-then-delete).
- Handshake `HelloAck.ok` enum.
- Doctor `rv-cli` reclassify (`DoctorRun.doctorHostState`).
- `PacksCommand.swift`, host codecs, PolicyGate, `GatedEvaluate`.
- Ceremony clock / `Thread.sleep` inside the plan.
- New SPM modules. `Package.swift` language-mode edits.
- `Clock` protocol. `RV_BYPASS`. Live-HOME tests.

**Assumptions:**

- `HostAdapterInstallation.setupPlan(force:)` stays the per-host law.
- Quiet second run, occupied skip, `--force` backup, hostless closer, and robot one-liners stay behavior-identical.
- `SetupEnvironment.home` is already `HomeDirectory`.

# 2. Definitions

| Term | Meaning |
|---|---|
| Work plan | Ordered setup steps plus enough data to execute them, derived from inspection + `force` with no writes. |
| Interpreter | Executes a work plan via `FileOps` / `launchctl`. Returns `SetupReport` from what actually happened. |
| Predicted slot | What the plan would do; not the report. Occupied skip is known before writes. |
| Observed slot | `SetupSlotKind` after interpretation: `.pending` (undetected / never visited), `.occupied` (skipped), `.wired` (write path ran). |

# 3. Requirements, Constraints & Guidelines

- **CON-001**: Value types except existing XPC `class`. No `try!` / `!` on production paths. Tests may use `try #require(HomeDirectory(validating:))`.
- **CON-002**: No `PacksCommand.swift`, packs renderers, hook codecs, PolicyGate, or doctor files.
- **CON-003**: Exclusive write paths below are hard. Do not edit `uninstallPerform`.
- **CON-004**: No live-HOME tests. No `RV_BYPASS`. No command text in logs.
- **GUD-001**: Prefer deepening existing types over new protocols. No effect-algebra / free monad.
- **PAT-001**: Specialists: `swiftify-codebase-architecture`, `swift-testing-pro`.

## T1 — Setup work plan

- **REQ-201**: A package-visible or `RVCLI`-internal `SetupWorkPlan` is built from `HostAdapterInstallationSnapshot` + `OwnedPaths` + `force` + whether `rvd` is executable. Building the plan performs no writes, no `launchctl`, and no analytics.
- **REQ-202**: Plan steps cover: create config directory; write or skip launch agent; per-host skip undetected / skip occupied / force-clear-then-write / write. Host order remains `layout.hostAdapters`. Host associated values are `HookHost`.
- **REQ-203**: `SetupRun.perform` interprets the plan sequentially. A force-clear or write failure still throws the current `SetupError` and must not run later host writes. Launchctl bootstrap still observes the plist just written (sequential interpreter, not a precomputed success report).
- **REQ-204**: `SetupReport` is built from interpreter results (`wrote`, observed slot kinds), not from predicted-success slots. Analytics `captureInstall` still sees post-write slots.
- **REQ-205**: Occupied skip, `--force` backup, hostless closer, quiet second run, and robot one-liners stay behavior-identical.
- **REQ-206**: `FileOps` stays private to the setup apply module (same file or an adjacent file under `Sources/RVCLI/Setup/`).
- **REQ-207**: Predicted slots (plan) are unit-testable without creating a temp HOME. Existing `SetupTests` FileOps cases remain the write contract.
- **REQ-208**: `SetupRun.perform` does not keep `var grokKind` / `piKind` / `openCodeKind` that mutate inside the inspect/`setupPlan` switch. Slot kinds come from interpreter results. `skipUndetected` leaves that host `.pending` (same as today’s `continue`).
- **REQ-209**: When `rvd` is not executable, the plan contains `skipLaunchAgent` (or equivalent), not a write-launch-agent step. Interpreter must not write the plist in that case (same early-return as today’s `writeLaunchAgent`).

# 4. Interfaces & Data Contracts

```swift
struct SetupWorkPlan: Equatable, Sendable {
    var steps: [SetupWorkStep]
}

enum SetupWorkStep: Equatable, Sendable {
    case createConfigDirectory
    case writeLaunchAgent
    case skipLaunchAgent
    case skipUndetected(HookHost)
    case skipOccupied(HookHost)
    case forceClearThenWrite(HookHost)
    case write(HookHost, existingData: Data?)
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

Names may vary. `Data` in `.write` is the existing owned-file bytes used by today’s `.write(existingData:)` plan. Interpreter loads adapter resources and renders `rvPath` at execute time (same as today). `touchLaunchd` remains an interpreter concern after a `writeLaunchAgent` step; it is not a separate plan case.

# 5. Acceptance Criteria

- **AC-201**: Given occupied grok and detected pi without `--force`, when `SetupWorkPlanBuilder.make` runs, then the plan contains `skipOccupied(.grok)` and a write step for pi, and performs no filesystem writes.
- **AC-202**: Given occupied grok without `--force`, when `SetupRun.setup` runs against a temp HOME, then grok bytes are unchanged and the report slot is occupied (existing test).
- **AC-203**: Given `rvd` not executable, when the plan is built, then the launch-agent step is skip, not write.
- **AC-204**: Existing setup/uninstall closer, force-backup, and launchctl tests still pass.
- **AC-205**: `rg 'var grokKind|var piKind|var openCodeKind' Sources/RVCLI` matches nothing after T1.

# 5b. Tickets (task graph)

### T1 — Setup work plan interpreter

| Field | Value |
|---|---|
| id | T1 |
| title | Setup inspect → work plan → interpreter |
| depends-on | none |
| exclusive-writes | `Sources/RVCLI/Setup/SetupRun.swift`, `Sources/RVCLI/Setup/SetupWorkPlan.swift` (create), `Tests/RVCLITests/SetupTests.swift`, `Tests/RVCLITests/HostAdapterSetupPlanTests.swift`, `spec/spec-architecture-setup-workplan.md` |
| acceptance | REQ-201–209; AC-201–205 |
| review-hint | `101–1499` (`SetupRun.swift`) |
| specialist | `swiftify-codebase-architecture`, `swift-testing-pro` |
| gate | `tools/gate.sh --quiet RVCLITests` |

Do not rewrite `uninstallPerform`. Do not edit `DoctorRun.swift`.

# 6. Test Automation Strategy

- **Test levels**: Swift Testing. Plan builder tests need no temp HOME. Interpreter / FileOps tests keep `withTempHome`.
- **Frameworks**: Swift Testing (`import Testing`). No XCTest.
- **Test data**: `HomeDirectory(validating: url.path)` via `try #require`. No live `$HOME`.
- **CI**: `tools/gate.sh`. Do not `swift package clean`.
- **Coverage**: no numeric floor. T1 must pin plan contents for occupied + force + missing rvd, and keep existing setup stdout tests.

# 7. Rationale & Context

Engine and PolicyGate.decide are already pure. FE5-T1 typed operator HOME. Setup still interprets per-host plans inside the write loop via three mutable slot vars. Uninstall already shows collect-then-apply. Extracting the work plan removes the last plan-while-mutate loop without an effect algebra.

# 8. Dependencies & External Integrations

- **PLT-001**: Swift 6.3.3, macOS 26, Apple Silicon, language mode 6.
- **INF-001**: `tools/swift-6.3.3`, warm `.build`.
- **EXT-001**: `/bin/launchctl` via existing `LaunchctlApplying` (interpreter only).

No new third-party services.

# 9. Examples & Edge Cases

```swift
let plan = SetupWorkPlanBuilder.make(
    installations: snapshot, // grok occupied, pi absentFile
    layout: layout,
    force: false,
    rvdIsExecutable: true
)
// contains skipOccupied(.grok) and write(.pi, …)
```

Mid-host `--force` clear failure: interpreter throws `SetupError.hostHookClearFailed` and must not write later hosts (same as today).

`skipUndetected` must not flip the slot to `.wired`. Hostless setup still prints the setup line with pending slots.

Quiet second run: write step with `existingData == rendered payload` returns `wroteHook == false` (today’s `writeOwned`).

# 10. Validation Criteria

- `tools/gate.sh --quiet RVCLITests` exits 0.
- `rg 'var grokKind|var piKind|var openCodeKind' Sources/RVCLI` is empty.
- `SetupRun.perform` does not assign slot kinds inside the inspect switch; kinds come from interpreter results.

# 11. Related Specifications / Further Reading

- `spec/spec-architecture-setup-home-workplan.md` (FE5-T1 landed; FE5-T2 is this ticket)
- `docs/factory/PLAN.md` (setup mutations, occupied skip, hostless)
- HTML report: `$TMPDIR/swift-functional-evolution-rv-20260825-152119.html`
