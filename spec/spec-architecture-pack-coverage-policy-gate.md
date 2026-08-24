---
title: Pack coverage newtypes and a total PolicyGate
version: 1.0
date_created: 2026-08-24
owner: rv
tags: [architecture, functional, type-system, evaluate, policy]
---

# Introduction

Execute the two Strong candidates from the 2026-08-24 functional-evolution
report (`$TMPDIR/swift-functional-evolution-rv-20260824-170706.html`):

1. **PC-T1** — name the two pack-ID worlds (walk vs compile) so they cannot be
   passed interchangeably, and stop reading process HOME inside request
   construction.
2. **PC-T2** — finish PolicyGate as a total function of values; keep consume
   atomic in the apply shell; stop minting `Date()` inside the daemon evaluate
   path.

Worth-exploring cards (setup work-plan, handshake enum) are **out of scope**.

Base SHA: `115c954` (`worktree/silver-forest-621f`). Toolchain: swift-tools 6.3
/ 6.3.3, language mode 6, macOS 26 only. Gate: `tools/gate.sh`. Never wipe
`.build` to prove a compile.

Audience: fresh-context implementer/reviewer subagents.

Collision: both tickets edit `GatedEvaluate.swift` and `ServiceRuntime.swift`.
They **serialize**: PC-T2 depends on PC-T1.

## 1. Purpose & Scope

Stop two `[PackID]` lists with opposite laws from compiling as the same type,
and stop PolicyGate tests from needing a filesystem to prove override order.

In scope: RVService pack-resolution types, GatedEvaluate request construction,
ServiceRuntime session compile set, RVPolicy PolicyGate, GatedEvaluate allowlist
load, clock injection on rvd/CLI evaluate apply.

Out of scope: collapsing walk and compile into one list; Domain/IPC
`EvaluationRequest.enabledPacks` wire change; HostCodec; handshake Bool;
setup effect algebra; analytics `[String: Any]`; RVPacks reading `config.toml`.

## 2. Definitions

| Term | Meaning |
|---|---|
| Walk set | Pack IDs this evaluate walks. Config as written. Empty included. May omit day-one. `EnabledPacks.resolve` today. |
| Compile set | Pack IDs compiled into `EvaluateSession`. Always includes day-one so catalog disable cannot uncompile required core rules. `EvaluationWorld.enabledIDs` today. |
| Pack coverage | One value holding both sets and the law that compile = walk ∪ day-one (when a catalog is present, walk comes from catalog flags then union). |
| Grant presence | Value the gate sees: none, or a live pending grant. Consume is not a presence; it is an effect that produces a status. |
| Deep module | Callers name one operation; the module owns which list to use. |

## 3. Requirements, Constraints & Guidelines

### Shared

- **CON-001**: Do not unify walk and compile into one `[PackID]`.
  `HomeSeamTests` / `EnabledPacksTests` (disable `core.git` → reset-hard allow)
  and `EvaluateWorldTests.catalogDisableCannotUncompileDayOneRules` must both
  still pass.
- **CON-002**: Hexagonal graph unchanged. RVPacks does not read HOME or
  `config.toml`. RVPolicy does not import RVPacks.
- **CON-003**: No new SPM dependencies. No public ABI promise; still keep
  `EvaluationRequest.enabledPacks: [PackID]` on the IPC wire.
- **CON-004**: Value types only in Domain/Engine/Packs/Policy. `class` stays
  at the XPC edge. No `try!` / `!` on production paths.
- **CON-005**: No `RV_BYPASS`. Down/skew still in-process evaluate. No live-HOME
  tests.
- **GUD-001**: Prefer `some`; `any` only for mixed lists. Do not add a protocol
  for `AllowOnceStore`.
- **PAT-001**: Newtypes wrap `[PackID]` with a single construction site for the
  compile-set union.

### PC-T1 — named pack coverage

- **REQ-101**: Introduce `WalkedPackIDs` and `CompiledPackIDs` (names may vary
  if clearer, but they must be distinct types) in RVService. Each is a
  `Sendable` `Equatable` value wrapping `[PackID]` with a stable ordered
  `ids` accessor. Do not put them in RVDomain (wire stays `[PackID]`).
- **REQ-102**: `PackCoverage` (or equivalent) is the only place that builds a
  compile set from a walk set: compile = walk ∪ `dayOnePackIDs` (order:
  walked order, then missing day-one appended — same as
  `EvaluationWorld.enabledIDs` today).
- **REQ-103**: `EvaluationWorld` exposes one assembly:
  `coverage(catalog:home:)` / `makeSession(coverage:snapshots:)` /
  `assemble(...)`. `enabledIDs(catalog:home:)` either becomes
  `coverage(...).compiled` or is deleted. Callers that needed the compile
  list take `CompiledPackIDs`.
- **REQ-104**: `EnabledPacks.resolve(home:)` returns `WalkedPackIDs` (or
  coverage.walked). Behavior unchanged: nil home / unreadable config →
  day-one; readable config is exact, empty included; disable core.git stays
  off the walk set.
- **REQ-105**: `GatedEvaluate.makeRequest(command:home:)` must not call
  `HomeDirectory.process()` as a default. HOME is resolved by the shell
  (`CommandRun`, `ServiceClient`, `ServiceRuntime` hook closure) and passed
  in. If `home` is nil, walk set is day-one (same as `EnabledPacks.resolve(nil)`).
- **REQ-106**: `EvaluateSession.init(enabledPacks:)` remains the **compile**
  list (`[PackID]`), so existing session tests keep compiling. Nil enabled
  packs = day-one compile set only. It must not call
  `HomeDirectory.process()` via `enabledIDs(catalog:nil, home:nil)` (today
  that leak exists). Prefer a `CompiledPackIDs` overload at package
  visibility if it is one extra initializer; do not rename the stored
  property across the module in this ticket.
- **REQ-107**: `ServiceRuntime` init, `rebuildGated`, and `listPacks`
  coverage rebuild use compile set from `PackCoverage`. Hook evaluate still
  rebuilds the **request** from `GatedEvaluate.makeRequest` / walk set so a
  warm rvd matches a cold CLI miss (`hookEvaluate_resolvesPacksFromConfig_notDayOne`).
  Wire `.evaluate` still trusts `params.request.enabledPacks` as-is (empty
  does not refill).
- **REQ-108**: `rebuildWhenUncovered(wanted:)` compares wanted walk IDs to
  compiled IDs without collapsing the types. Wanted remains the request's
  `[PackID]` (wire) converted at the boundary.

### PC-T2 — total PolicyGate

- **REQ-201**: `PolicyGate.decide` is a **sync** total function:
  `(EvaluationResult, cwd: String?, allowlist: AllowlistSnapshot, grant: GrantPresence) -> PolicyDecision`.
  No actor, no FileManager, no Date (allowlist `matches` still takes `now`
  if entries are time-bounded — pass `now` as a value).
- **REQ-202**: `GrantPresence` is a closed enum, e.g. `none | pending`. Do not
  model `.consumed` as presence; consume is the apply shell's effect.
- **REQ-203**: `apply` and `peek` keep their public signatures. They load /
  query the store, then call `decide`. One decision tree. Allowlist still
  wins over grant and must not consume (`allowlistBeforeAllowOnce`).
- **REQ-204**: `apply` still calls `store.consume` atomically on the deny path
  when allowlist misses and cwd/matchingView are nonempty. Do not
  hasGrant-then-consume. Indeterminate and allow never touch the store
  (existing tests).
- **REQ-205**: `GatedEvaluate` does not construct `AllowlistStore` from
  `store.baseDirectory` as a hidden coupling. Pass an `AllowlistSnapshot`
  (loaded at the door with an explicit `AllowlistStore` / injected snapshot).
  Tests may pass `.empty`. Production loads from the same config directory
  as today, but the dependency is a parameter, not `store.baseDirectory`
  inferred.
- **REQ-206**: `ServiceRuntime.runEvaluate` / `explain` / `classify` and
  `ServiceClient` in-process apply take `now: Date` from the caller or a
  stored clock value; they must not call `Date()` inside the evaluate
  function. `insertGranted(now: Date = Date())` test helper may keep the
  default.
- **REQ-207**: Override-order tests for `decide` run without creating a
  temp ledger directory. Existing apply/peek FS tests stay as shell tests.

## 4. Interfaces & Data Contracts

### Pack coverage (Swift, RVService)

```swift
public struct WalkedPackIDs: Sendable, Equatable {
    public var ids: [PackID]
}

public struct CompiledPackIDs: Sendable, Equatable {
    public var ids: [PackID]
}

public struct PackCoverage: Sendable, Equatable {
    public var walked: WalkedPackIDs
    public var compiled: CompiledPackIDs
}
```

`EvaluationRequest.enabledPacks` remains `[PackID]` (IPC). Convert
`coverage.walked.ids` at `makeRequest`.

### Grant presence (Swift, RVPolicy)

```swift
public enum GrantPresence: Sendable, Equatable {
    case none
    case pending
}
```

Wire unchanged. No IPC change in PC-T2.

### Product laws (must not change)

| Path | Walk | Compile | Decision on `git reset --hard` after disable `core.git` |
|---|---|---|---|
| Hook / CLI miss `makeRequest` | config | session compiled still has core | **allow** (rule not walked) |
| Session / rvd compiled packs | — | always ∪ day-one | session stays `corePacksReady` |
| Wire `.evaluate` with empty `enabledPacks` | empty | whatever session has | engine walks none; empty does not refill |

## 5. Acceptance Criteria

- **AC-101**: `EvaluationWorld` / `makeRequest` / `rebuildGated` use
  `WalkedPackIDs` vs `CompiledPackIDs`. A walk list is not passed into
  `EvaluateSession` except via `PackCoverage.compiled` (or an explicit
  compile `[PackID]` that tests already treat as compile).
- **AC-102**: Given a readable config that disables `core.git`, when hook
  evaluate runs `git reset --hard`, then decision is allow (existing
  HookEvaluate / HomeSeam tests).
- **AC-103**: Given a catalog that disables `core.git`, when a session is
  built from coverage, then `corePacksReady` is true and reset-hard still
  denies if the **request** walk set still includes `core.git`.
- **AC-104**: `GatedEvaluate.makeRequest` / `EvaluateSession()` default does
  not read `ProcessInfo.processInfo.environment["HOME"]`. Proof: grep
  those functions; HOME read stays in `HomeDirectory.process()` call sites
  at CLI/rvd edges only.
- **AC-201**: `PolicyGate.decide` is callable from a test with no
  `FileManager` temp directory and proves allowlist-before-grant,
  empty-cwd skip, indeterminate-never-honors.
- **AC-202**: Concurrent consume still CAS (existing OnceResume /
  AllowOnceStore tests).
- **AC-203**: `Date()` is absent from `ServiceRuntime.runEvaluate`,
  `explain`, `classify`.

## 5b. Tickets (task graph)

### PC-T1 — Named pack coverage

- **depends-on**: none
- **exclusive-writes**:
  - `Sources/RVService/EvaluateWorld.swift`
  - `Sources/RVService/EnabledPacks.swift`
  - `Sources/RVService/EvaluateSession.swift`
  - `Sources/RVService/GatedEvaluate.swift`
  - `Sources/RVService/ServiceRuntime.swift`
  - `Tests/RVServiceTests/EvaluateWorldTests.swift`
  - `Tests/RVServiceTests/EnabledPacksTests.swift`
  - `Tests/RVServiceTests/EvaluateDoorTests.swift`
  - `Tests/RVServiceTests/EvaluateSessionTests.swift`
  - `spec/spec-architecture-pack-coverage-policy-gate.md` (no content change
    required unless a type name differs; do not rewrite requirements)
- **acceptance**:
  - Distinct `WalkedPackIDs` / `CompiledPackIDs`; coverage constructor is the
    only union-with-day-one.
  - Existing HomeSeam / EnabledPacks / EvaluateWorld / HookEvaluate pack tests
    still pass.
  - No `HomeDirectory.process()` inside `makeRequest` or `EvaluateSession.init`.
- **review-hint**: `101–1499` (`ServiceRuntime.swift` ~474)
- **specialist**: `swift-type-system-architecture`, `swift-testing-pro`
- **gate**: `tools/gate.sh --quiet RVServiceTests RVEngineTests RVCLITests`

### PC-T2 — Total PolicyGate

- **depends-on**: PC-T1
- **exclusive-writes**:
  - `Sources/RVPolicy/PolicyGate.swift`
  - `Sources/RVPolicy/GrantPresence.swift` (create if not inlined)
  - `Sources/RVService/GatedEvaluate.swift`
  - `Sources/RVService/ServiceRuntime.swift`
  - `Sources/RVCLI/Service/ServiceClient.swift`
  - `Tests/RVPolicyTests/PolicyGateTests.swift`
  - `Tests/RVServiceTests/GatedEvaluateTests.swift`
- **acceptance**:
  - `decide` covers override order without a temp store.
  - `apply` still consumes via CAS; allowlist does not spend.
  - Daemon evaluate/explain/classify use injected `now`.
- **review-hint**: `101–1499` (`ServiceRuntime.swift`)
- **specialist**: `swift-functional-architecture`, `swift-testing-pro`
- **gate**: `tools/gate.sh --quiet RVPolicyTests RVServiceTests RVCLITests`

## 6. Test Automation Strategy

- **Test levels**: Swift Testing unit tests in `RVPolicyTests` and
  `RVServiceTests`; existing CLI HomeSeam / HookEvaluate stay regression.
- **Frameworks**: Swift Testing (`import Testing`). No XCTest. No new mocks
  for AllowOnceStore.
- **Test data**: temp HOME / allow-once dirs only for shell tests. `decide`
  tests use in-memory `AllowlistSnapshot` + `GrantPresence`.
- **CI**: `tools/gate.sh` path-inferred tests. Do not `swift package clean`.
- **Coverage**: no numeric floor. New types must have at least one test that
  would fail if walk and compile were swapped at a call site.

## 7. Rationale & Context

RVEngine.evaluate is already pure. The remaining functional cost is at
session construction: two `[PackID]` worlds and a policy gate that still
talks to an actor for logic the ledger already made a value.

Naming the lists is higher leverage than handshake enums or setup effect
algebras because a swapped list changes a Decision.

## 8. Dependencies & External Integrations

- **PLT-001**: Swift 6.3.3, macOS 26, Apple Silicon, language mode 6.
- **INF-001**: `tools/swift-6.3.3`, warm `.build`.
- **DAT-001**: Bundled pack catalog (`RVPacks` resources); day-one
  `core.git` + `core.filesystem`.

No new third-party services.

## 9. Examples & Edge Cases

```swift
// Compile from walk — day-one always present in compiled
let walked = WalkedPackIDs(ids: []) // readable config enabled none
let coverage = PackCoverage.unioningDayOne(walked)
// coverage.walked.ids == []
// coverage.compiled.ids contains core.git and core.filesystem

// Hook request uses walked, not compiled
let request = EvaluationRequest(command: cmd, enabledPacks: coverage.walked.ids)

// decide is total
let decision = PolicyGate.decide(
    denied,
    cwd: "/tmp/ws",
    allowlist: snapshot,
    grant: .pending,
    now: frozen
)
```

Empty cwd: `decide` returns override `.none` even if grant is `.pending`.
Indeterminate: override `.none`, grant ignored.

## 10. Validation Criteria

- [ ] `tools/gate.sh --quiet RVServiceTests RVPolicyTests RVCLITests RVEngineTests`
- [ ] Grep: no `HomeDirectory.process()` in `GatedEvaluate.makeRequest` or
  `EvaluateSession.init`
- [ ] Grep: no `Date()` in `ServiceRuntime.runEvaluate` / `explain` / `classify`
- [ ] Both product laws in §4 still have tests
- [ ] `PolicyGate.decide` tested without `isolatedStore()`

## 11. Related Specifications / Further Reading

- `docs/architecture/MODULES.md`
- `CONTEXT.md` (Enabled packs, Policy gate, Evaluate session)
- `spec/spec-architecture-allow-once-ledger.md`
- `spec/spec-architecture-wire-vocabulary.md` (do not reopen)
- HTML report: `/var/folders/ns/xmz0zmpj7p148vdgr4bwzp8h0000gn/T/swift-functional-evolution-rv-20260824-170706.html`
