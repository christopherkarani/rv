---
title: HostWiring document and ApprovalRuntime
version: 1.0
date_created: 2026-09-15
last_updated: 2026-09-15
owner: rv
tags: [architecture, setup, service, pending, swiftify]
---

# Introduction

Execute the two Strong candidates from `$TMPDIR/swift-architecture-review-rv-20260915-232633.html` (HEAD `d8ad5a8`, branch `worktree/quiet-field-e7d5` / `feat/file-tool-honor-honesty`).

1. **T1** — `HostWiring.fileTools` is the only inspect-time file-tool door. Top recommendation, type half of C01.
2. **T2** — Claude / Cursor / Codex merge writes a typed RV slice plus an opaque foreign remainder. C01 apply half. Depends on T1.
3. **T3** — `ApprovalRuntime` owns pending list/watch/resolve and rule preview/save. C02. Parallel with T1.

Do not execute worth-exploring C03 (MachineConfig / `config.json`) or C04 (ServiceCall). Do not fold XPC miss into `HookDoor` (cli-thin CL2). Do not reopen the evaluation door, PolicyGate, File tool **decode**, Hook mapper, EvaluationWorld, SessionScan, HookRequest, LiveEvaluateWorld, GitPushForceConstraint, FilesystemAnalysisWorld, DenialLedgerRecord, PacksConfig `[String]`, `Decision.ask`, or ProposedAction IR (OPE-156).

Audience: fresh-context implementer and reviewer subagents. Toolchain: Swift 6.3.3 (`tools/swift-6.3.3`), language mode 6, macOS 26 + Linux aarch64/x86_64. Gate: `tools/gate.sh`. Warm `.build`. Never `swift package clean`. After the first compile in a worktree, `git restore Package.resolved` unless this ticket owns dependency changes.

# 1. Purpose & Scope

Make two illegal programs hard, and hide one leaked IPC assembly:

- Doctor / setup reporting file-tool **wired** from a different predicate than the merge that writes the matchers.
- `ServiceRuntime` knowing plant / consume / rule-pin polarity while also owning handshake and evaluate.
- A fifth `config.json` `[String: Any]` reader (out of scope — C03 skipped).

## In scope

- RVCLI setup inspect file-tool classification (`HostAdapterInstallation.fileTools`, `GrokHookInspect`, Claude/Cursor matcher predicates).
- RVCLI merge apply for Claude `settings.json`, Cursor `hooks.json`, Codex `hooks.json` (typed RV slice, opaque remainder).
- RVService pending + rule IPC orchestration extracted behind `ApprovalRuntime`.

## Out of scope

- Typed `~/.config/rv/config.json` (MachineConfig). Analytics hexagon stays a leaf.
- ServiceClient XPC-or-miss runner (ServiceCall).
- Host codec decode / honor JSON / exit codes / leftover-ask-as-permit.
- `SetupWorkPlan` step enum (already landed). Do not resurrect `SetupHostKind`.
- Uninstall rewrite. LaunchAgent / systemd templates.
- New SPM modules. `Package.swift` graph edits.
- Folding miss into `HookDoor`. Changing `PendingAllowOncePlanner` cases.
- Live-HOME tests. `RV_BYPASS`. Command text in `os_log`.

# 2. Definitions

| Term | Meaning |
|---|---|
| HostWiring | RVCLI-internal façade: inspect file-tool door and (T2) apply/strip a typed RV slice on a host settings/hooks document. |
| File-tool door | Install-time classification: `wired`, `shellOnly`, or `notApplicable`. Already `DoctorFileToolsState`. |
| RV slice | Keys rv wrote (fingerprint, matcher set, command, timeout, failClosed, statusMessage). Closed. |
| Foreign remainder | Every other key in the host JSON document. Opaque. Must survive apply/strip. |
| ApprovalRuntime | Service actor (or actor-owned type) that handles `pendingList`, `pendingWatch`, `pendingResolve`, `rulePreview`, `ruleSave`. |
| Plant | Insert a granted allow-once row after CAS-resolve. Fail-closed: failed plant consumes the wait and returns unlockable error (today’s `resolveAllowOnce`). |
| Miss | `EvaluationRoute` chose in-process. Not this spec. |

# 3. Requirements, Constraints & Guidelines

- **CON-001**: Value types except existing XPC `class` / `ServiceRuntime` actor / `ApprovalRuntime` actor. No `try!` / `!` on production paths.
- **CON-002**: No new SPM module. HostWiring stays in `Sources/RVCLI/Setup/`. ApprovalRuntime stays in `Sources/RVService/`.
- **CON-003**: Exclusive write paths below are hard. Do not edit files outside the ticket set.
- **CON-004**: No live-HOME tests. No `RV_BYPASS`. No command text in logs.
- **CON-005**: Do not change host deny JSON keys, honor exit codes, or leftover-ask-as-permit law.
- **CON-006**: Do not import RVCLI from RVService. Do not import RVService from RVHooks.
- **GUD-001**: Prefer deepening existing types over new protocols. One façade, not `FooProtocol` / `FooImpl`.
- **PAT-001**: Specialists: `swiftify-codebase-architecture`, `swift-testing-pro`, `swift-hexagonal-spm` (graph freeze).

## T1 — HostWiring file-tool inspect

- **REQ-101**: Add `Sources/RVCLI/Setup/HostWiring.swift` (name may match neighbors). Package/internal API:

  ```swift
  enum HostWiring {
      static func fileTools(
          host: HookHost,
          adapterData: Data?,
          companionJSON: Data?
      ) -> DoctorFileToolsState
  }
  ```

  Reuse `DoctorFileToolsState` from RVPresentation. Do not invent a second enum.

- **REQ-102**: Law (must match today’s `HostAdapterInstallation.fileTools` + `GrokHookInspect` + Claude/Cursor predicates):

  | Host | Condition | Result |
  |---|---|---|
  | pi, opencode, openclaw, hermes, codex | always | `.notApplicable` |
  | claude, cursor, grok | adapter data is not a wired installation payload | `.notApplicable` when called from `HostAdapterInstallation.fileTools` (still only when `self` is `.wired`) |
  | claude + wired | `ClaudeSettingsMerge.hasFileToolMatchers` true | `.wired` |
  | claude + wired | matchers missing | `.shellOnly` |
  | grok + wired | `GrokHookInspect.hasFileToolDoor` (open PreToolUse, no matcher) | `.wired` else `.shellOnly` |
  | cursor + wired | companion `hooks.json` has fingerprinted `preToolUse` entry | `.wired` else `.shellOnly` |

- **REQ-103**: `HostAdapterInstallation.fileTools(companionJSON:)` and `HostAdapterInstallationSnapshot.fileTools(for:)` **delegate** to `HostWiring.fileTools`. They must not re-parse matcher keys inline.

- **REQ-104**: `GrokHookInspect.hasFileToolDoor` may remain as a thin wrapper or move into `HostWiring`. There must be **one** grok predicate implementation.

- **REQ-105**: `ClaudeSettingsMerge.hasFileToolMatchers` and `CursorHooksMerge.hasFileToolEntry` may remain as the bag readers that `HostWiring` calls in T1. T1 does **not** retype merge writes.

- **REQ-106**: Existing HostAdapterInstallationTests and DoctorTests keep passing with the same wired / shellOnly fixtures. Add one test that `HostWiring.fileTools` and `HostAdapterInstallation.fileTools` agree on the Claude wired + file-matcher fixture and the Cursor shell-only fixture.

- **CON-101**: Do not edit `SetupRun.swift`, merge `merge(` / `insertRVEntry` functions, codecs, or RVService.
- **CON-102**: Do not change `HostAdapterInstallation` cases or `setupPlan` / `uninstallPlan`.

## T2 — Typed RV slice on apply

- **REQ-201**: Claude, Cursor, and Codex merge **writes** go through a typed RV slice. Foreign keys stay in an opaque remainder (`[String: Any]` or `JSONValue` bag is allowed **only** for remainder, not for rv matchers/commands).

  Suggested shapes (names may match style):

  ```swift
  struct ClaudeRVSlice: Equatable, Sendable {
      var bakedRvPath: String
      var adapterPath: String
      var matchers: [String]  // Bash + Read + Edit + Write, existing order
      var timeout: Int        // 90
  }

  struct CursorRVSlice: Equatable, Sendable {
      var adapterPath: String
      var timeout: Int        // 5
      var failClosed: Bool    // true
      var registersPreToolUse: Bool  // true after today’s insert
  }

  struct CodexRVSlice: Equatable, Sendable {
      var adapterPath: String
      var matcher: String     // Bash
      var timeout: Int        // 5
      var statusMessage: String // RV
  }
  ```

- **REQ-202**: `merge(...)` still returns `(data: Data, wrote: Bool)` so `SetupRun` call sites can stay. Internally: parse remainder → strip fingerprinted RV entries → insert slice → encode remainder + slice. Bit-identical JSON is **not** required if key order already uses `.sortedKeys`; byte-identical to today’s merge on the same inputs **is** required for the fixtures in existing merge tests.

- **REQ-203**: `hasFileToolMatchers` / `hasFileToolEntry` are derived from the typed slice (or from the same slice decoder `HostWiring` uses), not from a third copy of matcher string lists.

- **REQ-204**: Strip / uninstall still leave foreign remainder. Empty remainder after strip still returns `nil` (file remove) as today, including Cursor version-only leftover.

- **REQ-205**: `SetupRun` writeClaude / writeCursor / writeCodex keep calling `merge`. If signatures stay, SetupRun may be untouched. If a signature must change, SetupRun is in this ticket’s exclusive set — behavior-identical writes.

- **REQ-206**: Tests: existing Claude/Cursor/Codex merge tests pass. Add: apply then `HostWiring.fileTools` on the merged bytes reports Claude `.wired`, Cursor `.wired` (companion JSON is the merged hooks.json), Codex file-tools stay `.notApplicable`.

- **CON-201**: Do not drop unknown host keys. Occupied / force / stale-legacy Claude inspection states stay.
- **CON-202**: Do not edit `ServiceRuntime.swift`, codecs, or ApprovalRuntime files.
- **CON-203**: Do not register Codex file-tool matchers. Codex stays shell-only / notApplicable.

## T3 — ApprovalRuntime

- **REQ-301**: Add `Sources/RVService/ApprovalRuntime.swift`. An `actor ApprovalRuntime` (or `struct` owned exclusively by `ServiceRuntime` if an extra actor hop is unnecessary — prefer actor if it holds generation + fingerprint). It owns:

  - `pendingApprovals: (any PendingApprovalCoordinating)?`
  - `allowOnce: AllowOnceStore`
  - clock
  - `pendingGeneration` / `pendingSetFingerprint`
  - a peek port: `@Sendable (ShellCommand, WorkingDirectory?, Date) async -> EvaluationResult` (today’s `peekPendingCommand` via `LiveEvaluateWorld.peek`)

- **REQ-302**: Package API (names may match neighbors):

  ```swift
  func list() async -> IPCResult
  func watch(afterGeneration: UInt64) async -> IPCResult
  func resolve(_ params: PendingResolveParams) async -> IPCResult
  func previewRule(_ params: RulePreviewParams) async -> IPCResult
  func saveRule(_ params: RuleSaveParams) async -> IPCResult
  ```

  Each returns the same `IPCResult` cases as today’s `ServiceRuntime` methods.

- **REQ-303**: Move these `ServiceRuntime` methods’ bodies (behavior-identical):

  - `pendingListResult` / `pendingWatchResult` / `makePendingListReply`
  - `pendingResolveResult` / `resolveAllowOnce` / `resolvePendingDecision` / `isTerminal`
  - `rulePreviewResult` / `ruleSaveResult` / `pinnedPolarity`
  - `peekPendingCommand` (as the injected peek port, constructed in `ServiceRuntime`)

  `PendingAllowOncePlanner` and `PendingListProjection` stay. Do not change planner cases.

- **REQ-304**: `ServiceRuntime.dispatch` pending/rule cases call `approvals.*` only. `ServiceRuntime` must not call `RulePinStore`, `pendingApprovals.resolve`, or `allowOnce.insertGranted` except by constructing `ApprovalRuntime` in `init`.

- **REQ-305**: Plant-then-consume order, consume-after-failed-plant, already-terminal, identity/fingerprint mismatch, hard-bind refuse, and rule draft/hard-stop errors stay identical. Existing `PendingDispatchTests` pass without rewrite of fixtures.

- **REQ-306**: `ApprovalRuntime` is constructed once in `ServiceRuntime.init` (and wherever `gated` / `allowOnce` / `pendingApprovals` / `clock` are set). Pack rebuild does not recreate it unless `allowOnce` identity changes (it does not today).

- **CON-301**: Do not edit RVCLI Setup, HostWiring, or host codecs.
- **CON-302**: Do not fold miss into `HookDoor`. Do not change `HookEvaluateWorld.live`.
- **CON-303**: Do not change evaluate / explain / classify / packs / doctor / handshake.
- **CON-304**: Do not invent a second AllowOnce door. Mint on hook deny stays on `LiveEvaluateWorld`.

# 4. Interfaces & Data Contracts

## HostWiring (T1/T2)

```swift
enum HostWiring {
    static func fileTools(
        host: HookHost,
        adapterData: Data?,
        companionJSON: Data?
    ) -> DoctorFileToolsState
}
```

`HostAdapterInstallation.fileTools` becomes:

```swift
func fileTools(companionJSON: Data? = nil) -> DoctorFileToolsState {
    switch self {
    case .wired(_, let data):
        return HostWiring.fileTools(
            host: ownedPath.host,
            adapterData: data,
            companionJSON: companionJSON
        )
    case .missing, .absentFile, .occupied, .broken:
        return .notApplicable
    }
}
```

T2 merge remains `(data: Data, wrote: Bool)` at the SetupRun boundary.

## ApprovalRuntime (T3)

`ServiceRuntime.dispatch` fragment:

```swift
case .pendingList:
    result = await approvals.list()
case .pendingWatch(let params):
    result = await approvals.watch(afterGeneration: params.afterGeneration)
case .pendingResolve(let params):
    result = await approvals.resolve(params)
case .rulePreview(let params):
    result = await approvals.previewRule(params)
case .ruleSave(let params):
    result = await approvals.saveRule(params)
```

Peek port construction (ServiceRuntime, not ApprovalRuntime importing extra policy I/O):

```swift
{ command, cwd, now in
    await LiveEvaluateWorld(
        home: configHome,
        store: allowOnce,
        gated: gated,
        clock: { now }
    ).peek(command: command, cwd: cwd)
}
```

# 5. Acceptance Criteria

- **AC-101**: Given Claude wired settings that include Read/Edit/Write matchers, when `HostWiring.fileTools(host: .claude, adapterData:data, companionJSON:nil)` runs, then result is `.wired`, and `HostAdapterInstallation.wired(...).fileTools()` agrees.
- **AC-102**: Given Cursor wired adapter + hooks.json with only `beforeShellExecution` (no fingerprinted `preToolUse`), then file-tools is `.shellOnly` (existing DoctorTests / HostAdapterInstallationTests).
- **AC-103**: `rg 'hasFileToolMatchers|hasFileToolEntry|hasFileToolDoor' Sources/RVCLI/Setup/HostAdapterInstallation.swift` does not match after T1 (delegation only).
- **AC-201**: Given empty Claude settings, when `ClaudeSettingsMerge.merge` runs, then output still contains Bash + Read + Edit + Write fingerprinted entries and a second merge is `wrote == false` when bytes match (existing tests).
- **AC-202**: Given a Claude settings file with a foreign `hooks.Notification` key, when merge then uninstall-strip runs, then that key remains until strip of rv entries; strip does not drop unrelated roots today — preserve that.
- **AC-203**: After T2 merge of Cursor hooks, `HostWiring.fileTools(host: .cursor, adapterData: adapterBytes, companionJSON: mergedHooks)` is `.wired`.
- **AC-301**: Existing `PendingDispatchTests` pass unchanged in intent (allow-once plant, refuse hard bind, rule hard-stop, draft mismatch).
- **AC-302**: `rg 'RulePinStore|insertGranted|pendingApprovals.resolve' Sources/RVService/ServiceRuntime.swift` matches only `ApprovalRuntime` construction / comments, not resolve/save bodies.
- **AC-303**: `ServiceRuntime.dispatch` pending/rule cases are one-liners to `approvals`.

# 5b. Tickets (task graph)

### T1 — HostWiring file-tool inspect

| Field | Value |
|---|---|
| `id` | T1 |
| `title` | HostWiring.fileTools is the only inspect-time file-tool door |
| `depends-on` | none |
| `exclusive-writes` | `Sources/RVCLI/Setup/HostWiring.swift` (new), `Sources/RVCLI/Setup/HostAdapterInstallation.swift`, `Sources/RVCLI/Setup/GrokHookInspect.swift`, `Tests/RVCLITests/HostAdapterInstallationTests.swift` |
| `acceptance` | AC-101, AC-102, AC-103 |
| `review-hint` | 101–1499 |

### T2 — Typed RV slice on merge apply

| Field | Value |
|---|---|
| `id` | T2 |
| `title` | Claude/Cursor/Codex merge writes a typed RV slice plus opaque remainder |
| `depends-on` | T1 |
| `exclusive-writes` | `Sources/RVCLI/Setup/ClaudeSettingsMerge.swift`, `Sources/RVCLI/Setup/CursorHooksMerge.swift`, `Sources/RVCLI/Setup/CodexHooksMerge.swift`, `Sources/RVCLI/Setup/SetupRun.swift`, `Sources/RVCLI/Setup/HostWiring.swift`, `Tests/RVCLITests/CursorHooksMergeTests.swift`, `Tests/RVCLITests/CodexHooksMergeTests.swift`, `Tests/RVCLITests/HostAdapterInstallationTests.swift`, `Tests/RVCLITests/SetupTests.swift` (only if a merge signature forces it) |
| `acceptance` | AC-201, AC-202, AC-203 |
| `review-hint` | 101–1499 |

T2 may edit `HostWiring.swift` to share slice decoders with `fileTools`. Do not expand exclusive-writes to codecs or Service.

### T3 — ApprovalRuntime

| Field | Value |
|---|---|
| `id` | T3 |
| `title` | Pending and rule IPC live in ApprovalRuntime |
| `depends-on` | none |
| `exclusive-writes` | `Sources/RVService/ApprovalRuntime.swift` (new), `Sources/RVService/ServiceRuntime.swift`, `Sources/RVService/PendingIPC.swift`, `Sources/RVService/PendingResolveGrant.swift`, `Tests/RVServiceTests/PendingDispatchTests.swift`, `Tests/RVServiceTests/PendingHostAskTests.swift` (only if compile requires) |
| `acceptance` | AC-301, AC-302, AC-303 |
| `review-hint` | 101–1499 |

Frontier: T1 ∥ T3. Then T2 (after T1).

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit tests in `RVCLITests` (T1/T2) and `RVServiceTests` (T3). No TTY-to-prove-decision tests.
- **Frameworks**: Swift Testing (`import Testing`). No XCTest.
- **Test Data Management**: Temp directories under `FileManager.default.temporaryDirectory`. Never live `$HOME`.
- **CI/CD Integration**: `tools/gate.sh RVCLITests` (T1/T2), `tools/gate.sh RVServiceTests` (T3). Warm `.build`.
- **Coverage Requirements**: Behavior of listed ACs. Do not add mock-every-dependency tests.
- **Performance Testing**: None.

# 7. Rationale & Context

Evaluate, Policy gate, HookRequest, and LiveEvaluateWorld already landed. The remaining leaks are (1) install-time file-tool classification split across JSON bags, and (2) pending/rule effects left in the ServiceRuntime actor after evaluate was extracted. MachineConfig and ServiceCall are real but lower leverage; skip this DAG.

Prior passes skipped a “setup materializer” / FileOps plan. T1/T2 are the **file-tool door axis**, not a FileOps rewrite. `SetupWorkPlan` stays.

# 8. Dependencies & External Integrations

### External Systems
- **EXT-001**: Host settings/hooks JSON on disk (Claude `settings.json`, Cursor/Codex `hooks.json`) — foreign documents; rv slice only.

### Third-Party Services
- None.

### Infrastructure Dependencies
- **INF-001**: Swift 6.3.3 toolchain via `tools/swift-6.3.3`.

### Data Dependencies
- **DAT-001**: Existing merge fixtures in RVCLITests. Existing PendingDispatchTests IPC fixtures.

### Technology Platform Dependencies
- **PLT-001**: macOS 26 + Linux aarch64/x86_64. Language mode 6.

### Compliance Dependencies
- **COM-001**: Hexagon: Setup mutations stay in RVCLI. Approval IPC stays in RVService.

# 9. Examples & Edge Cases

```swift
// T1: wired Claude without file matchers is shell-only
let settings = try ClaudeSettingsMerge.merge(
    existingData: bashOnlySettings,
    rvPath: rv,
    adapterPath: adapter,
    force: false
).data
#expect(HostWiring.fileTools(host: .claude, adapterData: settings, companionJSON: nil) == .wired)
// only if merge inserted file matchers — bash-only leftover from an old file is .shellOnly
```

```swift
// T3: hard-bound peek refuses plant
switch PendingAllowOncePlanner.plan(peek: hardDeny, cwd: cwd) {
case .refuse: break
default: Issue.record("hard bind must refuse")
}
```

# 10. Validation Criteria

- `tools/gate.sh RVCLITests` green on T1 and T2 branches.
- `tools/gate.sh RVServiceTests` green on T3 branch.
- `rg` acceptance lines AC-103 and AC-302 hold.
- No `Package.swift` change.
- No live HOME.

# 11. Related Specifications / Further Reading

- `spec/spec-architecture-hook-request-live-world.md` (landed; do not reopen)
- `spec/spec-architecture-setup-workplan.md` (landed; do not rewrite plan enum)
- `docs/architecture/MODULES.md`
- `CONTEXT.md` (Host adapter installation state, File tool, Policy gate)
- HTML: `$TMPDIR/swift-architecture-review-rv-20260915-232633.html`
