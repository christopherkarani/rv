---
title: CLI thin — EvaluationRoute, one Hook door, EvaluationWorld
version: 1.0
date_created: 2026-08-24
owner: rv factory
tags: [architecture, cli, refactor]
---

# CLI thin

Deepen `RVCLI` without adding an SPM target. Decision leaves the shell. ArgumentParser, TTY, and setup mutations stay.

Report: `$TMPDIR/architecture-review-20260824-120438.html`.
Vocabulary: `CONTEXT.md` (EvaluationRoute, EvaluationWorld, Matching view, Hook mapper) and codebase-design (module, interface, seam, adapter, depth, locality, leverage).
Graph law: `.grok/skills/swift-hexagonal-spm`. No new library. No new executable.

## 1. Purpose

`RVCLI` is ~4k LOC because three named doors were inlined into the shell:

1. **EvaluationRoute** — transport + semver facts → `EvaluationPath`
2. **Hook door** — host stdin → Hook mapper wire (`HookDoor` vs `HookRun`)
3. **EvaluationWorld** — `HomeDirectory?` → Enabled packs

This spec extracts those doors into the modules that already own them (`RVIPC`, `RVService`). CLI becomes an adapter.

## 2. Non-goals

- A fourteenth library (`RVOperator`, `RVCLICore`, …). Deletion test fails.
- Changing host deny voice, pack parse, or evaluate order.
- Sharing Swift with `Sources/rv-c`. C stays an adapter of the same law via a golden table.
- `package` visibility sweep across Presentation/IPC (separate).
- Catalog corpus (separate).
- Relitigating foreign/malformed → allow. That stay is product law.

## 3. Constraints

- **CON-001**: Hexagonal arrows unchanged. Types go *down*. CLI may drop `import RVEngine`; it must not gain `RVPacks`.
- **CON-002**: Functional core. `EvaluationRoute.choose` is a pure function: no `Date()`, `FileManager`, `ProcessInfo`, XPC.
- **CON-003**: Closed enums. No boolean `isSkewed` at new call sites. Result is `EvaluationPath`.
- **CON-004**: Unparseable or missing `serviceSemver` on a present reply is **inProcess**. Today `isMajorSkew` returns false if either side fails to parse; that hole closes.
- **CON-005**: Absent client semver on the *server* Hello/frame path stays legacy-compatible (current `ServiceRuntime.isMajorSkewed` empty → not skew). Do not conflate client-absent with service-unparseable.
- **CON-006**: Wire `rv.ipc.v1` unchanged. `EvaluateReply.via` still decodes only `.xpc`.
- **CON-007**: No `try!` / `!` / new `preconditionFailure`. No `@_exported`.
- **CON-008**: Tests that prove the route Decision live in `RVIPCTests` (pure) and `RVCLITests` (adapter). C proof script consumes the same table. A test that needs a TTY to prove a route Decision is in the wrong module.
- **CON-009**: `tools/gate.sh` on touched targets. Warm `.build`.

## 4. Ticket order

| Ticket | Outcome | Exclusive files | Gate |
|---|---|---|---|
| **CL1** | `EvaluationRoute` in `RVIPC`. ServiceClient + C + ServiceRuntime are adapters. Unparseable service semver → inProcess. | `Sources/RVIPC/EvaluationRoute.swift` (new), `ProtocolVersion.swift`, `Sources/RVCLI/Service/ServiceClient.swift` (evaluate only), `Sources/RVService/ServiceRuntime.swift` (`isMajorSkewed` body), `Sources/rv-c/rv.c` (`is_major_skew` + table include), `Tests/RVIPCTests/EvaluationRouteTests.swift` (new), `tools/c-hook-proof.sh` table, existing `FallbackSkewTests` / `FallbackDownTests` | L1: IPC + CLI fallback + C proof |
| **CL2** | Delete `HookRun`. `Hook` calls `HookDoor.run`. | `Sources/RVCLI/Commands/HookCommand.swift`, `Tests/RVCLITests` hook dispatch tests. Do not restyle `HookDoor.swift` unless a type mismatch forces a thin wrapper. | L3 hook fixtures |
| **CL3** | `EvaluationWorld` is the caller-facing door. `EnabledPacks.resolve` becomes implementation. | `Sources/RVService/EnabledPacks.swift` (or rename file), `GatedEvaluate.swift` (`makeRequest` uses World), `EvaluateSession.swift` / `ServiceRuntime.swift` callers, `Tests/RVServiceTests/EnabledPacksTests.swift` | L1 Service |
| **CL4** | CLI drops `import RVEngine`. Mint/allowlist take `ShellCommand`; Service builds Matching view. `CommandRun` stops re-normalizing. | `AllowOnceCommand.swift`, `AllowlistCommand.swift`, `CommandRun.swift`, `RVCLI.swift`, a small `RVService` Matching-view door, matching tests | L1 CLI + Policy allow-once |

CL1 serial. After CL1: **CL2 ∥ CL3** (disjoint files). **CL4 after CL3** (Matching-view door sits next to World).

## 5. CL1 — EvaluationRoute

### Interface (locked shape)

Facts the route may see, and nothing else:

```swift
public struct EvaluationRouteFacts: Sendable, Equatable {
    public var transportPresent: Bool
    public var advertisedServiceSemver: String?
    public var clientSemver: String
}

public enum EvaluationRoute {
    /// Pure. Owns major-skew and "cannot prove compatibility".
    public static func choose(_ facts: EvaluationRouteFacts) -> EvaluationPath
}
```

Total mapping (exhaustive, no `default` that swallows a new fact):

| transportPresent | advertisedServiceSemver | choose |
|---|---|---|
| false | * | `.inProcess` |
| true | `nil` or `""` | `.inProcess` |
| true | unparseable | `.inProcess` |
| true | parseable, major ≠ client major | `.inProcess` |
| true | parseable, major == client major | `.xpc` |

`ProtocolVersion.isMajorSkew` stays as the parse+compare primitive. New call sites use `EvaluationRoute.choose`. Existing `isMajorSkew` tests remain.

`ServiceClient.evaluate` becomes:

1. Build facts from transport + reply (or skip reply when transport is nil / send throws).
2. `switch EvaluationRoute.choose(facts)` → send path or `inProcessRoute()`.
3. Wire decode still rejects `via != .xpc` before facts are built from a reply.

C `is_major_skew` must implement the same table, including unparseable → miss. Do not try to link Swift. Check in a JSON (or C header) table under `Sources/rv-c/tests/` that Swift `EvaluationRouteTests` and `tools/c-hook-proof.sh` both read.

### What stays in the adapter

- XPC send / timeout / invalidate
- `GatedEvaluate.run(.apply, …, now: Date())` — clock stays in the shell
- C JSON build, 700 ms wait, `execve rv-cli`, `_exit(2)`

### Tests

- Table-driven `EvaluationRouteTests` covering every row above.
- Existing spoofed-`via` / missing-semver / major-skew fallback tests still deny `git reset --hard`.
- New: advertised `"not-a-version"` → inProcess → still deny.
- C proof: same unparseable row.

## 6. CL2 — One Hook door

`HookRun.run` is a shallow copy of `HookDoor.run` (decode → evaluate → `hookWire`, foreign/malformed → allow).

After:

```swift
// Hook.command
let reply = try await HookDoor.run(host: host.rawValue, stdin: stdin, evaluate: evaluate)
return (reply.stdout, "", reply.exitCode)
```

Unknown host: `HookDoor` throws `IPCError`; ArgumentParser already refuses unknown `--host` before this. If a test injected a raw string, keep fail-closed (nonzero, no evaluate).

`HookDispatch` stays. It is a shallow argv fast-path and earns its keep (skips the full command tree). Do not fold it into `HookDoor`.

Tests: existing hook fixtures. Delete tests that exist only to cover `HookRun` as a type name.

## 7. CL3 — EvaluationWorld

CONTEXT already forbids `EnabledPacks.resolve` as a caller-facing door.

```swift
public struct EvaluationWorld: Sendable, Equatable {
    public var enabledPacks: [PackID]
    public static func resolve(home: HomeDirectory?) -> EvaluationWorld
}
```

Nil or unreadable HOME → Day-one packs **inside** `resolve`. Callers do not write `?? dayOnePackIDs`.

`GatedEvaluate.makeRequest` reads `EvaluationWorld.resolve(home:).enabledPacks`. External tests and `EvaluateSession` stop naming `EnabledPacks`.

`EnabledPacks` may remain as `package` implementation or be deleted if the type has no other job. Do not keep two public doors.

Tests: move `EnabledPacksTests` assertions onto `EvaluationWorld`. Same cases (nil home, unreadable, empty config, day-one).

## 8. CL4 — CLI drops Engine

`MODULES.md`: CLI must not own regex or pack parse. `Normalize` is Engine. Graph allows the import; depth does not.

| Site | After |
|---|---|
| `RVCLI.swift` `import RVEngine` | Delete. Unused. |
| `CommandRun` re-normalize when `matchingView.isEmpty` | Delete. `evaluate` already sets Matching view on every path. Render `result.matchingView`. |
| `AllowOnceCLI.mint` / allowlist add | Take `ShellCommand`. Call a Service door that returns `MatchingView` via `Normalize`. Policy still stores `MatchingView`, never raw argv. |

Service already imports Engine. One function is enough; do not invent a `MatchingViewNormalizer` protocol (one adapter = hypothetical seam).

```swift
// RVService, next to EvaluationWorld
public enum MatchingViews {
    public static func t1(of command: ShellCommand) -> MatchingView
}
```

Grant fingerprint stays SHA-256 of Matching view. Mint still requires TTY + refuses robot.

## 9. Functional / type rules for implementers

- Value types only. No `class` in these tickets.
- `EvaluationRoute.choose` and `EvaluationWorld.resolve` are total: every input row has one output; no boolean out-params.
- `Date()` stays at `GatedEvaluate` apply/peek call sites only.
- Prefer `some` / concrete enums. Do not add `any` for a single adapter.
- If two modules need a type, it goes in the lower one (`RVIPC` for the route, `RVService` for the world).

## 10. Done when

- `import RVEngine` is gone from `Sources/RVCLI`.
- `HookRun` is gone.
- `isMajorSkew(` / `is_major_skew(` have no new call sites outside `EvaluationRoute` / the C adapter of that table.
- `EnabledPacks.resolve` is not public (or does not exist).
- `tools/gate.sh RVIPCTests RVServiceTests RVCLITests` green; C proof script green.
- `CONTEXT.md` Avoid lines match the code.

Do not edit `docs/factory/PLAN.md` unless a product-law conflict appears. None is expected.
