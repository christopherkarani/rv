---
title: Functional evolution — review-session reducer, sealed revision log, idle-exit policy, owner-gate refusals, MCP setup plan/apply
version: 1.0
date_created: 2026-11-10
owner: rv architecture pipeline (run 643e16, swift-functional-codebase-evolution)
tags: architecture, functional-core, RVOperatorUI, RVPolicy, RVService, RVCLI, RVMCP
---

# Introduction

Five places where a decision is fused with effects or mutable state, making
it either racy, untestable without the world, or copied by hand. Each ticket
pulls the decision into a pure value or function and leaves a thin shell
that owns I/O, locks, timers and UI. Two tickets carry confirmed defects
and fix them first (T1a operator-UI selection race, T5 MCP setup partial
application); the rest are behavior-preserving except where a ticket names
the exact user-visible change allowed.

Report: `swift-functional-evolution-rv-20261110-0035.html` (session
scratchpad). Base commit: `2569eb88` (`origin/main` at run start). Each
implementer re-verifies line numbers on their ticket branch.

## 1. Purpose & Scope

Purpose: same inputs → same decision, tested without HOME, temp trees,
real timers, XPC, or interleaving luck.

In scope: tickets T1a, T1b, T2, T3, T4, T5 (§5b).

Out of scope (do not touch, do not relitigate):

- Typed `MachinePolicyRoot`/`RepoPolicyRoot` for TypedRuleStore (deferred
  follow-up after T2; runtime guard in `PolicyWorkspace.revisionRepoStore`
  already closes the hazard).
- Ceremony review-seat drift in RVService (Workspace lets any UI cancel an
  unbound review; Action/Hook refuse) — a product question, raised
  separately.
- `CustodianIdleWatchdog`, remote MCP session protocol, judge-runtime
  globals, RuntimeAdmissionEvent derived fields, HostTable.
- Hook notice auto-dismiss on poll and arrival-baseline quirks in
  `HookReviewModel` — preserve exactly in T1b; flag only.
- Anything in open PRs #532–#554. No ticket here writes a file those PRs
  touch.
- Toolchain, deployment target, `Package.swift`. New files inside an
  existing target directory need no manifest edit.

Audience: implementers, fresh-context reviewers. Assumes Swift 6.4,
`swiftLanguageModes: [.v6]`, macOS 15 floor + Linux CI, Swift Testing.

## 2. Definitions

- **review session**: the operator UI's per-window state for one review
  kind — connection, item list, current selection, last status, notice.
- **stale reply**: an async bridge reply whose request no longer matches the
  current selection/challenge.
- **sealed revision log**: `policy-revisions-machine.log` + tip + key; the
  HMAC chain that makes machine policy history tamper-evident.
- **display log**: the human-readable revision JSONL that must agree with
  the sealed log.
- **phase** (idle exit): `serving(inFlight, generation)`,
  `draining(inFlight)`, `exited`.
- **owner gate**: the TTY + device-owner authentication ceremony in front of
  allow-once redeem/mint, egress approve/deny and allowlist changes.
- **setup plan**: the pure result of deciding every MCP host-config rewrite
  before any file is written.

## 3. Requirements, Constraints & Guidelines

- **REQ-001**: No ticket changes a public signature except where named
  (T5 adds one error case; T4 changes no public API).
- **REQ-002**: Each pure core is constructible and testable with no
  `FileManager`, `ProcessInfo`, `Date()`, timers, XPC or `Task.sleep`.
- **SEC-001** (T1a/T1b): the operator UI may only authenticate/complete/deny
  the bundle whose ID equals the displayed selection. Invariant:
  `bound == nil || id(bound) == selectedID`.
- **SEC-002** (T2): sealed-log bytes (log, tip) are byte-identical before and
  after; golden fixtures captured from pre-move code pin it on macOS and
  Linux (CryptoKit vs swift-crypto).
- **SEC-003** (T5): every host entry rv rewrote has a manifest record whose
  `written` equals the file contents; a missing record is never allowed, an
  extra one is harmless.
- **CON-001**: Effects run outside locks (`IdleWatchdog.onFire`, store
  writes stay under the existing lock order: log lock → file lock).
- **CON-002**: User-visible wording is byte-identical unless the ticket lists
  the change.
- **GUD-001**: TDD — characterization/regression test first, then move.

## 4. Interfaces & Data Contracts

Sketches; implementers may adjust names, not shape.

### T1b — `Sources/RVOperatorUI/ReviewSession.swift`

```swift
enum DenyStrategy { case cancelByID, denyBoundChallenge }
protocol ReviewMode {                   // caseless enums LaunchReview / ActionReview / HookReview
    associatedtype ID: Hashable & Sendable
    associatedtype Item: Equatable & Sendable
    associatedtype Bundle: Equatable & Sendable
    associatedtype Status: Equatable & Sendable
    static func id(of: Item) -> ID
    static func id(of: Bundle) -> ID
    static func challengeID(of: Bundle) -> UUID
    static func isTerminal(_: Status) -> Bool
    static var denyStrategy: DenyStrategy { get }
    static var authenticationReason: String { get }
    static func unavailableNotice(_: Bundle) -> String?                       // Hook only
    static func notAuthenticatedNotice(_: UIAuthenticationOutcome) -> String? // nil = complete anyway
}
struct ReviewSession<Mode: ReviewMode>: Equatable, Sendable {
    enum Selection { case none, binding(ID), unbound(ID), bound(Bundle), authorizing(Bundle),
                     bindingToDeny(ID), denying(ID, Bundle?) }
    mutating func reduce(_ event: Event) -> [Command]
    // events: connectRequested, connectReplied, listReplied(gen:), selectTapped, bindReplied(ID, _),
    //         allowTapped, authenticated(challenge:_:), completeReplied(challenge:_:), denyTapped,
    //         denyReplied(ID,_), dismissNotice
    // commands: connect, list(gen:), bind(ID), authenticate(Bundle), complete(Bundle, outcome),
    //           deny(Bundle), cancel(ID)
}
struct ArrivalLedger { baseline(_:), observe(_:), open(_:) }   // Hook unseen tracking, pure
```

The three `@Observable @MainActor` models keep their public properties (now
computed from `session`) and async methods (now `send(event)` loops that
run commands until the queue is empty).

### T2 — `Sources/RVPolicy/MachineRevisionLog.swift` (module-internal)

```swift
enum MachineRevisionLog {
    struct Record: Sendable, Equatable { revision, prev, mac, recordedAtMs, toml, document }
    struct VerifiedChain: Sendable {      // only verify/fresh/absent construct it
        let records: [Record]; fileprivate let key: SymmetricKey?
        var generations: [Record] { get }; var sealedHead: Record? { get }
    }
    enum Reconciliation: Equatable { case unchanged, sealTail(toml: String, recordedAtMs: Int64) }
    struct Appended { chain, head, logBytes: Data, tipBytes: Data }
    static func classifyAbsent(policyFileExists:remnantExists:) throws(TypedRuleStoreError) -> VerifiedChain
    static func verify(logBytes:tipBytes:keyBytes:) throws(TypedRuleStoreError) -> VerifiedChain
    static func checkDisplay(_:matches:) throws(TypedRuleStoreError)
    static func reconcile(_:display:liveTOML:) -> Reconciliation
    static func appending(toml:at:to:) throws(TypedRuleStoreError) -> Appended
    static func rollbackTarget(generation:in:) throws(TypedRuleStoreError) -> (target: Record, sealedHead: Record)
}
```

`TypedRuleStore` gains internal `init(baseDirectory:now:)`; public
`init(baseDirectory:)` unchanged. Same `#if canImport(CryptoKit)` import as
today.

### T3 — `Sources/RVService/IdleExitPolicy.swift` (internal)

```swift
enum IdleExitPolicy {
    enum Phase: Equatable { case serving(inFlight: Int, generation: UInt64), draining(inFlight: Int), exited }
    enum Event: Equatable { case start, begin, end(stale: Bool), idleTimer(UInt64, stale: Bool),
                            grantsChecked(UInt64, live: Bool), staleTick(stale: Bool) }
    enum Effect: Equatable { case armIdle(UInt64), armStaleCheck, checkGrants(UInt64), exit }
    static func admits(_: Phase) -> Bool
    static func reduce(_: Phase, _: Event) -> (Phase, [Effect])
}
struct IdleExitScheduler: Sendable {      // closure struct
    var after: @Sendable (Duration, @escaping @Sendable () -> Void) -> Void
    var detach: @Sendable (@escaping @Sendable () async -> Void) -> Void
    static func dispatch(label: String) -> IdleExitScheduler
}
```

`IdleWatchdog` public surface unchanged; internal init gains
`scheduler: = .dispatch`. Sample `stale` only when the reducer will read it
(do not add a stat per timer fire while in flight).

### T4 — `Sources/RVCLI/OwnerGateRefusal.swift` (internal)

A classifier, not typed throws: the ceremony bodies call untyped RVPolicy
stores and `CLIOwnerAuth`, `ctx.requireHome()` throws `ExitCode` that must
pass through, and ~20 tests assert domain errors directly.

```swift
enum OwnerGateRefusal: Error, Sendable, Equatable, CaseIterable {
    case ttyRequired, robotRefused, changedDuringReview, authRequired, throttled, storeUnavailable
    enum Subject: Sendable { case grant, proposal, allowlistEntry }
    init?(_ error: any Error)     // AllowOnceError, AllowOnceAuthError, EgressReviewError, AllowlistStoreError;
                                  // inner switches exhaustive — a new case is a compile error
    func text(subject: Subject) -> String
    func message(command: String, subject: Subject) -> (text: String, exitCode: Int32)   // exit 2
}
extension CommandContext {
    func failOwnerGate(_ error: any Error, command: String, subject: OwnerGateRefusal.Subject) throws -> Never
    // gate refusal → stderr + exit 2; anything else (ExitCode included) rethrown unchanged
}
```

### T4s — CLI output sink (test seam)

`final class CLIOutputCapture: Sendable` (`Mutex<(stdout, stderr)>`);
`CLIProcess.Context.output: CLIOutputCapture?`; `CommandContext.writeStdout/
writeStderr` append to it when installed, else write to `FileHandle` as now;
`withCLIProcess(…, output:)` returns captured text.

### T5 — `Sources/RVMCP/MCPHostSetupPlan.swift` (internal)

```swift
struct MCPHostSnapshot { file: MCPHostFile; contents: MCPInventory.HostFile; isSymbolicLink: Bool }
struct MCPSetupPlan { prior: [MCPSetupRecord]; writes: [Write]  /* one per distinct path */
                      report: MCPSetupResult; func manifest(written: Set<String>) -> [MCPSetupRecord] }
struct MCPUndoPlan  { records; writes; report; func manifest(written:) -> [MCPSetupRecord] }
extension MCPHostSetup {
    static func plan(snapshots:manifest:configuration:servers:rvPath:) -> Result<MCPSetupPlan, MCPSetupError>
    static func planUndo(manifest:snapshots:host:servers:) -> Result<MCPUndoPlan, MCPSetupError>
    static func apply(_: MCPSetupPlan, write:saveManifest:) -> Result<MCPSetupResult, MCPSetupError>
    static func apply(_: MCPUndoPlan, write:saveManifest:) -> Result<MCPSetupResult, MCPSetupError>
}
public enum MCPSetupError { ... ; indirect case partial(applied: MCPSetupResult, cause: MCPSetupError) }
```

Ordering: setup saves the manifest once as intent (prior + all planned
records) before any write; on partial failure, best-effort re-save with
prior + records of written paths only. Undo writes files first, retires
records last (as today). All deterministic refusals (symlink, comments,
unreadable) are decided in `plan`, before any write. Entries for the same
path (`~/.claude.json` user and project scopes) fold over one evolving JSON
root → one write per path.

## 5. Acceptance Criteria

Per ticket in §5b. Global:

- **AC-001**: `swift build --build-tests` and `swift test` green on macOS;
  Linux CI green (T2 especially).
- **AC-002**: No public signature diff beyond REQ-001 exceptions; views and
  `Sources/rv-operator-ui/main.swift` unchanged.
- **AC-003**: `~/.config/rv` untouched by `swift test` (existing CI check).

## 5b. Tickets (task graph)

| id | title | depends-on | review-hint |
|---|---|---|---|
| T1a | fix: operator UI drops stale bind replies; deny is busy | none | 101–1499 |
| T1b | refactor: one `ReviewSession` reducer for the three review models | T1a | 101–1499 |
| T2 | refactor: sealed revision log as a pure `MachineRevisionLog` | none | ≥1500 (TypedRuleStore.swift) |
| T3 | refactor: `IdleExitPolicy` reducer + injected scheduler | none | 101–1499 |
| T4s | test: CLI output sink on `CLIProcess.Context` | none | 101–1499 |
| T4 | refactor: one owner-gate refusal table for CLI + TUI | T4s | 101–1499 |
| T5 | fix: `rv mcp setup`/`--undo` as plan → apply | none | 101–1499 |

Frontier at start: T1a, T2, T3, T4s, T5 (no shared write paths).

### T1a — operator UI stale-reply + deny-busy fix

- **specialist**: swift-concurrency, swift-testing-pro
- **exclusive-writes**: `Sources/RVOperatorUI/{ReviewModel,ActionReviewModel,HookReviewModel}.swift`,
  `Tests/RVOperatorUITests/*ReviewModel*Tests.swift` (the three existing files)
- **work**: after every bind `await`, apply the reply only if `selectedID`
  still equals the requested ID (failures included); a private busy state
  set across `deny()` that blocks `select`/`allowOnce`/`authorize`; launch
  `deny()` cancels the displayed (bound or selected) review only when
  `bound`/`selectedID` agree. Gated fakes in tests.
- **acceptance**:
  - `staleBindReplyNeverOverwritesNewerSelection` (×3 models),
    `denyInFlightBlocksAllowAndSelect`, `launchDenyTargetsDisplayedReview`
    fail on `2569eb88` and pass.
  - Existing tests pass with only fake additions; prompt and notice text
    unchanged.

### T1b — `ReviewSession` reducer

- **specialist**: swift-functional-core, swift-type-system-architecture, swift-testing-pro
- **exclusive-writes**: new `Sources/RVOperatorUI/{ReviewSession,ReviewModes,ArrivalLedger,OperatorUIErrorText}.swift`;
  the three model files; new `Tests/RVOperatorUITests/{ReviewSessionTests,ArrivalLedgerTests}.swift`
- **work**: §4 T1b. Behavior table (Launch/Action/Hook differences) is the
  `ReviewMode` conformance — deny strategy, terminal sets, Hook
  `allowOnceAvailable` gate and not-authenticated notices, Hook arrivals and
  `maintain()`. Out-of-order list replies dropped by generation.
- **acceptance**:
  - T1a regression tests pass unchanged.
  - Pure tests cover every `Selection` transition and assert SEC-001 after
    every event in scripted sequences.
  - Model files shrink (≈660 → ≈210 lines + ≈250 core); views/main.swift no diff.

### T2 — `MachineRevisionLog`

- **specialist**: swift-functional-core, swift-type-system-architecture, swift-testing-pro
- **exclusive-writes**: new `Sources/RVPolicy/MachineRevisionLog.swift`,
  `Sources/RVPolicy/TypedRuleStore.swift`, new
  `Tests/RVPolicyTests/{MachineRevisionLogTests,MachineRevisionLogFixtures}.swift`,
  `Tests/RVPolicyTests/{PolicyRevisionLogTests,PolicyRevisionTests}.swift`
- **work**: commit 1 = characterization only (golden log/tip/key/jsonl/toml
  bytes from current code embedded as literals; HMAC known-answer vectors
  from an independent `openssl dgst -hmac`). Commit 2 = move verify, append,
  encode, MACs, reconcile decision, generations, display agreement,
  missing-log classification, rollback target. Keep reconcile's `try?`
  read semantics; keep `[.sortedKeys]` encoder and `.rounded()` ms.
- **acceptance**:
  - Golden fixture verifies and round-trips byte-identically after the
    move on macOS and Linux CI.
  - `TypedRuleStore.swift` contains no `HMAC<`, `compressedGenerations`,
    `checkJsonlMatchesSealed`, `nowMs`, or `Date()`; `VerifiedChain` cannot be
    built outside its file.
  - All RVPolicyTests + RVCLITests policy suites pass; tamper tests in the
    listed files move to byte-level pure tests.

### T3 — `IdleExitPolicy`

- **specialist**: swift-functional-core, swift-concurrency, swift-testing-pro
- **exclusive-writes**: `Sources/RVService/IdleExit.swift`, new
  `Sources/RVService/IdleExitPolicy.swift`,
  `Tests/RVServiceTests/IdleExitTests.swift`, new
  `Tests/RVServiceTests/IdleExitPolicyTests.swift`
- **work**: §4 T3. Interpreter: `Mutex<(phase, requestCount)>`, one
  `send(_:) -> Bool` applying `reduce` under the lock and running effects
  after unlock; `[weak self]` timer closures. `ManualIdleScheduler`
  (`advance(by:)`, `runDetached()`) in tests.
- **acceptance**:
  - Public API and the four callers have no diff; IdleExit /
    PeerSessionPing / UnixSocketListener / LinuxUnixSocket suites green on
    macOS + Linux.
  - At most one wall-clock test (`dispatchSchedulerSmoke`); every pinned
    behavior has a named reduce test.
  - Exhaustive sequence test (length ≤ 6): `.exit` emitted at most once,
    only from inFlight 0; re-entrant `hasLiveGrants → beginRequest` test passes.

### T4s — CLI output sink

- **specialist**: swift-testing-pro, swift-concurrency
- **exclusive-writes**: `Sources/RVCLI/CLIProcess.swift`,
  `Sources/RVCLI/CommandContext.swift` (write functions only),
  `Tests/RVCLITests/CLITestSupport.swift`, the 4 `captureStdout`/
  `captureStderr` call sites' test files
- **work**: §4 T4s. Migrate the 4 dup2-based capture call sites to the sink
  and delete `captureStdout`/`captureStderr`. Direct `FileHandle` writes
  elsewhere (e.g. `CLIOwnerAuth.swift:52`, MCP/Workspace/OpenCode commands)
  are out of scope; list them in the PR.
- **acceptance**:
  - `withCLIProcess(…, output:)` returns stdout/stderr text; no test uses
    dup2 capture.
  - Production output unchanged when no capture is installed.
  - RVCLITests green under `timeout` on macOS and Linux.

### T4 — owner-gate refusal table

- **specialist**: swift-type-system-architecture, swift-testing-pro
- **exclusive-writes**: new `Sources/RVCLI/OwnerGateRefusal.swift`,
  new `Tests/RVCLITests/{OwnerGateRefusalTests,EgressCommandRunTests}.swift`;
  `Sources/RVCLI/AllowOnceCommand.swift` (three `run()` ladders),
  `Sources/RVCLI/Commands/EgressCommand.swift` (approve/deny ladders),
  `Sources/RVCLI/AllowlistCommand.swift` (three ladders),
  `Sources/RVCLI/Commands/WorkspaceReviewQueue.swift` (`refusal`);
  `Tests/RVCLITests/{AllowOnceCommandRunTests,AllowlistCommandRunTests}.swift`,
  `Tests/RVWorkspaceTUITests/WorkspaceReviewQueueTests.swift` (or wherever it lives).
  Do not touch `OwnerConfirmation.swift`, `ServiceClient.swift` (#549),
  Managed/Packs/Scan commands (#546), `CLIOwnerAuth.swift`, RVPolicy.
- **work**: §4 T4. Each site keeps its domain-specific catches and ends with
  `catch { try ctx.failOwnerGate(error, command:, subject:) }` as the LAST
  clause. TUI `refusal(_:)` starts with the classifier.
- **canonical wording** (exit 2): tty "requires an interactive TTY (stdin
  and stdout)"; robot "--json/--robot refused"; changed — grant "grant
  changed during review; retry with a fresh code", proposal "proposal
  changed during review; retry"; auth "device-owner authentication
  required"; throttled "too many authentication prompts; wait and retry";
  store "store unavailable".
- **allowed text changes**: mint TTY prefix → `rv allow-once mint:`; clear
  and the three allowlist verbs gain "(stdin and stdout)"; redeem drops "for
  redeem", egress drops "for approve/deny"; TUI "robot output refused" →
  "--json/--robot refused". No other text changes.
- **acceptance**:
  - No `catch` of the gate cases (AllowOnceError tty/robot/
    redemptionChanged/lock/encode/collision, AllowOnceAuthError,
    EgressReviewError.storeUnavailable, AllowlistStoreError) in RVCLI
    outside `OwnerGateRefusal.swift`.
  - Parameterized classifier table (every case of the 4 enums + ExitCode,
    ValidationError, CocoaError) and golden message table pass; CLI tests
    assert stderr text via T4s, not just `ExitCode(2)`.
  - Non-gate errors including `ExitCode` pass through unchanged; merged-with-
    main tree builds.
- **known gap (flag in PR, do not fix)**: allowlist owner-auth refusal comes
  from `OwnerConfirmation.require` as a `ValidationError` (exit 64, usage
  dump, prompts before the TTY gate) — follow-up after #549 merges.

### T5 — MCP setup plan → apply

- **specialist**: swift-functional-core, swift-testing-pro
- **exclusive-writes**: `Sources/RVMCP/MCPHostSetup.swift` (setup/undo
  section), new `Sources/RVMCP/MCPHostSetupPlan.swift`,
  `Sources/RVCLI/Commands/MCPCommand.swift` (setup/undo rendering block
  only), `Tests/RVMCPTests/MCPHostSetupTests.swift`, new
  `Tests/RVMCPTests/MCPHostSetupPlanTests.swift`
- **work**: §4 T5. Characterization first on disk:
  `setupRoutesUserAndProjectScopesInOneClaudeJSON` + undo restores both.
  `setup`/`undo` public signatures unchanged (thin wrappers: snapshot →
  plan → apply). MCPCommand renders `.partial` applied lines then fails with
  the cause.
- **allowed behavior changes**: deterministic refusals now write nothing
  (previously earlier files were already written); `~/.claude.json` gets one
  write + one backup per run instead of two; `.partial` reports what was
  applied.
- **acceptance**:
  - Symlink / comments / unreadable in file 2 → nothing written, including
    file 1. Write failure in file 2 → command reports file 1's routing and
    backup; manifest holds exactly prior + written-path records.
  - Both `~/.claude.json` scopes routed in one write; undo restores both.
  - Plan tests touch no filesystem; `swift test --filter MCPHostSetup` green.

## 6. Test Automation Strategy

- Swift Testing, `@testable import` for internal cores.
- Pure tests for every core; a small number of wiring tests stay on disk /
  timers (named per ticket).
- Gated fakes (continuations released by the test) for async ordering in
  T1a/T1b — no sleeps.
- CI: existing `swift build --build-tests` + `swift test` on macOS and Linux.

## 7. Rationale & Context

- T1a before T1b: the fix is ~30 lines and its regression tests become the
  refactor's safety net.
- T2 moves encode and decode together: splitting only `verify` would put the
  wire encoder and decoder in different files — where byte drift comes from.
- T3 Phase enum is exact: `draining` with inFlight 0 never persists (both
  setters move straight to exit under the same lock), and admission is
  refused once exiting.
- T5 manifest-as-intent: an extra record is harmless (undo checks the
  current value equals `written`), a missing one is unrecoverable.

## 8. Dependencies & External Integrations

None new. CryptoKit (Darwin) / swift-crypto (Linux) already in RVPolicy.

## 9. Examples & Edge Cases

- T1: select A (slow bind) → select B → B replies → A replies → Allow must
  complete B only.
- T2: identical re-save seals a duplicate record; generations compress it.
- T3: request arrives while the async grants check runs → exit cancelled.
- T5: `~/.claude.json` user + project scope both route in one write.

## 10. Validation Criteria

Per-ticket acceptance + AC-001..003; fresh-context review per ticket
(size-routed), then a fresh final pass.

## 11. Related Specifications / Further Reading

- `spec/spec-architecture-27dc7ddd-deepening.md` (prior run)
- `CONTEXT.md` (domain glossary)
