---
title: One hook door plus SessionID fingerprint builder
version: 1.0
date_created: 2026-08-31
last_updated: 2026-08-31
owner: architecture-pipeline
tags: [architecture, functional-evolution, hooks, ipc]
---

# Introduction

Execute the two Strong candidates from `$TMPDIR/swift-functional-evolution-rv-20260831-140046.html` (HEAD exploration `24b951b`, implement off `origin/main`).

1. **C01** — Swift `rv hook` must not rebuild Host Ask from a Codable `evaluate` reply that is defined to drop `BoundReview`. One hook door: mapping happens next to in-process `GatedEvaluate`, same as C `hookEvaluate`.
2. **C02** — Own host-door fingerprint construction: `SessionID` + `ActionFingerprint.make`; delete Codex/Cursor duplicate `proposedAction` overrides.

Do not put `boundReview` on the evaluate wire. Do not implement full OPE-156 (no effects on host `ProposedAction`). Do not migrate AllowOnce keys off `matchingView`. Do not execute PolicyGate analysis-preserve or RulePinning table (not Strong).

# 1. Purpose & Scope

**Audience:** implement-spec agents on `rv` (Swift 6.3.3, language mode 6, macOS 26). Gate: `tools/gate.sh`. Warm `.build`. Never `swift package clean`.

**In scope:**

1. Additive optional `stderr` on `HookEvaluateReply` so Codex honor path can travel with `hookEvaluate`.
2. `HookDoor` copies `HookWire.stderr`.
3. `ServiceClient` grows a `hookEvaluate` path (XPC `hookEvaluate` when transport works; in-process `hookWire` + local `GatedEvaluate` on miss). `HookCommand.run` uses that path, not `evaluateResult`.
4. `SessionID` newtype; `HookRequest.session` stores `SessionID?`; `ActionFingerprint.make`; Codex/Cursor drop identical overrides.

**Out of scope:**

- Codable `boundReview` on `EvaluationResult` / `EvaluateReply`.
- C `json_reply.c` parser changes (unknown keys already `skip_value`).
- Editing `Sources/rv-c/**` unless a golden C test fails because empty `stderr` was encoded (it must not be).
- OPE-156 IR effects on host actions. OPE-158 fingerprint grants.
- `PolicyGate.allowDecision` analysis copy. `RulePinning` table merge.
- Setup/Uninstall, PacksConfig, Elm TUI, scan `[String: Any]`.

**Assumptions:**

- C hit path already maps inside rvd via `HookDoor` and keeps `BoundReview`.
- Swift miss with warm rvd today calls IPC `evaluate`, decode sets `boundReview = nil`, `hookBody` empty-effect fallback cannot recover `mandatoryHuman`.
- `spendHostAsk` is already in-process on `ServiceClient`.
- Hexagon unchanged. No new SPM modules or dependencies.

# 2. Definitions

| Term | Meaning |
|---|---|
| Hook door | Decode stdin → gated evaluate → `BoundReview` → `HostWire`. |
| `hookEvaluate` | `rv.ipc.v1` method whose reply is stdout/exit/(optional stderr), not `EvaluationResult`. |
| In-process bind | `EvaluationResult.boundReview`. Omitted from Codable by design. |
| Host-door fingerprint | `host:session:cwd:command` spelling owned by `ActionFingerprint.make`. |
| Semantic fingerprint | `shell:git.*` / `shell:fs.*` from analyzers. Unchanged this spec. |

# 3. Requirements, Constraints & Guidelines

### T1 — Additive stderr on HookEvaluateReply

- **REQ-101**: `HookEvaluateReply` gains `public var stderr: String` default `""`. Codable key `"stderr"`. Encode only when nonempty (`encodeIfPresent` / omit empty). Decode missing/null as `""`.
- **REQ-102**: Existing golden `hookEvaluateReplyFrame_bytesMatchGolden` stays byte-identical (empty stderr omitted).
- **REQ-103**: `HookDoor.reply` copies `wire.stderr` into the reply. `HookEvaluateReply(stdout:exitCode:)` existing call sites keep compiling (stderr defaults empty).
- **CON-101**: Do not edit `Sources/rv-c/**`. Do not add `stderr` to C `RvHookReply` this ticket.
- **CON-102**: Do not change `EvaluateReply` or `EvaluationResult` Codable keys.
- **GUD-101**: Follow `serviceSemver` additive optional precedent.

### T2 — Swift hook uses hookEvaluate

- **REQ-201**: `ServiceClient` exposes a method (name may match file style, e.g. `hookEvaluate(host:stdin:)`) returning `HookWire` (stdout, exitCode, stderr).
- **REQ-202**: When `transport` is non-nil and the send decodes a `HookEvaluateReply` with `via == .xpc` and compatible semver, return that wire. One-shot budget stays connect+request (700 ms), same as evaluate. Implicit hello via `clientSemver` on `HookEvaluateParams`.
- **REQ-203**: On transport nil, send failure, skew, invalid id/protocol, or non-xpc reply: invalidate transport when appropriate (same as `evaluate`) and map in-process: `hookWire(host:stdin:evaluate:spendHostAsk:)` where evaluate is local `door.run(.apply, ...)` and spend is existing `spendHostAsk`. Pack IDs from `GatedEvaluate.makeRequest` / `EvaluationWorld.walkedPackIDs`.
- **REQ-204**: `HookCommand.run()` uses that client method. It must not call `evaluateResult` then local `hookWire` for the production stdin path.
- **REQ-205**: A ScriptedTransport that replies with Codable `EvaluateReply` whose `boundReview` would be nil must no longer be the Swift hook first-call path. Add a test: warm-daemon `hookEvaluate` of a Pi stdin whose in-process result would be `mandatoryHuman` encodes Ask (or, if using a stub transport, prove the sent IPC method is `.hookEvaluate` not `.evaluate`).
- **REQ-206**: Codex deny through Swift hook still forwards stderr when the reply includes it (XPC path) and when in-process `HookWire.stderr` is set.
- **CON-201**: Down/skew still evaluates (fail closed). No `RV_BYPASS`. No silent allow. `git reset --hard` still denies; `git stash drop` still empty allow.
- **CON-202**: Depends on T1 so reply.stderr exists. Do not revert T1 omit-empty encoding.
- **PAT-201**: Mirror `evaluate`'s one-shot `clientSemver` + invalidate-on-skew. Do not add a second hello round-trip.

### T3 — SessionID + ActionFingerprint.make

- **REQ-301**: Add `SessionID` in RVDomain: `RawRepresentable`, `Hashable`, `Sendable`, `Equatable`, `Codable`. Failable `init?(validating:)` / `init?(rawValue:)` reject `""`. Single JSON string.
- **REQ-302**: `HookRequest.session` is `SessionID?`. Initializer may still accept `String?` and map through `SessionID(validating:)` so codecs that pass envelope strings keep one-liners; empty/missing → nil. Stored type is `SessionID?`.
- **REQ-303**: `ActionFingerprint.make(host:session:cwd:command:)` owns `"\(host.rawValue):\(session?.rawValue ?? ""):\(cwd?.rawValue ?? ""):\(command.rawValue)"`. Default `HostCodec.proposedAction` calls it.
- **REQ-304**: Delete `proposedAction(from:)` overrides on `CodexHostCodec` and `CursorHostCodec` when they only re-spell the default.
- **REQ-305**: Update `ProposedAction.swift` comment: IR owns host-door fingerprint construction; semantic Git/FS fingerprints remain distinct.
- **CON-301**: Do not change GitAction / FilesystemAction fingerprint alphabets. Do not change AllowOnce keys.
- **CON-302**: Independent of T1/T2 (no exclusive-write overlap). Must not revert BoundReview behavior.
- **GUD-301**: No `ExpressibleByStringLiteral` on `SessionID`.

# 4. Interfaces & Data Contracts

```swift
public struct HookEvaluateReply: Sendable, Equatable, Codable {
    public var stdout: String
    public var exitCode: Int32
    public var stderr: String  // default ""; omit empty on encode
    public let via: EvaluationPath
    public var serviceSemver: String?
}

// ServiceClient
func hookEvaluate(host: HookHost, stdin: String) async -> HookWire

public struct SessionID: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String
    public init?(validating rawValue: String) // rejects ""
}

extension ActionFingerprint {
    public static func make(
        host: HookHost,
        session: SessionID?,
        cwd: WorkingDirectory?,
        command: ShellCommand
    ) -> ActionFingerprint
}
```

Empty-stderr `HookEvaluateReply` JSON stays the current golden (no `stderr` key).

# 5. Acceptance Criteria

- **AC-101**: Given `HookEvaluateReply(stdout: "", exitCode: 1)`, When encoded, Then UTF-8 equals existing golden (no `stderr` key).
- **AC-102**: Given `HookEvaluateReply` JSON with `"stderr":"blocked"`, When decoded, Then `stderr == "blocked"`. Missing key → `""`.
- **AC-103**: Given `HookDoor.run` on a codec that sets `HookWire.stderr`, When the reply is built, Then `reply.stderr` equals that string.
- **AC-201**: Given `ServiceClient` with a working transport, When Swift `Hook.run` production path evaluates stdin, Then the sent IPC method is `.hookEvaluate`, not `.evaluate`.
- **AC-202**: Given transport nil, When Swift hook runs `git reset --hard` fixture, Then deny (not allow). `git stash drop` empty allow.
- **AC-203**: Given a ScriptedTransport `hookEvaluate` reply for Pi with spend-first Ask semantics, When mapped, Then stdout is Ask JSON (`decision` ask), not a silent allow.
- **AC-301**: `SessionID(validating: "") == nil`. Nonempty round-trips Codable.
- **AC-302**: `ActionFingerprint.make` matches today's default interpolation for grok/pi/opencode/codex/cursor host raw values; nil session and nil cwd use empty field slots.
- **AC-303**: `rg -n 'func proposedAction' Sources/RVHooks/CodexHostCodec.swift Sources/RVHooks/CursorHostCodec.swift` matches nothing.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | Additive `stderr` on `HookEvaluateReply`; HookDoor copies it | none | `spec/spec-architecture-hook-door-fingerprint.md`, `Sources/RVIPC/IPCMethods.swift` (HookEvaluateReply region only), `Sources/RVService/HookDoor.swift`, `Tests/RVIPCTests/HookEvaluateRoundTripTests.swift`, `Tests/RVServiceTests/HookEvaluateTests.swift` | AC-101, AC-102, AC-103; `tools/gate.sh RVIPCTests RVServiceTests` | 101–1499 (`IPCMethods.swift`) |
| T2 | Swift hook door uses `hookEvaluate` | T1 | `Sources/RVCLI/Commands/HookCommand.swift`, `Sources/RVCLI/Service/ServiceClient.swift`, `Tests/RVCLITests/HookCommandTests.swift`, `Tests/RVCLITests/OneShotEvaluateTests.swift`, `Tests/RVCLITests/HostAskSpendTests.swift` (only if the production hook path is asserted there) | AC-201, AC-202, AC-203; `tools/gate.sh RVCLITests` | 101–1499 (`ServiceClient.swift`) |
| T3 | SessionID + ActionFingerprint.make; delete codec dupes | none | `Sources/RVDomain/SessionID.swift` (new) or colocated in `ProposedAction.swift`, `Sources/RVDomain/ProposedAction.swift`, `Sources/RVHooks/HostCodec.swift`, `Sources/RVHooks/CodexHostCodec.swift`, `Sources/RVHooks/CursorHostCodec.swift`, `Tests/RVDomainTests/` (SessionID / fingerprint only), `Tests/RVHooksTests/CodexHookTests.swift`, `Tests/RVHooksTests/CursorHookTests.swift` | AC-301, AC-302, AC-303; `tools/gate.sh RVDomainTests RVHooksTests` | 101–1499 (`HostCodec.swift`) |

Specialists: T1/T2 → `swift-functional-architecture` + `.grok/skills/swift-hook-xpc` + `swift-testing-pro`. T3 → `swift-type-system-architecture` if present else `swift-functional-architecture` + `swift-hook-xpc` + `swift-testing-pro`.

Frontier: T1 ∥ T3. T2 after T1 merge base.

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing in the ticket's module test targets. No live-HOME. Temp HOME for ServiceClient store tests.
- **Frameworks**: Swift Testing. No XCTest.
- **Commands**: `tools/gate.sh` as in the ticket table. Warm `.build`. Never wipe `.build`.
- **RED**: failing assertion first. Do not weaken golden frames to pass.

# 7. Rationale & Context

`BoundReview` was made in-process-only (#170). C `hookEvaluate` honors that. Swift `HookCommand` then preferred IPC `evaluate`, which strips the bind. Warm rvd therefore Asks on C and Denies on Swift for semantic `mandatoryHuman`. Putting the bind on Codable would fight the type. Routing Swift through `hookEvaluate` (or local door on miss) is the deep module.

Fingerprint builder is leftover T2 from `spec-architecture-bound-review-fingerprint.md`. Small type-system slice of OPE-156, not the full IR.

# 8. Dependencies & External Integrations

- **PLT-001**: Swift 6.3.3, language mode 6, macOS 26. `tools/swift-6.3.3`.
- **INF-001**: Existing `rv.ipc.v1` XPC/unix transport. Additive reply field only.

# 9. Examples & Edge Cases

```swift
// T1 encode omit
HookEvaluateReply(stdout: "", exitCode: 1)  // no stderr key

// T2 miss
ServiceClient(transport: nil).hookEvaluate(...)  // in-process hookWire

// T3
SessionID(validating: "") == nil
ActionFingerprint.make(host: .codex, session: nil, cwd: nil, command: cmd)
// rawValue == "codex:::git status"  (empty session and cwd slots)
```

# 10. Validation Criteria

- Ticket gates green.
- `git stash drop` empty allow; `git reset --hard` deny on miss path.
- No `boundReview` key in `EvaluationResult` encode.
- C golden hookEvaluate request/reply frames unchanged for empty stderr.

# 11. Related Specifications / Further Reading

- `spec/spec-architecture-bound-review-fingerprint.md` (T1 shipped; T2 leftover → this spec T3)
- `spec/spec-architecture-c-hook-pipe.md`
- `docs/architecture/02.md` (SessionID newtype; Ask not a Decision case)
- `docs/architecture/MODULES.md`
- HTML: `$TMPDIR/swift-functional-evolution-rv-20260831-140046.html`
