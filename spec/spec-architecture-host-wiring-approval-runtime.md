---
title: HostWiring document and ApprovalRuntime
version: 1.0
date_created: 2026-09-15
last_updated: 2026-09-15
owner: rv
tags: [architecture, functional-swift, setup, service, approvals]
---

# Introduction

Execute the two Strong candidates from `$TMPDIR/swift-functional-evolution-rv-20260915-234100.html` (HEAD `d8ad5a8`, branch `worktree/green-forest-7e5b`).

1. **T1** — `HostWiring` owns FileToolDoor derivation from adapter / companion bytes. Top recommendation (inspect half of C01).
2. **T2** — Setup write goes through `HostWiring.apply`; inspect of those bytes yields the same FileToolDoor. C01 apply half. Depends on T1.
3. **T3** — `ApprovalRuntime` owns pending list/watch/resolve and rule preview/save. C02. Parallel with T1.

Do not execute worth-exploring C03 (`PolicySurface` / leftover `GatedEvaluate` overlay I/O). Do not create `EvaluatePolicyWorld`. Do not fold XPC miss into `HookDoor`. Do not reopen the evaluation door, PolicyGate, File tool honor codecs, Hook mapper, EvaluationWorld, SessionScan, HookRequest, LiveEvaluateWorld as a new door, GitPushForceConstraint, FilesystemAnalysisWorld, DenialLedgerRecord, GitAnalysisWorld, setup file-op plan (`SetupWorkPlan` already exists), MachineConfig bag, Host Ask wait door, `PacksConfig` `[String]`, `Decision.ask`, or ProposedAction IR (OPE-156).

Audience: fresh-context implementer and reviewer subagents. Toolchain: Swift 6.3.3 (`tools/swift-6.3.3`), language mode 6, macOS 26 + Linux aarch64/x86_64. Gate: `tools/gate.sh`. Warm `.build`. Never `swift package clean`. After the first compile in a worktree, `git restore Package.resolved` unless this ticket owns dependency changes.

# 1. Purpose & Scope

Make two illegal programs unrepresentable, and hide one leaked assembly:

- Doctor reporting file-tool **wired** from a different predicate than the bytes setup just wrote.
- Three `[String: Any]` walks (`ClaudeSettingsMerge.hasFileToolMatchers`, `CursorHooksMerge.hasFileToolEntry`, `GrokHookInspect.hasFileToolDoor`) living in `HostAdapterInstallation` instead of one document function.
- Pending allow-once plant/consume/rule-pin polarity living in the same actor as handshake, catalog rebuild, and analytics (`ServiceRuntime`, 872 lines).

## In scope

- RVCLI `HostWiring` (new) + `HostAdapterInstallation` + `DoctorRun` consumption.
- RVCLI `SetupRun` write arms for Claude / Cursor / Grok that produce host JSON (T2 only).
- Existing merge helpers: they stay; T1/T2 call them, they do not move to RVHooks.
- RVService `ApprovalRuntime` (new) + `ServiceRuntime` dispatch for pending* / rule*.
- Existing `PendingAllowOncePlanner`, `PendingListProjection`, `PendingApprovalLedger`, `RulePinStore`.

## Out of scope

- `PolicySurface` / moving SafetyStore loads out of `GatedEvaluate` (C03).
- Typed `config.json` / MachineConfig. Analytics hexagon stays a leaf.
- Setup file-op algebra. `SetupWorkPlan` / `FileOps` stay.
- Folding miss into `HookDoor`.
- Changing host deny JSON keys, honor exit codes, leftover-ask-as-permit, or codec decode.
- Changing `SetupSlotKind.wired` meaning (adapter + sibling `rv-cli`). File-tool is a **second** axis (`DoctorFileToolsState`).
- C `rv` hook. Host adapter templates as new files. New SPM modules.

# 2. Definitions

| Term | Meaning |
|---|---|
| HostWiring | Deep module in RVCLI that turns host bytes + companion bytes into a document, and (T2) applies a typed RV slice onto an opaque remainder. |
| HostWiringDocument | Value: installation state already owned by `HostAdapterInstallation`, plus `DoctorFileToolsState` derived from those same bytes. |
| File-tool door | `DoctorFileToolsState`: `wired` / `shellOnly` / `notApplicable`. Not `SetupSlotKind`. |
| Companion JSON | Cursor `hooks.json` bytes. Other hosts have no companion. |
| ApprovalRuntime | Service-owned type that executes pending list/watch/resolve and rule preview/save. Owns watch-generation fingerprint. |
| Planner | `PendingAllowOncePlanner.plan` — pure `EvaluationResult` + cwd → plant / resolveWithoutGrant / refuse. Unchanged. |
| Ledger | `PendingApprovalLedger` — pure state transitions. Unchanged. |

# 3. Requirements, Constraints & Guidelines

## Shared

- **CON-001**: Value types except existing XPC `class`. No `try!` / `!` on production paths.
- **CON-002**: No new SPM target. No `@_exported import`. Hexagon: RVHooks still has no setup mutations. RVService still has no ArgumentParser.
- **CON-003**: No live-HOME tests. No `RV_BYPASS`. No command text in `os_log`.
- **CON-004**: Do not change honor codecs, `HookWire` JSON, or Claude leftover `permissionDecision: "ask"`.
- **CON-005**: Exclusive-writes are a collision fence. If a test file outside the list fails to compile because of this ticket’s API, the ticket **owns** that test file. Do not use that clause to edit PolicyGate, Engine, or the other ticket’s exclusive set.
- **GUD-001**: Prefer deepening existing types over new protocols. No effect algebra.
- **PAT-001**: TDD: failing test → minimal fix → `tools/gate.sh <Target>Tests`.
- **PAT-002**: Specialists: T1/T2 `swiftify-codebase-architecture` + `swift-testing-pro`. T3 `swift-functional-architecture` + `swift-concurrency`.

## T1 — HostWiring inspect document

- **REQ-101**: Add `Sources/RVCLI/Setup/HostWiring.swift` (name fixed). It owns FileToolDoor derivation. Reuse `DoctorFileToolsState`; do **not** invent a second `FileToolDoor` enum.

- **REQ-102**: Package API (labels may match neighbors; cases are the law):

  ```swift
  enum HostWiring {
      static func fileTools(
          host: HookHost,
          adapterBytes: Data?,
          companionJSON: Data?
      ) -> DoctorFileToolsState
  }
  ```

  Law:

  | Host | Result |
  |---|---|
  | Pi, OpenCode, OpenClaw, Hermes, Codex | `.notApplicable` (ignore bytes) |
  | Claude, Grok, Cursor | `.notApplicable` when `adapterBytes` is nil or installation is not `.wired` |
  | Claude | `.wired` iff `ClaudeSettingsMerge.hasFileToolMatchers` on adapter bytes; else `.shellOnly` |
  | Grok | `.wired` iff `GrokHookInspect.hasFileToolDoor`; else `.shellOnly` |
  | Cursor | `.wired` iff companion JSON parses and `CursorHooksMerge.hasFileToolEntry`; missing companion → `.shellOnly` |

- **REQ-103**: `HostAdapterInstallation.fileTools(companionJSON:)` and `HostAdapterInstallationSnapshot.fileTools(for:)` **must** call `HostWiring.fileTools`. They must not call `hasFileToolMatchers` / `hasFileToolEntry` / `hasFileToolDoor` directly. `DoctorRun` keeps calling `installations.fileTools(for:)`.

- **REQ-104**: Existing installation states (missing / absentFile / occupied / broken / wired) and sibling `rv-cli` inspect law stay. T1 does not change `isWiredMissPath`.

- **REQ-105**: Tests in `Tests/RVCLITests/` (extend `HostAdapterInstallationTests.swift` and/or add `HostWiringTests.swift`):

  1. Claude adapter bytes **with** Read/Edit/Write matchers → `.wired`.
  2. Claude adapter bytes that are otherwise wired (sibling `rv-cli`) **without** those matchers → `.shellOnly`.
  3. Cursor companion with file-tool entry → `.wired`; without → `.shellOnly`.
  4. Pi + any bytes → `.notApplicable`.
  5. `HostAdapterInstallation.fileTools` equals `HostWiring.fileTools` on the same bytes (one equality test is enough).

- **CON-101**: Do not edit `SetupRun.swift`, merge **write** paths, `ServiceRuntime.swift`, or RVHooks codecs.
- **CON-102**: Merge files may keep their `hasFileTool*` helpers; T1 routes through them, does not duplicate the matcher lists.

## T2 — HostWiring apply (depends on T1)

- **REQ-201**: Add `HostWiring.apply` (or `merge`) that is the only setup write path for Claude settings.json, Cursor hooks.json file-tool slice, and Grok hook JSON. It returns `(data: Data, fileTools: DoctorFileToolsState)` (plus existing `wrote: Bool` if needed). `fileTools` is `HostWiring.fileTools` on the **returned** data (Cursor: returned companion bytes).

- **REQ-202**: `SetupRun.writeClaudeSettings` and the Cursor / Grok write arms call `HostWiring.apply`. They must not call `ClaudeSettingsMerge.merge` / `CursorHooksMerge.merge` except through `HostWiring`.

- **REQ-203**: After a successful write, `HostWiring.fileTools` on the written bytes must match the `fileTools` returned from apply. Prove with a unit test that does not run full `rv setup`.

- **REQ-204**: Bit-identical: Claude timeout, Cursor `failClosed`, Codex `statusMessage`, foreign keys, and existing merge tests stay green. If a golden byte test exists, it still passes.

- **REQ-205**: `SetupSlotKind.wired` still means adapter present + sibling `rv-cli` (interpreter already assigns `.wired` after write). Do **not** change `.wired` to mean file-tool. File-tool remains the second axis.

- **CON-201**: Do not edit `ServiceRuntime.swift`, `ApprovalRuntime.swift`, or hook codecs.
- **CON-202**: Do not rewrite `SetupWorkPlan` / `FileOps`. Uninstall stays collect-then-delete.

## T3 — ApprovalRuntime (independent of T1/T2)

- **REQ-301**: Add `Sources/RVService/ApprovalRuntime.swift`. It owns:

  - pending list + watch generation fingerprint (`pendingGeneration`, `pendingSetFingerprint`)
  - `pendingResolve` including `resolveAllowOnce` plant / consume / fail-closed consume-after-failed-plant
  - `rulePreview` / `ruleSave` including polarity map and `RulePinStore.save` then pending resolve

- **REQ-302**: `ServiceRuntime.dispatch` for `.pendingList`, `.pendingWatch`, `.pendingResolve`, `.rulePreview`, `.ruleSave` forwards to `ApprovalRuntime`. Those method bodies must not remain in `ServiceRuntime.swift` after T3 (thin one-liner forward is allowed).

- **REQ-303**: Peek for allow-once stays `LiveEvaluateWorld.peek` injected into the runtime (port or stored `LiveEvaluateWorld` factory). Do not fold miss into `HookDoor`. Do not invent a second AllowOnce store.

- **REQ-304**: `PendingAllowOncePlanner` and `PendingListProjection` stay. Do not reimplement planner cases.

- **REQ-305**: Plant-then-consume order and errors stay: failed plant → consume the wait → `.pendingAllowOnceNotUnlockable`. Already-terminal → `.pendingAlreadyTerminal`. Missing coordinator → existing unavailable error.

- **REQ-306**: `HookDoor.recordPending` / `clearPending` stay in `HookDoor.swift`. T3 does not move hook-door plant of awaiting rows.

- **REQ-307**: Tests: `PendingDispatchTests` keep speaking IPC methods. They may construct `ServiceRuntime` (preferred) or `ApprovalRuntime` if dispatch still covers the same replies. Existing plant/refuse/identity-mismatch cases stay green.

- **CON-301**: Do not edit setup / HostWiring / merge files.
- **CON-302**: Do not change IPC method names or Codable keys.
- **CON-303**: `ApprovalRuntime` is owned by `ServiceRuntime` (stored member). Not a free-floating global. Actor vs struct: if it holds `pendingGeneration`, it must be isolated the same way as today (the `ServiceRuntime` actor can own an `ApprovalRuntime` struct mutated only on the actor, or `ApprovalRuntime` can be an actor — pick one; do not add a lock).

# 4. Interfaces & Data Contracts

## HostWiring (T1/T2)

| Operation | I/O | Result |
|---|---|---|
| `fileTools(host:adapterBytes:companionJSON:)` | none | `DoctorFileToolsState` |
| `apply` (T2) | none (pure merge of Data) | bytes + `DoctorFileToolsState` |
| Setup `FileOps.write` | filesystem | existing `SetupError` |

`DoctorRun` does not import merge types.

## ApprovalRuntime (T3)

| IPC method | Runtime operation |
|---|---|
| `pendingList` | list + generation bump |
| `pendingWatch` | wait until generation changes (same as today) |
| `pendingResolve` | planner + plant/consume |
| `rulePreview` | `RulePinning.preview` |
| `ruleSave` | `RulePinStore.save` + pending resolve |

Evaluate / hookEvaluate / explain / classify / packs / doctor stay on `ServiceRuntime`.

# 5. Acceptance Criteria

- **AC-101**: Given Claude settings bytes that include the three file-tool matchers and a wired installation, When `HostWiring.fileTools` runs, Then the result is `.wired`.
- **AC-102**: Given Claude settings bytes that are a wired adapter **without** those matchers, When `HostWiring.fileTools` runs, Then the result is `.shellOnly`.
- **AC-103**: Given Cursor adapter `.wired` and companion JSON without a file-tool entry, When `snapshot.fileTools(for: .cursor)` runs, Then `.shellOnly`. With the entry, `.wired`.
- **AC-104**: `grep -n "hasFileToolMatchers\\|hasFileToolEntry\\|hasFileToolDoor" Sources/RVCLI/Setup/HostAdapterInstallation.swift Sources/RVCLI/Doctor/DoctorRun.swift` is empty after T1.
- **AC-201**: Given `HostWiring.apply` for Claude with current matchers, When the returned data is passed to `HostWiring.fileTools`, Then `fileTools` equals the apply result’s `fileTools` and is `.wired`.
- **AC-202**: Existing Claude / Cursor / Grok merge golden or inspect tests stay green (bit-identical foreign keys).
- **AC-203**: `SetupRun` write arms for Claude / Cursor / Grok do not call `*Merge.merge` except via `HostWiring` (`grep` those names in `SetupRun.swift` is empty or only comments).
- **AC-301**: `grep -n "func pendingListResult\\|func resolveAllowOnce\\|func ruleSaveResult" Sources/RVService/ServiceRuntime.swift` is empty after T3.
- **AC-302**: Given an unlockable pending allow-once, When IPC `pendingResolve` allowOnce runs, Then the grant is planted and the wait consumed — same replies as today’s `PendingDispatchTests`.
- **AC-303**: Given a failed plant, When resolve runs, Then the wait is consumed and the error is `.pendingAllowOnceNotUnlockable`.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | `HostWiring.fileTools` owns the file-tool axis | none | `Sources/RVCLI/Setup/HostWiring.swift` (create), `Sources/RVCLI/Setup/HostAdapterInstallation.swift`, `Tests/RVCLITests/HostAdapterInstallationTests.swift`, `Tests/RVCLITests/HostWiringTests.swift` (create) | AC-101–104; `tools/gate.sh RVCLITests` | 101–1499 |
| T2 | `HostWiring.apply`; Setup writes through it | T1 | `Sources/RVCLI/Setup/HostWiring.swift`, `Sources/RVCLI/Setup/SetupRun.swift`, `Sources/RVCLI/Setup/ClaudeSettingsMerge.swift`, `Sources/RVCLI/Setup/CursorHooksMerge.swift`, `Sources/RVCLI/Setup/GrokHookInspect.swift`, `Tests/RVCLITests/HostWiringTests.swift`, `Tests/RVCLITests/SetupTests.swift` (only cases that must compile or prove AC-201–203) | AC-201–203; `tools/gate.sh RVCLITests` | 101–1499 |
| T3 | `ApprovalRuntime` owns pending + rule IPC | none | `Sources/RVService/ApprovalRuntime.swift` (create), `Sources/RVService/ServiceRuntime.swift`, `Sources/RVService/PendingIPC.swift`, `Sources/RVService/PendingResolveGrant.swift`, `Tests/RVServiceTests/PendingDispatchTests.swift` | AC-301–303; `tools/gate.sh RVServiceTests` | 101–1499 |

Frontier: **T1 ∥ T3**. T2 starts only after T1’s ticket branch is the base (stack on T1).

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit in RVCLITests (T1, T2) and RVServiceTests (T3).
- **Frameworks**: Swift Testing. No XCTest. No live HOME. Temp directories only.
- **CI**: `tools/gate.sh` as in the ticket table. First compile: `git restore Package.resolved` if resolve rewrote it (Darwin must keep Linux swift-crypto pins).
- **Coverage**: AC-101–104, AC-201–203, existing PendingDispatch plant/refuse/mismatch.
- **TDD**: write the failing test first for each ticket.

# 7. Rationale & Context

File-tool honor landed on HEAD (`d8ad5a8`) while install inspect still walks three JSON bags. `SetupWorkPlan` already sequenced file ops; the missing value is the host document those ops write. `PendingApprovalLedger` + `PendingAllowOncePlanner` are already reducers; `ServiceRuntime` still executes their effects next to handshake. Completing those two deepenings is the leftover functional work. Overlay I/O inside `GatedEvaluate` is smaller and is C03 — skip.

# 8. Dependencies & External Integrations

- **PLT-001**: Swift 6.3.3, language mode 6, macOS 26, Linux aarch64/x86_64.
- **INF-001**: `tools/gate.sh` + `tools/swift-6.3.3`. Warm `.build`.
- **COM-001**: Host deny JSON is the block. Do not change keys.
- **DAT-001**: Host settings.json / hooks.json are open documents. Unknown keys must survive merge. Pending JSONL identity strings unchanged.

# 9. Examples & Edge Cases

```swift
// T1
HostWiring.fileTools(host: .pi, adapterBytes: data, companionJSON: nil) // .notApplicable
HostWiring.fileTools(host: .claude, adapterBytes: wiredWithoutMatchers, companionJSON: nil) // .shellOnly
HostWiring.fileTools(host: .cursor, adapterBytes: wiredAdapter, companionJSON: nil) // .shellOnly

// T2
let applied = try HostWiring.applyClaude(existing: nil, rvPath: rv, adapterPath: adapter)
HostWiring.fileTools(host: .claude, adapterBytes: applied.data, companionJSON: nil) == applied.fileTools

// T3
// ServiceRuntime.dispatch(.pendingResolve(allowOnce)) → ApprovalRuntime
// grep func resolveAllowOnce Sources/RVService/ServiceRuntime.swift → empty
```

# 10. Validation Criteria

Each ticket: listed `tools/gate.sh` green. No new `TODO`/`FIXME` in production. No `RV_BYPASS`. `git restore Package.resolved` if the first worktree resolve rewrote it. Hexagon imports unchanged. AC-104 / AC-203 / AC-301 greps hold on that ticket’s exclusive set.

# 11. Related Specifications / Further Reading

- `spec/spec-architecture-setup-workplan.md` (file-op plan already landed)
- `spec/spec-architecture-hook-request-live-world.md` (do not fold miss into HookDoor)
- `CONTEXT.md` Host adapter installation state, File tool, Policy gate
- `docs/architecture/MODULES.md`
- HTML: `swift-functional-evolution-rv-20260915-234100.html`
