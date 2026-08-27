---
title: CLI thin. EvaluationRoute, seal EnabledPacks, drop Engine from CLI
version: 1.1
date_created: 2026-08-24
date_revised: 2026-08-27
owner: rv factory
tags: [architecture, cli, refactor]
---

# CLI thin

Deepen `RVCLI` without a new SPM target. Decision stays out of the shell. ArgumentParser, TTY, and setup mutations stay.

This revision matches the tree after `arch-evaluation-door.md`. Do not re-assemble EvaluationWorld. Do not fold CLI hook miss into `HookDoor`.

Vocabulary: `CONTEXT.md` (EvaluationRoute, EvaluationWorld, Matching view). Graph: `.grok/skills/swift-hexagonal-spm`. No new library. No new executable.

## 1. Purpose

Three leftovers, not three new modules.

1. **EvaluationRoute.** Client transport + advertised service semver → `EvaluationPath`. Today `ServiceClient.evaluate` and C `is_major_skew` treat unparseable advertised semver as compatible and trust XPC.
2. **Seal EnabledPacks.** `EvaluationWorld` already assembles. `EnabledPacks.resolve` is still a second public door.
3. **Matching view door.** CLI still imports `RVEngine` to call `Normalize`. Service already imports Engine.

## 2. Already landed (do not redo)

| Thing | Where | Law |
|---|---|---|
| `EvaluationWorld` assembly | `Sources/RVService/EvaluateWorld.swift` (`package enum`) | `resolveSnapshots`, `coverage`, `makeSession`, `assemble` → lazy `GatedEvaluate`. Walk vs compile is `WalkedPackIDs` / `CompiledPackIDs` / `PackCoverage`. |
| `HookDoor` | `Sources/RVService/HookDoor.swift` | Server XPC door around `hookWire`. `ServiceRuntime` already calls it, including `spendHostAsk`. |
| CLI hook miss | `Sources/RVCLI/Commands/HookCommand.swift` | Calls `hookWire` and returns `(stdout, stderr, exitCode)`. Codex stderr lives here. |
| `HookDispatch` | `Sources/RVCLI/Hook/HookDispatch.swift` | Argv fast-path. Keep. |
| `HookRun` | gone | Do not recreate. |

`HookEvaluateReply` has no `stderr`. Routing CLI miss through `HookDoor` would drop Codex stderr (fail-open) and drop Host Ask. That ticket is withdrawn. Adding `stderr` to the wire is a later IPC change, not this spec.

## 3. Non-goals

- A fourteenth library (`RVOperator`, `RVCLICore`, …).
- Changing host deny voice, pack parse, or evaluate order.
- Sharing Swift with `Sources/rv-c`. C stays an adapter of the same client table.
- `package` visibility sweep across Presentation/IPC.
- Relitigating foreign/malformed → allow.
- Folding CLI hook miss into `HookDoor`.
- Replacing `EvaluationWorld` with a pack-ID bag.
- `MatchingViewNormalizer` or any protocol for one `Normalize` call.
- Editing `Package.swift`. CLI may still *list* `RVEngine`; source must not `import` it after CL4.
- Doctor / Hello `isMajorSkew` on `ServiceClient.route`. Unparseable Hello `serviceSemver` is a follow-up.
- Changing `ProtocolVersion.isMajorSkew` or `ServiceRuntime.isMajorSkewed` (server: empty client → not skew).
- `docs/factory/PLAN.md` (no product-law conflict).

## 4. Constraints

- **CON-001**: Hexagonal arrows unchanged. Types go down. CLI may drop `import RVEngine`; it must not gain `RVPacks`.
- **CON-002**: `EvaluationRoute.path(for:)` is pure. No `Date()`, `FileManager`, `ProcessInfo`, XPC. Pack resolution is I/O; it is not this function.
- **CON-003**: Closed enums. No `transportPresent: Bool`. Result is `EvaluationPath`.
- **CON-004**: Unparseable, missing, or empty advertised **service** semver on a present evaluate/hookEvaluate reply is **inProcess** / C miss-replay. Cannot prove compatibility.
- **CON-005**: Absent or empty **client** semver on the server Hello/frame path stays legacy-compatible (`ServiceRuntime.isMajorSkewed` empty → not skew). Do not implement CON-004 by flipping `isMajorSkew` / `isMajorSkewed` / C `is_major_skew` to true on parse failure.
- **CON-006**: Wire `rv.ipc.v1` unchanged. `EvaluateReply.via` still decodes only `.xpc`.
- **CON-007**: No `try!` / `!` / new `preconditionFailure`. No `@_exported`. Value types only.
- **CON-008**: Route Decision tests live in `RVIPCTests` (pure) and `RVCLITests` (adapter). C unit + proof consume the same rows. A test that needs a TTY to prove a route Decision is in the wrong module.
- **CON-009**: `tools/gate.sh` on touched targets. Warm `.build`.
- **CON-010**: `EnabledPacks` is not a public door after CL3. Walk vs compile law unchanged: empty enabled means none; compile still unions day-one.

## 5. Ticket order

```
CL1 EvaluationRoute     (client table; unparseable advertised → inProcess)
CL3 Seal EnabledPacks   (may run ∥ CL1; disjoint files)
        │
        ▼
CL4 Matching view door  (after CL3; shares EvaluateWorld.swift + ServiceRuntime.swift)
```

CL2 is withdrawn. See §2.

| Ticket | Outcome | Exclusive files | Gate |
|---|---|---|---|
| **CL1** | `EvaluationRoute.path(for:)` in `RVIPC`. `ServiceClient.evaluate` and C miss-replay are adapters. Unparseable/empty advertised service semver → inProcess / miss. | `Sources/RVIPC/EvaluationRoute.swift` (new), `Sources/RVCLI/Service/ServiceClient.swift` (evaluate only), `Sources/rv-c/evaluation_route.h` (new), `Sources/rv-c/rv.c` (call site only), `Sources/rv-c/tests/evaluation_route_test.c` (new), `Sources/rv-c/tests/run.sh`, `Tests/RVIPCTests/EvaluationRouteTests.swift` (new), `Tests/RVCLITests/FallbackSkewTests.swift` (add rows), `tools/c-hook-proof.sh` (unparseable spoof) | `tools/gate.sh RVIPCTests RVCLITests`; `Sources/rv-c/tests/run.sh`; `tools/c-hook-proof.sh` unparseable row |
| **CL3** | `EnabledPacks` is not public. Walk goes through `EvaluationWorld`. `PackCoverage` law unchanged. | `Sources/RVService/EnabledPacks.swift` (package or delete), `Sources/RVService/EvaluateWorld.swift` (walk helper only), `Sources/RVService/GatedEvaluate.swift` (`makeRequest` walk), `Sources/RVService/ServiceRuntime.swift` (spend/rebuild + comments; not explain), `Tests/RVServiceTests/EnabledPacksTests.swift`, `Tests/RVServiceTests/EvaluateWorldTests.swift`, `Tests/RVServiceTests/EvaluateDoorTests.swift` (if walk assertions move), `Tests/RVServiceTests/HookEvaluateTests.swift` (comment only) | `tools/gate.sh RVServiceTests` |
| **CL4** | No `import RVEngine` under `Sources/RVCLI`. Mint/allowlist take `ShellCommand`. Render uses `result.matchingView`. Same explain fallback removed in `ServiceRuntime`. | `Sources/RVService/EvaluateWorld.swift` (`matchingView(of:)`), `Sources/RVCLI/RVCLI.swift`, `Sources/RVCLI/CommandRun.swift`, `Sources/RVCLI/AllowOnceCommand.swift`, `Sources/RVCLI/AllowlistCommand.swift`, `Sources/RVService/ServiceRuntime.swift` (explain normalize line only), `Tests/RVCLITests/AllowOnceTTYTests.swift` (mint signature) | `tools/gate.sh RVCLITests RVServiceTests` |

Do not edit `ProtocolVersion.swift` or `ServiceRuntime.isMajorSkewed` in any ticket.

## 6. CL1. EvaluationRoute

### Bug

`ProtocolVersion.isMajorSkew` returns false when either side fails to parse. That is correct for the **server** (CON-005).

Client evaluate does this today:

```swift
guard let advertised = reply.serviceSemver else { return await inProcessRoute() }
if ProtocolVersion.isMajorSkew(clientSemver: ProtocolVersion.serviceSemver, serviceSemver: advertised) {
    return await inProcessRoute()
}
return RoutedEvaluation(result: reply.result, path: .xpc)
```

`""` and `"not-a-version"` pass the guard. `isMajorSkew` is false. The client trusts XPC. C `has_service_semver` + `is_major_skew` has the same hole. No test covers advertised `"not-a-version"`. Product law: never allow because XPC missed.

### Interface (locked)

Who chooses the type: the implementation. One hidden function. Closed result already exists (`EvaluationPath`). No protocol. Two adapters (Swift client, C hook) make the seam real.

```swift
public enum EvaluationRoute: Sendable {
    public enum Facts: Sendable, Equatable {
        /// Transport missing, send threw, or no evaluate reply was decoded.
        case transportAbsent
        /// Decoded evaluate / hookEvaluate reply. `via == .xpc` already enforced.
        case reply(clientSemver: String, advertisedServiceSemver: String?)
    }

    /// Returns the client evaluation path for these facts.
    /// Missing, empty, or unparseable advertised service semver cannot prove compatibility.
    public static func path(for facts: Facts) -> EvaluationPath
}
```

`let` facts. No `transportPresent: Bool`. No mutable stored properties. Noun `path(for:)`.

Implementation uses `ProtocolVersion.major(of:)`. It does **not** call `isMajorSkew` (that boolean cannot say "unprovable").

### Total map

| facts | path |
|---|---|
| `.transportAbsent` | `.inProcess` |
| `.reply` advertised `nil` or `""` | `.inProcess` |
| `.reply` advertised unparseable | `.inProcess` |
| `.reply` client unparseable or `""` | `.inProcess` |
| `.reply` both parseable, majors differ | `.inProcess` |
| `.reply` both parseable, majors equal | `.xpc` |

`1.0.0` vs `1.9.9` is `.xpc`. `1.0.0` vs `2.0.0` is `.inProcess`.

### Adapters

**`ServiceClient.evaluate`**

Call `path` only when a reply exists. Nil transport, send throw, decode / id / protocol failure, and non-evaluate results stay `inProcessRoute()` (invalidate as today). That is the same outcome as `.transportAbsent`. Do not switch `path(.transportAbsent)` in the adapter: the `.xpc` arm would be a dead `preconditionFailure`.

Decode still rejects `via != .xpc` before facts. On `.evaluate(reply)`:

```swift
switch EvaluationRoute.path(for: .reply(
    clientSemver: ProtocolVersion.serviceSemver,
    advertisedServiceSemver: reply.serviceSemver
)) {
case .xpc:
    return RoutedEvaluation(result: reply.result, path: .xpc)
case .inProcess:
    transport.invalidate()
    return await inProcessRoute()
}
```

Leave `route()` / `skewReason` / Hello `isMajorSkew` alone.

**C**

Add `Sources/rv-c/evaluation_route.h` with `static inline` `rv_semver_major` and `rv_should_miss_replay(client, service)`.

- `service == NULL` or `""` or either major unparseable → 1 (miss).
- majors differ → 1.
- majors equal → 0 (trust).

`rv.c` includes the header. After a parsed hookEvaluate reply:

```c
if (rv_should_miss_replay(
        RV_CLIENT_SEMVER,
        reply.has_service_semver ? reply.service_semver : NULL))
{
    rv_hook_reply_free(&reply);
    miss_replay(argv, host, stdin_buf.p, stdin_buf.len);
}
```

Do not change `is_major_skew` semantics. If it becomes unused, delete it so `-Wall` stays clean. Do not add a `.c` that `release.sh` / `c-hook-proof.sh` would have to compile; keep the table in the header so existing clang lines stay.

XPC send failure still `miss_replay` before this function (transport absent).

### Tests

`Tests/RVIPCTests/EvaluationRouteTests.swift` covers every row in the table, including `transportAbsent`, advertised `nil` / `""` / `"not-a-version"`, unparseable client, `1.0.0` vs `1.9.9`, `1.0.0` vs `2.0.0`.

`FallbackSkewTests`: advertised `"not-a-version"` and `""` on an allow-shaped XPC reply still deny `git reset --hard`, path `.inProcess`, transport invalidated. Existing nil-semver and `2.0.0` rows stay.

`Sources/rv-c/tests/evaluation_route_test.c` asserts `rv_should_miss_replay` for every reply-row (not `transportAbsent`). `run.sh` compiles and runs it.

`tools/c-hook-proof.sh`: copy the AC-003 skew spoof with `"serviceSemver":"not-a-version"`. Empty allow from that listener must miss and still deny `git reset --hard`.

## 7. CL3. Seal EnabledPacks

`EvaluationWorld` already exists as a `package enum` assembly door. Do not introduce a second type with that name. Do not publish:

```swift
public struct EvaluationWorld { public var enabledPacks: [PackID] }
```

That shape drops walk vs compile and fights `PackCoverage`.

### Interface (locked)

```swift
package enum EvaluationWorld {
    // existing: resolveSnapshots, coverage, makeSession, assemble

    /// Walk set from config. Nil or unreadable HOME is day-one. Empty config is empty.
    package static func walkedPackIDs(home: HomeDirectory?) -> WalkedPackIDs
}
```

`coverage(catalog:home:)` calls `walkedPackIDs` when catalog is nil. Body is today's `EnabledPacks.resolve`.

`GatedEvaluate.makeRequest` reads `EvaluationWorld.walkedPackIDs(home:).ids`. It may stay as the wire-request builder. It must not name `EnabledPacks`.

`ServiceRuntime` spend/rebuild uses `EvaluationWorld.walkedPackIDs(home: configHome)`. Update the warm-rvd comment that names `EnabledPacks.resolve`.

`EnabledPacks` becomes `package` and is referenced only from `EvaluateWorld.swift`, or the file is deleted. `rg 'EnabledPacks' Sources` after CL3 is at most that file plus analytics `noteEnabledPacks` (different type).

### Tests

Move `EnabledPacksTests` cases onto `EvaluationWorld.walkedPackIDs` / `coverage`:

- nil home → day-one walk
- fresh home → day-one walk
- extras resolve beyond day-one
- disabled `core.git` stays off the **walk** and remains on **compile**

`EvaluateDoorTests` `makeRequest` day-one assertions stay. Do not weaken `empty enabled means none`.

## 8. CL4. CLI drops Engine

`MODULES.md`: CLI must not own regex or pack parse. `Normalize` is Engine. Graph may still list `RVEngine`; after CL4 no file under `Sources/RVCLI` imports it.

### Interface (locked)

On the existing door, not a new enum:

```swift
extension EvaluationWorld {
    /// T1 matching view for grant mint, allowlist, and explain render.
    package static func matchingView(of command: ShellCommand) -> MatchingView {
        Normalize.matchingView(of: command.rawValue)
    }
}
```

`EvaluateWorld.swift` gains `import RVEngine` (Service already depends on Engine). No `MatchingViews`. No `t1` at the call site.

### Call sites

| Site | After |
|---|---|
| `RVCLI.swift` `import RVEngine` | Delete that import only. |
| `CommandRun` re-normalize when `matchingView.isEmpty` | Delete. Render `result.matchingView.rawValue`. |
| `ServiceRuntime.explain` same empty fallback | Delete. Same render of `result.matchingView`. |
| `AllowOnceCLI.mint` | `command: ShellCommand`. `EvaluationWorld.matchingView(of: command)`. |
| Allowlist add / remove | `ShellCommand` then `EvaluationWorld.matchingView(of:)`. Remove still passes the raw string plus matching-view alias into the store as today. |

ArgumentParser still joins argv to a string, then `ShellCommand(rawValue:)`. Tests (`AllowOnceTTYTests`) pass `ShellCommand(rawValue:)`.

Grant fingerprint stays SHA-256 of Matching view. Mint still requires TTY and refuses robot. Policy still stores `MatchingView`, never raw argv.

`rg 'import RVEngine' Sources/RVCLI` is empty. `rg 'Normalize\\.' Sources/RVCLI` is empty.

## 9. Type rules for implementers

- Value types only. No `class` in these tickets.
- `EvaluationRoute.path(for:)` is total: every `Facts` row has one `EvaluationPath`.
- `EvaluationWorld.walkedPackIDs` does I/O (config). Do not call it a functional core.
- `Date()` stays at `GatedEvaluate` apply/peek call sites.
- Prefer concrete enums. Do not add `any` or a protocol for a single adapter.
- If two modules need a type, it goes in the lower one (`RVIPC` for the route, `RVService` for the world).
- Public only when another module's production code must name it. `EvaluationRoute` is public (`RVIPC` product + CLI). World helpers stay `package`.

## 10. Done when

- `EvaluationRoute.path(for:)` exists. Client evaluate and C miss-replay use it. Advertised `"not-a-version"` and `""` still deny `git reset --hard`.
- `ProtocolVersion.isMajorSkew` still returns false when a side fails to parse. `ServiceRuntime.isMajorSkewed` still treats empty client as not skew.
- `HookRun` still absent. CLI hook miss still returns `wire.stderr`. `HookDoor` still server-only.
- `EnabledPacks.resolve` is not public (or the type is gone). Callers use `EvaluationWorld`.
- `import RVEngine` is gone from `Sources/RVCLI`.
- `CONTEXT.md` Avoid lines match the code.
- `tools/gate.sh RVIPCTests RVServiceTests RVCLITests` green; `Sources/rv-c/tests/run.sh` green; C proof unparseable row green.
