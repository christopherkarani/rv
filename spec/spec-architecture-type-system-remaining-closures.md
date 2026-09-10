---
title: Type-system remaining closures — scan window, hook voice, allow-once lifecycle, leftover IPC
version: 1.0
date_created: 2026-09-10
last_updated: 2026-09-10
owner: rv
tags: [architecture, type-system, scan, hooks, policy, ipc]
---

# Introduction

Execute the four Strong candidates from `$TMPDIR/swift-type-system-review-rv-20260910-042559.html` (HEAD `394b456`, branch `worktree/quiet-river-45c5`).

1. **T1** — `ScanTimeWindow` becomes `lastDays(UInt) | all`.
2. **T2** — `HostCodec.encodeDeny` / `encodeAsk` take `RuleID?` and `HookVoiceNext`, not parallel strings.
3. **T3** — `AllowOnceRecord` lifecycle enum (top recommendation). jsonl keys frozen.
4. **T4** — Close leftover IPC vocabulary: `ExplainStage.name` is `ExplainStep.ID`; retire `allowOnceConsume`; named `IPCError` cases keep today’s engine-string bytes.

Do not execute Worth-exploring C5 (`ScanHostID` → `HookHost`). Do not revive ProposedAction IR (OPE-156). Do not add `Decision.ask`. Do not change host deny JSON keys or evaluate Codable field names.

Audience: fresh-context implementer and reviewer subagents. Toolchain: Swift 6.3.3 (`tools/swift-6.3.3`), language mode 6, macOS 26. Gate: `tools/gate.sh`. Warm `.build`. Never `swift package clean`.

# 1. Purpose & Scope

Make four illegal programs unrepresentable:

- A scan window that is both “last N days” and “all time”.
- A hook deny/ask whose `rule` is not a `RuleID` and whose `next` is an arbitrary string.
- An allow-once row that is `.granted` and already consumed, or `.consumed` with no stamp.
- A Swift client constructing `allowOnceConsume`, an explain stage named `"quickReject"`, or an `IPCError.engine` sentence the service does not own.

## In scope

- RVScan `ScanTimeWindow` + `SessionScanRequest` storage + CLI flag mapping.
- RVHooks `HostCodec` encode requirements, `HookVoiceNext`, `AllowOnceUnlockCode`, JSON formatting at `hookDenyJSON` / `hookAskJSON`.
- RVPolicy `AllowOnceRecord` in-memory lifecycle + jsonl custom Codable + ledger/store call sites.
- RVIPC `ExplainStage`, `IPCMethod` / `IPCResult` consume cases, `IPCError` named engine cases with frozen string wire; RVService dispatch and tests.

## Out of scope

- Unifying `ScanHostID` and `HookHost`.
- Session-store `[String: Any]` JSON (intentional foreign-JSON boundary).
- `PacksConfig.enabled: [String]` (file DTO; `PacksFacade` already parses `SelectionToken`).
- Failable `PackID(rawValue:)` / `SelectionToken.unknown`.
- Collapsing `HostCodec` into an enum.
- `LiveEvaluation` phantom states; `boundReview` dual meaning.
- C `rv` hook. Host adapter templates. Analytics `Any`.

# 2. Definitions

| Term | Meaning |
|---|---|
| Scan window | Inclusive lookback for session forensics. Either last N days or disabled (`--all`). |
| Hook voice | Native host deny/ask JSON produced by `HostCodec`. Display rule id is slash (`core.git/reset-hard`). |
| Unlock code | Six lowercase hex characters minted for `rv allow-once`. Absence is `AllowOnceUnlockCode?`. |
| Allow-once lifecycle | pending → granted → consumed(at). Terminal consumed cannot later authorize. |
| Phantom method | Codable IPC method whose dispatch always returns `unknownMethod`. |
| Engine string | Today’s `IPCError.engine("…")` payload. Named cases must encode the same UTF-8. |
| rv.ipc.v1 freeze | JSON keys and healthy golden frames stay identical unless a test is for the retired method. |

# 3. Requirements, Constraints & Guidelines

## T1 — ScanTimeWindow enum

- **REQ-101**: Replace `ScanTimeWindow`’s `dayCount` + `isDisabled` with:

  ```swift
  public enum ScanTimeWindow: Sendable, Equatable {
      case lastDays(UInt)
      case all
  }
  ```

  `defaultDayCount` stays `7`. `static let default = lastDays(defaultDayCount)`. `static let all = .all`.
- **REQ-102**: `filter` switches: `.all` returns findings unchanged; `.lastDays(n)` uses `n * 86_400` cutoff. Do not read a day count on `.all`.
- **REQ-103**: `SessionScanRequest` stores `timeWindow: ScanTimeWindow` only. Delete stored `days` and `scanAll`. Keep `var timeWindow` as the stored property (not a computed pair).
- **REQ-104**: CLI `ScanSessionsFlags` still has `--days` and `--all`. Conversion is one computed `timeWindow`: `scanAll ? .all : .lastDays(days)`. ArgumentParser types stay as they are.
- **CON-101**: No generics. No `ScanTimeWindow<Disabled>`. No change to scan bounds, adapters, or classify.
- **GUD-101**: Tests that compared `ScanTimeWindow(dayCount: 7)` compare `.lastDays(7)` or `.default`.

## T2 — Typed hook-deny encode

- **REQ-201**: Add in RVHooks (not Domain):

  ```swift
  public struct AllowOnceUnlockCode: Hashable, Sendable, Equatable {
      public let rawValue: String
      public init?(validating rawValue: String) // same rule as isAllowOnceUnlockCode
  }

  public enum HookVoiceNext: Sendable, Equatable {
      case none
      case ttyHint
      case minted(AllowOnceUnlockCode)
  }
  ```

  `isAllowOnceUnlockCode` remains the predicate; the newtype calls it.
- **REQ-202**: `HostCodec.encodeDeny` / `encodeAsk` take `reason: String, rule: RuleID?, next: HookVoiceNext`. Default extension formats `rule` with `displayRuleID` and `next` with existing `hookUnlockNext` / `mintedUnlockNext` sentences. JSON keys unchanged.
- **REQ-203**: `hookDenyJSON` / `hookAskJSON` may keep `String?` internally as the last-inch wire. Callers in RVHooks pass typed values; they do not pass colon `RuleID.rawValue` as `rule`.
- **REQ-204**: Claude / Codex / Cursor overrides update the new signature. Behavior unchanged: Claude short deny still uses `claudeIndeterminateDenyJSON`; Codex/Cursor still ignore rule/next for honor JSON. Defaults on the protocol extension cover Grok/Pi/OpenCode/OpenClaw/Hermes.
- **REQ-205**: `hookWire(from:… unlockCode: String?)` still accepts the minted string from Policy. Convert with `AllowOnceUnlockCode(validating:)` inside RVHooks; invalid codes become `.none` (same as today’s `mintedUnlockNext` nil).
- **CON-201**: Do not change host JSON keys, deny exit codes, leftover-ask law, or `displayRuleID` slash form. Do not move `AllowOnceUnlockCode` into RVDomain this ticket.
- **CON-202**: Do not edit RVService `mintUnlockCode` return type.
- **GUD-201**: Prefer `next: .none` over optional `HookVoiceNext?`.

## T3 — AllowOnceRecord lifecycle

- **REQ-301**: Replace parallel `kind` + `consumedAt` on `AllowOnceRecord` with:

  ```swift
  public enum AllowOnceLifecycle: Sendable, Equatable {
      case pending
      case granted
      case consumed(at: Date)
  }
  ```

  `AllowOnceRecord.Kind` may remain as a projection for list rows (`pending` / `granted` / `consumed`) so TTY/robot list JSON stays `kind` strings.
- **REQ-302**: jsonl keys stay `kind` and `consumed_at`. Encode `.pending`/`.granted` omitting `consumed_at` (or null — match current granted/pending bytes). Encode `.consumed(at)` as `kind=consumed` plus `consumed_at`. Decode `consumed` without a stamp throws. Decode `pending` or `granted` with a present stamp throws.
- **REQ-303**: `AllowOnceLedger.mint` writes `.pending`. `redeem` pending → `.granted`. `consume` granted → `.consumed(at: now)`. `plantAndConsume` appends `.granted` then consume. Filters that read `.kind == .consumed` read the lifecycle instead.
- **REQ-304**: A test proves `kind=granted` + `consumed_at` present fails decode, and `kind=consumed` without stamp fails decode. Existing redeem/consume/plant tests stay green in intent.
- **CON-301**: Do not persist command text beyond existing `command_redacted`. Do not change hash/fingerprint algorithms or TTL.
- **CON-302**: No phantom `Record<Granted>`. Three-case enum only.
- **GUD-301**: Mirror `PendingApprovalState` + HelloAck illegal-combo throw.

## T4 — Leftover IPC vocabulary

- **REQ-401**: `ExplainStage.name` is `ExplainStep.ID`. Codable encodes/decodes the existing kebab-case raw values (`quick-reject`, not `quickReject`). Unknown name throws `DecodingError`. `ServiceRuntime` constructs `ExplainStage(name: $0.id, elapsedMs: 0)`.
- **REQ-402**: Remove `IPCMethod.allowOnceConsume` and `IPCResult.allowOnceConsume` and the Params/Reply types. JSON with that key fails `IPCMethod` decode (`unknown IPCMethod`). Listener mapping of decode failure stays `decodeFailed` (or today’s decode-error path). Sending consume must not spend a grant — keep/adjust `allowOnceConsumeIsUnknownMethodAndDoesNotSpend` to assert no spend + error, not a consume reply.
- **REQ-403**: Replace production `IPCError.engine("…")` uses with named cases. Keep `engine(String)` only if a leftover unknown engine string must still decode (HelloAck pattern). Production service never constructs `.engine(String)`.

  | Case | Frozen engine string |
  |---|---|
  | `hookEvaluateFailed` | `hook evaluate failed` |
  | `packEnableFailed` | `pack enable failed` |
  | `rulePinRequiresMatchingView` | `rule pin requires a matching view` |
  | `pendingAllowOnceNotUnlockable` | `pending allowOnce is not unlockable` |
  | `pendingCoordinatorUnavailable` | `pending coordinator unavailable` |

  Codable: named cases encode as today’s `engine` key + exact sentence. Decode of those sentences yields the named case. Unknown engine string: `.engine(String)` or throw — prefer named-or-engine leftover so old frames still decode.
- **REQ-404**: Delete round-trip tests that encode `allowOnceConsume` as a supported method. Update tests that `#expect(…engine("pending coordinator unavailable"))` to the named case (equality on `IPCError`).
- **CON-401**: Do not change evaluate / hookEvaluate / explain / classify JSON keys. Do not add `Decision.ask`. Do not edit `Sources/rv-c/**`.
- **CON-402**: Exclusive writes listed in tickets. T4 owns `ServiceRuntime.swift` and `IPCMethods.swift`; other tickets must not touch them.
- **GUD-401**: Golden frames that are not the retired method stay byte-identical.

## Shared

- **CON-001**: Swift 6.3.3, language mode 6, value types only in Domain/Engine/Packs/Presentation/Policy/Hooks/IPC/Scan. `class` only at XPC edge.
- **CON-002**: Exclusive writes per ticket. No drive-by.
- **CON-003**: No `try!` / IUO on production paths. No live-HOME tests. No `RV_BYPASS`. No command text in `os_log`.
- **CON-004**: `tools/gate.sh` with warm `.build`. Do not wipe `.build`.
- **PAT-001**: Closed enums + exhaustive switches. Codable at the wire door. Same pattern as `EvaluationOutcome` / `HelloAck.status` / `PendingApprovalState`.
- **GUD-001**: TDD: failing tests first, then types, then callers.
- **PAT-002**: Specialist: `swift-type-system-architecture`, `swift-testing-pro`. T2 also `.grok/skills/swift-hook-xpc`. T4 also `swift-hook-xpc` for wire freeze.

# 4. Interfaces & Data Contracts

```swift
// RVScan
public enum ScanTimeWindow: Sendable, Equatable {
    case lastDays(UInt)
    case all
}

// RVHooks
public enum HookVoiceNext: Sendable, Equatable {
    case none
    case ttyHint
    case minted(AllowOnceUnlockCode)
}

public protocol HostCodec: Sendable {
    func encodeDeny(reason: String, rule: RuleID?, next: HookVoiceNext) -> HookWire
    func encodeAsk(reason: String, rule: RuleID?, next: HookVoiceNext) -> HookWire
}

// RVPolicy
public enum AllowOnceLifecycle: Sendable, Equatable {
    case pending
    case granted
    case consumed(at: Date)
}

// RVIPC
public struct ExplainStage: Sendable, Equatable, Codable {
    public var name: ExplainStep.ID
    public var elapsedMs: Double
}
```

JSON: explain stage `"name":"quick-reject"`. Engine errors still `"engine":"hook evaluate failed"`. Allow-once jsonl `"kind":"consumed","consumed_at":…`.

# 5. Acceptance Criteria

- **AC-101**: `ScanTimeWindow.all.filter` does not use `defaultDayCount`. `SessionScanRequest` has no `scanAll` stored field.
- **AC-102**: `ScanTimeWindow(dayCount:isDisabled:)` does not compile.
- **AC-201**: `encodeDeny(reason:rule:next:)` does not compile with `rule: String`. Invalid 5-char unlock code does not construct `AllowOnceUnlockCode`.
- **AC-202**: Existing host deny JSON tests remain byte-identical for Grok short deny (slash rule + next sentence).
- **AC-301**: Decode of granted+stamp and consumed-without-stamp throws. Mint/redeem/consume still work.
- **AC-302**: Consumed rows still list as `kind=consumed` for TTY/robot if that surface exists.
- **AC-401**: `ExplainStage(name: "quickReject", …)` does not compile. Decode of `"quickReject"` throws.
- **AC-402**: `IPCMethod.allowOnceConsume` does not compile. Socket send of that key does not spend; error is not a consume reply.
- **AC-403**: `IPCError.hookEvaluateFailed` encodes the same engine string as today.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | ScanTimeWindow enum | none | `Sources/RVScan/TimeWindow.swift`, `Sources/RVScan/SessionScan.swift`, `Sources/RVCLI/Commands/ScanCommand.swift`, `Tests/RVScanTests/DedupeTimeTests.swift`, `Tests/RVScanTests/SessionScanTests.swift` | AC-101, AC-102 | ≤100 TimeWindow; 101–1499 if SessionScan.swift is the largest touched |
| T2 | Typed hook-deny encode | none | `Sources/RVHooks/HostCodec.swift`, `Sources/RVHooks/HookDenyJSON.swift`, `Sources/RVHooks/HookMapper.swift`, `Sources/RVHooks/HookDispatch.swift`, `Sources/RVHooks/HostDenyText.swift`, `Sources/RVHooks/ClaudeHostCodec.swift`, `Sources/RVHooks/CodexHostCodec.swift`, `Sources/RVHooks/CursorHostCodec.swift`, `Tests/RVHooksTests/**` as needed | AC-201, AC-202 | 101–1499 |
| T3 | AllowOnce lifecycle enum | none | `Sources/RVPolicy/AllowOnceRecord.swift`, `Sources/RVPolicy/AllowOnceLedger.swift`, `Sources/RVPolicy/AllowOnceStore.swift`, `Tests/RVPolicyTests/AllowOnceStoreTests.swift` and other RVPolicyTests that construct `AllowOnceRecord` | AC-301, AC-302 | 101–1499 |
| T4 | Leftover IPC vocabulary | none | `Sources/RVIPC/IPCMethods.swift`, `Sources/RVIPC/IPCEnvelope.swift`, `Sources/RVService/ServiceRuntime.swift`, `Sources/RVService/PendingIPC.swift`, `Tests/RVIPCTests/**`, `Tests/RVServiceTests/FakeXPCUnixSocketTests.swift`, `Tests/RVServiceTests/PendingResolveGrantTests.swift`, `Tests/RVServiceTests/PendingDispatchTests.swift` | AC-401, AC-402, AC-403 | 101–1499 |

T1, T2, T3, T4 do not share exclusive-writes. Parallel.

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit in RVScanTests, RVCLITests only if ScanCommand tests exist and must compile (prefer not to add CLI tests; T1 CLI change is a mapping). RVHooksTests, RVPolicyTests, RVIPCTests, RVServiceTests.
- **Frameworks**: Swift Testing. No XCTest. No live HOME.
- **CI**: `tools/gate.sh RVScanTests` (T1; include RVCLITests if ScanCommand compile requires it), `RVHooksTests` (T2), `RVPolicyTests` (T3), `RVIPCTests` then `RVServiceTests` (T4).
- **Coverage**: illegal decode combos, exhaustive window filter, host JSON byte identity, consume-key does not spend.

# 7. Rationale & Context

Prior type-system specs closed Decision/outcome, HelloAck, pack-door vs Ask, WorkingDirectory, SetupHostKind, LiveEvaluation, PackIndex PackID. Remaining holes are local boolean/string soup on scan, hook voice, honor-path rows, and leftover IPC cases WV-T2 named but did not finish.

# 8. Dependencies & External Integrations

- **PLT-001**: Swift 6.3.3, language mode 6, macOS 26.
- **DAT-001**: allow-once jsonl keys unchanged. `rv.ipc.v1` engine strings and explain stage kebab-case unchanged.
- **COM-001**: Host deny JSON is the block; do not change keys.

# 9. Examples & Edge Cases

```swift
// T1
_ = ScanTimeWindow.lastDays(7)
_ = ScanTimeWindow.all.filter(findings, now: now) // ignores 7

// T2
codec.encodeDeny(reason: text, rule: deny.ruleID, next: .ttyHint)
AllowOnceUnlockCode(validating: "abc") == nil

// T3
// json: {"kind":"consumed"} without consumed_at → throw
// json: {"kind":"granted","consumed_at":"..."} → throw

// T4
ExplainStage(name: .quickReject, elapsedMs: 0)
// JSON name: "quick-reject"
```

# 10. Validation Criteria

Each ticket: `tools/gate.sh` for that ticket’s test targets green. No new `TODO`/`FIXME` in production. No `RV_BYPASS`. Host JSON / jsonl / engine-string bytes as specified.

# 11. Related Specifications / Further Reading

- `spec/spec-architecture-type-system-handshake-ask.md`
- `spec/spec-architecture-type-system-honor-host.md`
- `spec/spec-architecture-type-system-live-wire.md`
- `spec/spec-architecture-wire-vocabulary.md` (WV-T2 leftovers)
- `docs/architecture/MODULES.md`
- HTML: `swift-type-system-review-rv-20260910-042559.html`
