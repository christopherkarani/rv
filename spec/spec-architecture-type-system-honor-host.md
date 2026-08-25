---
title: Honor-path WorkingDirectory and one HookHost family
version: 1.0
date_created: 2026-08-25
last_updated: 2026-08-25
owner: rv
tags:
  - architecture
  - type-system
  - policy
  - hosts
---

# Introduction

Execute the two Strong candidates from the 2026-08-25 type-system review
(`$TMPDIR/swift-type-system-review-rv-20260825-135632.html`):

1. **T1** — `WorkingDirectory` newtype on the allow-once honor path (cwd),
   matching the `HomeDirectory` pattern already landed (TH1 / #59).
2. **T2** — delete `SetupHostKind`; Presentation/CLI setup, doctor, and owned
   paths switch on `HookHost` (already in RVDomain after WV-T1 / #71).

Base SHA: `a86fb34` (`main`). Toolchain: swift-tools 6.3 / toolchain 6.3.3
(`tools/swift-6.3.3`), language mode 6, macOS 26 only. Gate: `tools/gate.sh`.
Never wipe `.build` to prove a compile.

Audience: fresh-context implementer and reviewer subagents.

# 1. Purpose & Scope

Make two classes of invalid program unrepresentable:

- Empty string as an allow-once honor key, and swapping matching-view text
  with cwd at typed APIs.
- A setup/doctor host identity that can drift from the wire `HookHost` family.

## In scope

- New `WorkingDirectory` in RVDomain; honor-path call sites listed in T1
  exclusive writes.
- `HookHost: CaseIterable`; removal of `SetupHostKind` and both mapping
  functions.

## Out of scope

- Retiring or retyping `AllowOnceConsumeParams` / `AllowOnceConsumeReply`.
  Product law: allow-once is TTY + Policy gate; the hook wire never carries a
  code. `spec/spec-architecture-wire-vocabulary.md` WV-T2 already specifies
  retiring that phantom method. It is not on this `main`. Do not "improve"
  those types here.
- `ExplainStage.name: String` → `ExplainStep.ID` (same WV-T2 slice).
- `AllowOnceRecord` kind + `consumedAt` lifecycle enum (Worth exploring).
- Collapsing `HostCodec` into an enum (project capability protocol).
- `SetupEnvironment.home: String` → `HomeDirectory` (same files as T2).
- PatternEngine, ServiceTransport, analytics `Any` JSONSerialization boundary.
- Decision / EvaluationOutcome (already closed).

# 2. Definitions

| Term | Meaning |
|---|---|
| Honor path | Policy gate after engine deny: allowlist then one matching-view + cwd grant. Missing cwd skips honor. |
| WorkingDirectory | Nonempty workspace path used as the grant honor key. Absence is `WorkingDirectory?`. `""` is not representable. |
| Matching view | T1-normalized command text (`MatchingView`). Distinct from cwd and from raw `ShellCommand`. |
| Host family | Closed three-case set `grok` / `pi` / `opencode` (`HookHost` raw values). |
| Setup slot | TTY setup/doctor row for one Host adapter. Same family as the wire host. |

# 3. Requirements, Constraints & Guidelines

## T1 — WorkingDirectory

- **REQ-101**: Add `public struct WorkingDirectory: RawRepresentable, Hashable, Sendable, Codable` in RVDomain. Failable `init?(validating:)` / `init?(rawValue:)` reject `""`. Codable is a single JSON string (same shape as `HomeDirectory` / `MatchingView`). No `ExpressibleByStringLiteral` (empty literals must not compile as a value).
- **REQ-102**: `HookRequest.cwd` is `WorkingDirectory?`. Grok decode maps envelope cwd through `WorkingDirectory(validating:)`; empty or missing becomes `nil`. Pi and OpenCode still omit cwd (stay `nil`).
- **REQ-103**: `hookWire(host:stdin:evaluate:)` evaluate closure takes `(ShellCommand, WorkingDirectory?)`. `HookDoor.run` matches.
- **REQ-104**: `PolicyGate.decide` / `peek` / `apply` / `honorCwd` take `WorkingDirectory?`. Empty-string tests become `cwd: nil`. Nonempty test paths use `WorkingDirectory(validating:)!` only in tests if the fixture is a known nonempty literal — prefer `try #require(WorkingDirectory(validating: "/tmp/ws"))`.
- **REQ-105**: `AllowOnceRecord.cwd`, `AllowOnceListRow.cwd`, ledger mint/consume, and `AllowOnceStore` honor APIs use `WorkingDirectory` (non-optional on stored grants). On-disk jsonl key `cwd` remains a string; custom Codable or `rawValue` encode must keep existing bytes for nonempty paths.
- **REQ-106**: IPC `EvaluateParams.cwd`, `ExplainParams.cwd`, `ClassifyParams.cwd` become `WorkingDirectory?`. `RequestCwdCoding.nonempty` becomes validate-or-nil. Encoded JSON for omitted/empty cwd stays omitted or absent — empty string must not reappear as a honor key after decode. Do not change `AllowOnceConsumeParams`.
- **REQ-107**: `GatedEvaluate.run` / `peek` / `apply`, `ServiceRuntime` evaluate/explain/classify cwd parameters, `ServiceClient.evaluate`, and CLI `CommandRun` honor callers use `WorkingDirectory?`. ArgumentParser / `FileManager` strings convert once at the CLI edge.
- **CON-101**: Do not add generics, phantom states, or a `HonorKey<View, Cwd>` pair type.
- **CON-102**: Do not honor a grant when cwd is `nil`. Product law unchanged: Pi/OpenCode codecs do not populate cwd.
- **CON-103**: No live-HOME tests. No command text in `os_log`.
- **GUD-101**: Mirror `Sources/RVPolicy/HomeDirectory.swift` for the newtype; do not copy HOME semantics (this is workspace cwd, not `~/.config/rv`).

## T2 — One HookHost family

- **REQ-201**: `HookHost` gains `CaseIterable` with case order `grok`, `pi`, `opencode` (current setup slot order).
- **REQ-202**: Delete `SetupHostKind`. Every former use switches on `HookHost`. Display names stay in Presentation: `extension HookHost { var displayName: String }` with Grok / Pi / OpenCode.
- **REQ-203**: Delete `SetupHostKind.hookHost`, `SetupHostKind.init(hook:)`, and `OwnedHostAdapterPath` dual identity. One `host: HookHost` field.
- **REQ-204**: Robot JSON host keys stay `"grok"` / `"pi"` / `"opencode"` via `HookHost.rawValue`. Delete `robotName` if it only duplicated raw values.
- **REQ-205**: `HostAdapterInstallationSnapshot` and `SetupSlotSnapshot` still store three fields or subscript via exhaustive `HookHost` switch — no `[HookHost: …]` dictionary that loses exhaustiveness.
- **CON-201**: Do not change `HostCodec`. Do not add a fourth host.
- **CON-202**: Wire raw values unchanged.

- **CON-001** (all): Swift 6.3.3, language mode 6, value types only in Domain/Engine/Packs/Presentation. `class` only at XPC edge.
- **CON-002**: Exclusive writes per ticket. No drive-by.
- **PAT-001**: TH1 `HomeDirectory`, WV-T1 `HookHost` in Domain, `EvaluationOutcome` closed fields.

# 4. Interfaces & Data Contracts

```swift
// RVDomain — new
public struct WorkingDirectory: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init?(validating rawValue: String) // nil iff empty
    public init?(rawValue: String)
}

// RVHooks
public struct HookRequest: Equatable, Sendable {
    public var host: HookHost
    public var command: ShellCommand
    public var cwd: WorkingDirectory?
}

public func hookWire(
    host: HookHost,
    stdin: String,
    evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult
) async -> HookWire

// RVPolicy
public enum PolicyGate {
    public static func decide(
        _ result: EvaluationResult,
        cwd: WorkingDirectory?,
        allowlist: AllowlistSnapshot,
        grant: GrantPresence,
        now: Date
    ) -> PolicyDecision
}

// RVIPC — EvaluateParams / ExplainParams / ClassifyParams
public var cwd: WorkingDirectory?
```

JSON: `"cwd":"/tmp/ws"` encodes as today. `"cwd":""` decodes to `nil`.

# 5. Acceptance Criteria

- **AC-101**: `WorkingDirectory(validating: "") == nil`. Decode of JSON `""` throws or yields nil at the IPC nonempty helper — PolicyGate never receives a nonempty-looking empty path.
- **AC-102**: `HookRequest(host:command:cwd:)` does not compile with `cwd: MatchingView(...)` or `cwd: ShellCommand(...)`.
- **AC-103**: Existing PolicyGate empty-cwd skip behavior holds with `cwd: nil`. Grant honor for `/tmp/ws` still works.
- **AC-104**: Grok decode of cwd `""` and missing cwd both produce `HookRequest.cwd == nil`.
- **AC-105**: `rg -n 'AllowOnceConsumeParams' Sources` still matches (untouched). `tools/gate.sh` green for T1 filters.
- **AC-201**: `rg -n 'enum SetupHostKind' Sources Tests` matches nothing.
- **AC-202**: `rg -n 'SetupHostKind' Sources Tests` matches nothing.
- **AC-203**: `HookHost.allCases.map(\.rawValue) == ["grok", "pi", "opencode"]`.
- **AC-204**: Doctor/setup robot host keys remain grok/pi/opencode. Existing setup/doctor tests pass in intent.
- **AC-205**: `OwnedHostAdapterPath` has a single host field of type `HookHost`.
- **AC-301** (all): No new `as!` / `try!` / `TODO`/`FIXME`. Gate per ticket.

# 5b. Tickets (task graph)

## T1

| Field | Value |
|---|---|
| `id` | T1 |
| `title` | WorkingDirectory on the honor path |
| `depends-on` | none |
| `exclusive-writes` | `spec/spec-architecture-type-system-honor-host.md`, `Sources/RVDomain/WorkingDirectory.swift` (new), `Tests/RVDomainTests/NewtypeTests.swift`, `Sources/RVHooks/HostCodec.swift`, `Sources/RVHooks/GrokHostCodec.swift`, `Sources/RVHooks/HookDispatch.swift`, `Tests/RVHooksTests/**` (cwd/decode only), `Sources/RVPolicy/PolicyGate.swift`, `Sources/RVPolicy/AllowOnceRecord.swift`, `Sources/RVPolicy/AllowOnceLedger.swift`, `Sources/RVPolicy/AllowOnceStore.swift`, `Tests/RVPolicyTests/**`, `Sources/RVIPC/IPCMethods.swift` (cwd / `RequestCwdCoding` only; do not edit allowOnceConsume types), `Tests/RVIPCTests/**` (cwd round-trip only), `Sources/RVService/GatedEvaluate.swift`, `Sources/RVService/HookDoor.swift`, `Sources/RVService/ServiceRuntime.swift` (cwd parameters only), `Tests/RVServiceTests/**` (cwd call sites), `Sources/RVCLI/Service/ServiceClient.swift`, `Sources/RVCLI/CommandRun.swift`, `Sources/RVCLI/AllowOnceCommand.swift`, `Sources/RVCLI/Robot/AllowOnceRobot.swift`, `Tests/RVCLITests/**` (honor/cwd call sites only) |
| `acceptance` | AC-101…105, AC-301 |
| `review-hint` | `101–1499` (`PolicyGate.swift` / `IPCMethods.swift`) → `swift-pr-review` |
| `gate` | `tools/gate.sh RVDomainTests` then `RVHooksTests` `RVPolicyTests` `RVIPCTests` `RVServiceTests` `RVCLITests` (or one gate covering those filters) |
| `skill` | `swift-type-system-architecture` (implement the specified types only), `swift-testing-pro`, `.grok/skills/swift-hook-xpc` if touching codecs |

## T2

| Field | Value |
|---|---|
| `id` | T2 |
| `title` | HookHost replaces SetupHostKind |
| `depends-on` | none |
| `exclusive-writes` | `Sources/RVDomain/HookHost.swift`, `Tests/RVDomainTests/HookHostTests.swift`, `Sources/RVPresentation/SetupViewModel.swift`, `Sources/RVPresentation/SetupCeremony.swift`, `Sources/RVPresentation/UninstallCeremony.swift`, `Sources/RVPresentation/DoctorViewModel.swift`, `Sources/RVPresentation/RobotPayloads.swift`, `Tests/RVPresentationTests/**`, `Sources/RVCLI/Setup/OwnedPaths.swift`, `Sources/RVCLI/Setup/SetupRun.swift`, `Sources/RVCLI/Setup/SetupError.swift`, `Sources/RVCLI/Setup/SetupFormat.swift`, `Sources/RVCLI/Setup/HostAdapterInstallation.swift`, `Sources/RVCLI/Doctor/DoctorRun.swift`, `Tests/RVCLITests/HostAdapterInstallationTests.swift`, `Tests/RVCLITests/DoctorTests.swift`, `Tests/RVCLITests/SetupTests.swift`, `Tests/RVTUITests/SetupRendererTests.swift` |
| `acceptance` | AC-201…205, AC-301 |
| `review-hint` | `101–1499` (`SetupViewModel.swift` / `SetupRun.swift`) → `swift-pr-review` |
| `gate` | `tools/gate.sh RVDomainTests` `RVPresentationTests` `RVCLITests` `RVTUITests` |
| `skill` | `swift-type-system-architecture` |

Parallel-safe: **Yes**. Disjoint exclusive writes. T1 must not edit `HookHost.swift` or any `Setup*` Presentation/CLI file. T2 must not edit cwd/honor APIs.

Specialist: TDD — tests that pin `WorkingDirectory(validating: "") == nil` and `HookHost.allCases` land in the same ticket as the type, before callers if practical.

# 6. Test Automation Strategy

- Framework: Swift Testing (`@Test`, `#expect`). Fixtures/fakes stay in `Tests/`.
- No live HOME. Isolated allow-once stores as today.
- T1: extend `NewtypeTests.swift`; update `PolicyGateTests` empty-cwd case to `nil`; Grok decode tests for empty cwd.
- T2: extend `HookHostTests.swift`; setup/doctor tests keep observable robot/pretty behavior.
- Gate: `tools/gate.sh` with warm `.build`. Pin `tools/swift-6.3.3`. Do not `swift package clean`.

# 7. Rationale & Context

`HomeDirectory` already proved empty-string sentinels do not belong next to `Optional`. Cwd still uses `String?` plus `isEmpty` in PolicyGate, Grok decode, and `RequestCwdCoding`. That is the remaining honor-path hole.

`HookHost` already closed the wire family (WV-T1). `SetupHostKind` with `openCode` vs `opencode` is a second closed world plus two mapping functions. Unifying is negative complexity.

Worth-exploring items (AllowOnceRecord lifecycle, ExplainStage.ID) stay out: persistence/IPC migration cost, and WV-T2 already specified the stage-name slice.

# 8. Dependencies & External Integrations

None new. Darwin/Foundation as today.

# 9. Examples & Edge Cases

```swift
WorkingDirectory(validating: "")          // nil
WorkingDirectory(validating: "/tmp/ws")   // value
// PolicyGate.decide(denied, cwd: nil, ...)  // skip honor
// JSON cwd "" or missing → WorkingDirectory? nil after RequestCwdCoding
```

- Grok envelope `"cwd":""` → `HookRequest.cwd == nil` (same as missing).
- Pi/OpenCode decode still `cwd: nil`.
- MatchingView remains allowed to be empty (`MatchingView("")` for empty command evaluate) — do not conflate with WorkingDirectory.

# 10. Validation Criteria

Per ticket: exclusive-write `git diff --name-only` is a subset of the ticket list (new files allowed if named). AC grep bullets true. Gate green. Reviewer findings fixed. Final pass clean. One PR per ticket off `main`.

Branches: `arch/<run-id>/T1`, `arch/<run-id>/T2`.

# 11. Related Specifications / Further Reading

- Type-system report: `/var/folders/ns/xmz0zmpj7p148vdgr4bwzp8h0000gn/T/swift-type-system-review-rv-20260825-135632.html`
- `spec/spec-architecture-wire-vocabulary.md` (WV-T1 landed; WV-T2 specified, not on this main)
- TH1 HomeDirectory: PR #59
- `CONTEXT.md` Policy gate / Allow-once grant / Host adapter
- `docs/architecture/MODULES.md`, `AGENTS.md`
