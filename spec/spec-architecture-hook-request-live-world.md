---
title: Typed HookRequest sum and LiveEvaluateWorld gate inputs
version: 1.0
date_created: 2026-09-15
last_updated: 2026-09-15
owner: rv
tags: [architecture, hooks, service, evaluate, swiftify]
---

# Introduction

Execute the two Strong candidates from `$TMPDIR/swift-architecture-review-rv-20260915-041431.html` (HEAD `8ef53e4`).

1. **T1** — `HookRequest` is a closed sum `.shell` / `.file` / `.spend`. Top recommendation (type half of C01).
2. **T2** — `LiveEvaluateWorld` owns Policy-gate inputs (store, clock, home, lazy allowlist). C02. Parallel with T1.
3. **T3** — `HookEvaluateWorld` is one ports value. Wire `HookDoor` / `ServiceRuntime` / `ServiceClient` miss. C01 ports half. Depends on T1 and T2.

Do not execute worth-exploring C03 (setup materializer) or C04 (MachineConfig). Do not fold XPC miss into `HookDoor` (cli-thin CL2). Do not reopen the evaluation door, PolicyGate, File tool honor path, Hook mapper, EvaluationWorld pack assembly, SessionScan, GitPushForceConstraint, FilesystemAnalysisWorld, DenialLedgerRecord, ProposedAction IR (OPE-156), or `Decision.ask`.

Audience: fresh-context implementer and reviewer subagents. Toolchain: Swift 6.3.3 (`tools/swift-6.3.3`), language mode 6, macOS 26 + Linux aarch64/x86_64. Gate: `tools/gate.sh`. Warm `.build`. Never `swift package clean`. After the first compile in a worktree, `git restore Package.resolved` unless this ticket owns dependency changes.

# 1. Purpose & Scope

Make two illegal programs unrepresentable, and hide one leaked assembly:

- `HookRequest` with a file tool, a spend intent, and an empty `ShellCommand` at once.
- A live evaluate call that passes `AllowOnceStore` from one home and an `AllowlistStore` loaded from another.
- Seven optional closures copied in `ServiceRuntime.makeHookEvaluateResult` and `ServiceClient.hookEvaluate`.

## In scope

- RVHooks `HookRequest`, codec `decode` constructors, `hookBody` control flow, `HostCodec.proposedAction`.
- RVService `LiveEvaluateWorld` wrapping existing `GatedEvaluate` + stores.
- RVCLI `CommandRun.evaluateCommand` using that world.
- RVService `HookDoor` + `ServiceRuntime` hook evaluate wiring.
- RVCLI `ServiceClient` in-process miss wiring (EvaluationRoute stays).

## Out of scope

- Setup host materializer (C03).
- Typed `config.json` / MachineConfig (C04). Analytics hexagon stays a leaf.
- Folding miss into `HookDoor`.
- Changing host deny JSON keys, honor exit codes, or leftover-ask-as-permit law.
- `SessionIdentity` / `AgentIdentity` → `SessionID` / `HookHost` (pending JSON freeze).
- `GatedEvaluate` PolicyGate behavior, T13 skip-on-allow, mint/spend semantics.
- C `rv` hook. Host adapter templates.

# 2. Definitions

| Term | Meaning |
|---|---|
| Hook request | What a codec decoded from host stdin. Closed over shell, file tool, or same-turn spend. |
| Shell request | Executing command for pack + semantic evaluate. |
| File request | Read / Edit / Write catalog path. Packs never see it. |
| Spend request | Host Ask confirm callback. Policy gate plant+spend this turn. |
| HookEvaluateWorld | Required ports for a live hook door: evaluate, evaluateFile, spend, mint, record, clear. |
| LiveEvaluateWorld | Owns session assembly, AllowOnceStore, home, clock, and the T13 lazy allowlist. Callers name peek / apply / spend / runFile. |
| Miss | `EvaluationRoute` chose in-process. Still uses the same worlds. Not a third evaluate implementation. |
| T13 | Allow and indeterminate never invoke the allowlist loader. |

# 3. Requirements, Constraints & Guidelines

## T1 — HookRequest sum

- **REQ-101**: Replace the optional-soup struct with a closed enum in `Sources/RVHooks/HostCodec.swift`:

  ```swift
  public enum HookRequest: Equatable, Sendable {
      case shell(host: HookHost, command: ShellCommand, cwd: WorkingDirectory?, session: SessionID?)
      case file(host: HookHost, file: FileToolAction, cwd: WorkingDirectory?, session: SessionID?)
      case spend(host: HookHost, command: ShellCommand, cwd: WorkingDirectory?, session: SessionID?)
  }
  ```

  Associated labels may be a nested struct per case if the enum payload is too wide; the three cases are the law.

- **REQ-102**: No stored `file: FileToolAction?`, no stored `hostAsk: HostAskHookIntent?`, no `command` on the file case, no `init(session: String?)`. Session is `SessionID?` already validated at decode (`firstNonEmpty` then `SessionID(validating:)`).

- **REQ-103**: Computed `host`, `cwd`, `session` may exist so `HookDoor.recordPending` keeps compiling. Do **not** add computed `command` that returns `ShellCommand(rawValue: "")` for `.file`.

- **REQ-104**: Each codec `decode`:
  - File-tool match (existing `FileToolAction.decoded`) → `.file`. File wins over a spend flag on the same envelope (today’s `if let file` precedence).
  - Else `hostAsk` maps to `HostAskHookIntent.spend` → `.spend` (command required, missing command stays `.malformed(.missingCommand)`).
  - Else non-empty command → `.shell`.
  - Foreign / malformed unchanged.

- **REQ-105**: `hookBody` switches on `HookRequest` exhaustively. `.file` → `hookFileBody`. `.spend` → existing spend path (missing `spendHostAsk` still fail-closed incomplete). `.shell` → evaluate + mint + record. Empty file path still malformed.

- **REQ-106**: `HostCodec.proposedAction(from:)` switches: `.shell` / `.spend` keep today’s fingerprint + `supportingCommand`. `.file` is not an empty-command shell action; do not call this default for the file door.

- **REQ-107**: Keep the seven-closure `hookWire(...)` signature in T1 so T3 can replace it. T1 is the request type, not the ports type.

- **REQ-108**: Tests that read `request.command` / `request.hostAsk` / `request.file` pattern-match the enum. `GrokHookTests` equality against `.request(HookRequest(...))` uses the new cases.

- **CON-101**: Do not change `HookWire`, honor JSON, exit codes, or `HostAskHookIntent` raw value `"spend"` on the wire.
- **CON-102**: Do not edit `ServiceRuntime.swift` or `ServiceClient.swift` in T1.
- **PAT-101**: Value types only. No `class`. Prefer `some HostCodec` in `hookBody` (already generic).

## T2 — LiveEvaluateWorld

- **REQ-201**: Add `package struct LiveEvaluateWorld: Sendable` in RVService (new file `Sources/RVService/LiveEvaluateWorld.swift` preferred). It owns:

  - `GatedEvaluate` (lazy session via existing `EvaluationWorld.assemble` is allowed)
  - `AllowOnceStore`
  - `HomeDirectory?`
  - clock `@Sendable () -> Date`

- **REQ-202**: Package API (names may match style of neighbors):

  ```swift
  func peek(command:cwd:host:) async -> EvaluationResult
  func apply(command:cwd:host:) async -> EvaluationResult
  func spend(command:cwd:host:) async -> EvaluationResult
  func runFile(action:cwd:host:) -> EvaluationResult
  ```

  `host` defaults to `.tty` where today’s callers pass nothing. `tool` defaults to `.bash` for shell verbs and `.file(kind)` for `runFile`.

- **REQ-203**: The allowlist closure is constructed **inside** the world:

  ```swift
  AllowlistStore(baseDirectory: store.baseDirectory)
      .loadUserSnapshot(workspacePath: cwd.map(\.rawValue), now: now)
  ```

  T13 remains: `GatedEvaluate.gated` must still skip invoking that loader on allow/indeterminate. Do not move that skip into callers.

- **REQ-204**: `CommandRun.evaluateCommand` uses `LiveEvaluateWorld.peek`. It must not construct the allowlist closure itself.

- **REQ-205**: Do **not** change `GatedEvaluate.run` / `peek` / `apply` / `spendHostAsk` parameter lists in T2. ServiceRuntime and ServiceClient keep compiling against the old bag until T3.

- **REQ-206**: Mint stays `GatedEvaluate.mintUnlockCode` until T3. T2 may expose `var store: AllowOnceStore` or a `mintUnlockCode` forwarder if tests need it; do not duplicate mint logic.

- **CON-201**: Do not import RVCLI from RVService. Do not open a TTY. No live HOME tests.
- **CON-202**: Do not edit `Sources/RVHooks/**` in T2.
- **CON-203**: Peek does not spend grants. Apply spends. Spend is host-Ask plant+spend. Same as today.

## T3 — HookEvaluateWorld + live wiring

- **REQ-301**: Add `package struct HookEvaluateWorld: Sendable` with **required** (non-optional) ports:

  ```swift
  var evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult
  var evaluateFile: @Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult
  var spend: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult
  var mintOnDeny: @Sendable (EvaluationResult, WorkingDirectory?) async -> String?
  var recordHostAsk: @Sendable (HookRequest, ProposedAction) async throws -> Void
  var clearHostAsk: @Sendable (HookRequest, ProposedAction) async throws -> Void
  ```

  Test helpers may build a world whose file/spend ports return the same incomplete deny `HookWire` as today’s missing-closure path **inside the port**, not by omitting the port.

- **REQ-302**: `hookWire(host:stdin:world:)` and `HookDoor.run(host:stdin:world:)` take `HookEvaluateWorld`. Remove the seven-optional-closure public/package overloads from production call sites. A test-only overload that fills incomplete ports is allowed in tests, not in `Sources/`.

- **REQ-303**: `ServiceRuntime.makeHookEvaluateResult` builds one world from `LiveEvaluateWorld` + existing pending record/clear. No inline `AllowlistStore` closure.

- **REQ-304**: `ServiceClient` in-process miss builds the same world shape. XPC success path unchanged. `EvaluationRoute.path` still chooses xpc vs inProcess. Do not fold miss into `HookDoor`.

- **REQ-305**: `ServiceRuntime` evaluate / spend / explain / classify / pending peek use `LiveEvaluateWorld` (no copied allowlist closures). `CommandRun` already migrated in T2.

- **REQ-306**: `hookBody` missing-port fail-closed paths: if a test world is used, file/spend ports must still produce `incompleteEvalSentence` when the test intends that. Production worlds always have real ports.

- **CON-301**: Do not change IPC method names or `HookEvaluateReply` keys.
- **CON-302**: Do not fold TTY `rv test` through `HookDoor`.
- **CON-303**: Pending `SessionIdentity(rawValue: session.rawValue)` conversion stays until a later identity ticket.

## Shared constraints

- **CON-401**: Hexagon: Engine never imports CLI/TUI/XPC. Hooks never import Service. Analytics never sees command text.
- **CON-402**: No `RV_BYPASS`. No `try!` / `!` on production paths. No live HOME tests.
- **CON-403**: Value types in Domain/Engine/Hooks/Presentation. `class` only at XPC/`NSObject` edge (untouched).
- **GUD-401**: Smallest interface that names the domain operation. Do not add a protocol for one production world.
- **PAT-401**: TDD: failing test → minimal fix → `tools/gate.sh <Target>Tests`.

# 4. Interfaces & Data Contracts

## HookRequest (T1)

| Case | Evaluate door | Mapper command |
|---|---|---|
| `.shell` | `evaluate(command, cwd)` | `command` |
| `.file` | `evaluateFile(file, cwd)` | existing file-tool deny copy; no empty `ShellCommand` |
| `.spend` | `spend(command, cwd)` then `intent: .afterSpend` | `command` |

Wire envelopes still use JSON `hostAsk: "spend"`. That string is not stored on the request.

## LiveEvaluateWorld (T2)

Construct with `home`, optional explicit `GatedEvaluate` / `AllowOnceStore` / clock for tests. Nil home is day-one walk (EvaluationWorld law).

## HookEvaluateWorld (T3)

Production builder (name flexible):

```swift
HookEvaluateWorld.live(
    evaluate: world,
    host: HookHost,
    pending: (any PendingApprovalCoordinating)?
)
```

binds:

- `evaluate` / `spend` / `runFile` → `LiveEvaluateWorld` with `LedgerHost.hook(host)`
- `mintOnDeny` → `GatedEvaluate.mintUnlockCode` / world forwarder
- `record` / `clear` → existing `HookDoor.recordPending` / `clearPending`

# 5. Acceptance Criteria

- **AC-101**: Given Claude stdin with a Read tool path, When decode runs, Then the request is `.file` and there is no `ShellCommand(rawValue: "")` in the value.
- **AC-102**: Given Pi stdin with `hostAsk: "spend"` and a bash command, When decode runs, Then the request is `.spend` and `request.hostAsk` does not exist as a field.
- **AC-103**: Given a file envelope that also carries `hostAsk: "spend"`, When decode runs, Then the request is `.file` (file wins).
- **AC-104**: `HookRequest(host:command:cwd:session:hostAsk:file:)` does not compile.
- **AC-201**: Given `CommandRun.evaluateCommand`, When a command allows, Then the allowlist loader is not invoked (T13). Prove with a counting loader or existing skip test migrated onto the world.
- **AC-202**: Given apply on an unlockable deny with a grant, When `LiveEvaluateWorld.apply` runs, Then the grant is spent the same as today’s `GatedEvaluate.apply`.
- **AC-203**: `ServiceRuntime.swift` still compiles after T2 without edits (old `GatedEvaluate` bag remains).
- **AC-301**: `ServiceRuntime.makeHookEvaluateResult` and `ServiceClient.hookEvaluate` in-process miss contain one world construction, not seven optional closures.
- **AC-302**: Given transport miss, When `ServiceClient.hookEvaluate` runs, Then EvaluationRoute still chose inProcess; behavior matches T1 doors.
- **AC-303**: `grep -n "AllowlistStore(baseDirectory" Sources/RVService/ServiceRuntime.swift Sources/RVCLI/Service/ServiceClient.swift Sources/RVCLI/CommandRun.swift` is empty after T3.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | Close `HookRequest` as `.shell` / `.file` / `.spend` | none | `Sources/RVHooks/HostCodec.swift`, `Sources/RVHooks/HookDispatch.swift`, `Sources/RVHooks/GrokHostCodec.swift`, `Sources/RVHooks/PiHostCodec.swift`, `Sources/RVHooks/OpenCodeHostCodec.swift`, `Sources/RVHooks/ClaudeHostCodec.swift`, `Sources/RVHooks/OpenClawHostCodec.swift`, `Sources/RVHooks/HermesHostCodec.swift`, `Sources/RVHooks/CodexHostCodec.swift`, `Sources/RVHooks/CursorHostCodec.swift`, `Tests/RVHooksTests/` | AC-101–104; `tools/gate.sh RVHooksTests` | 101–1499 |
| T2 | `LiveEvaluateWorld` owns gate inputs; CommandRun peek uses it | none | `Sources/RVService/LiveEvaluateWorld.swift` (create), `Sources/RVCLI/CommandRun.swift`, `Tests/RVServiceTests/LiveEvaluateWorldTests.swift` (create), `Tests/RVCLITests/` files that compile against `CommandRun.evaluateCommand` allowlist (edit only those tests that fail to compile or that this ticket must migrate; do not drive-by the rest of RVCLITests) | AC-201–203; `tools/gate.sh RVServiceTests` then `tools/gate.sh RVCLITests` | 101–1499 |
| T3 | `HookEvaluateWorld` + ServiceRuntime/ServiceClient wiring | T1, T2 | `Sources/RVService/HookDoor.swift`, `Sources/RVService/ServiceRuntime.swift`, `Sources/RVCLI/Service/ServiceClient.swift`, `Sources/RVHooks/HookDispatch.swift` (ports signature only), `Tests/RVServiceTests/HookEvaluateTests.swift`, `Tests/RVCLITests/HookCommandTests.swift`, `Tests/RVCLITests/HookDispatchTests.swift` | AC-301–303; `tools/gate.sh RVServiceTests` then `tools/gate.sh RVCLITests` then `tools/gate.sh RVHooksTests` | 101–1499 |

If a test file outside the exclusive list fails to compile because it constructed the old `HookRequest` or the seven-closure door, the ticket that introduced the break **owns** that file — grep and include it rather than leaving the package unbuildable (exclusive-writes are a collision fence, not a compile set). Do not use that clause to edit `SetupRun.swift` or PolicyGate.

T1 and T2 are the frontier (parallel). T3 starts only after both are merged to the ticket branches this run uses as its base.

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit in RVHooksTests (T1), RVServiceTests + RVCLITests (T2, T3).
- **Frameworks**: Swift Testing. No XCTest. No live HOME.
- **CI**: `tools/gate.sh` as in the ticket table. First compile: `git restore Package.resolved` if resolve rewrote it.
- **Coverage**: decode three cases; file-wins-spend; T13 skip; miss still in-process; no leftover `AllowlistStore(baseDirectory` at the three live files after T3.
- **TDD**: write the failing test first for each ticket.

# 7. Rationale & Context

File tool (#203) and Host Ask pending/spend (#189, #211) landed on a `HookRequest` struct of optionals and a seven-closure `hookWire`. `EvaluationWorld` already hid pack assembly; Policy-gate *inputs* still leak to ServiceRuntime (5 copies), ServiceClient (2), CommandRun (1). C01+C02 close those without redoing the gate or the mapper.

# 8. Dependencies & External Integrations

- **PLT-001**: Swift 6.3.3, language mode 6, macOS 26, Linux aarch64/x86_64.
- **INF-001**: `tools/gate.sh` + `tools/swift-6.3.3`. Warm `.build`.
- **COM-001**: Host deny JSON is the block. Do not change keys. Do not emit Claude leftover `permissionDecision: "ask"`.
- **DAT-001**: No persisted `HookRequest`. Pending JSON identity strings unchanged.

# 9. Examples & Edge Cases

```swift
// T1 decode
GrokHostCodec().decode(readJSON) // .request(.file(...))
PiHostCodec().decode(spendJSON)  // .request(.spend(..., command: "git reset --hard", ...))
// HookRequest(host: .pi, command: ..., hostAsk: .spend, file: nil) // does not compile

// T2
let world = LiveEvaluateWorld(home: home, store: store, clock: { now })
await world.peek(command: cmd, cwd: cwd, host: .tty)
// allow → allowlist loader not called

// T3
HookDoor.run(host: .claude, stdin: stdin, world: HookEvaluateWorld.live(...))
// ServiceClient miss: EvaluationRoute.inProcess, same world, not HookDoor-as-client
```

# 10. Validation Criteria

Each ticket: listed `tools/gate.sh` green. No new `TODO`/`FIXME` in production. No `RV_BYPASS`. `git restore Package.resolved` if the first worktree resolve rewrote it. Hexagon imports unchanged. After T3, AC-303 grep is empty.

# 11. Related Specifications / Further Reading

- `spec/spec-architecture-cli-thin.md` (CL2 withdrawn: do not fold miss into HookDoor)
- `spec/spec-architecture-file-tool-secrets.md` / file-tool door
- `CONTEXT.md` EvaluationWorld, Policy gate, File tool, EvaluationRoute
- `docs/architecture/MODULES.md`
- HTML: `swift-architecture-review-rv-20260915-041431.html`
