---
title: Deep-module refactors for RVIsolation, RVEngine, and RVCLI
version: 1.0
date_created: 2026-10-09
owner: swift-architecture-pipeline run 10a882e7
tags: [architecture, deep-modules, refactor]
---

# Introduction

This spec turns six Strong deepening candidates from the 2026-10-09
architecture review into an implementable ticket DAG. Each ticket deepens one
module: more behavior behind a smaller interface, with no observable behavior
change. Discovery report (outside repo):
`/var/folders/ns/xmz0zmpj7p148vdgr4bwzp8h0000gn/T/architecture-review-20261009-012907.html`.

## 1. Purpose & Scope

Purpose: reduce architectural friction in the three hottest modules
(RVIsolation, RVEngine shell pipeline, RVCLI) by collapsing shallow mirrors,
unwired duplicates, and scattered concepts into deep modules.

Scope: six tickets (T1-T6). In scope: production code under
`Sources/RVIsolation`, `Sources/RVEngine`, `Sources/RVCLI` and their tests.
Out of scope: Worth-exploring and Speculative candidates (I-3, E-3, E-4, C-3,
C-4), toolchain changes, new product behavior.

Audience: implementer subagents (fresh context, spec + ticket only) and
reviewer subagents.

## 2. Definitions

- **Module**: anything with an interface and an implementation.
- **Interface**: everything a caller must know (signatures, invariants,
  ordering, errors, config).
- **Depth**: behavior per unit of interface. Deep = small interface, large
  implementation. Shallow = interface nearly as complex as implementation.
- **Seam**: location where behavior can change without editing there; where a
  module's interface lives.
- **Adapter**: concrete thing satisfying an interface at a seam.
- **Leverage**: caller payoff from depth. **Locality**: maintainer payoff
  (change/bugs/verification concentrate in one place).
- **RV**: the repo's Swift CLI product. **PTY**: pseudo-terminal.
- **Golden test**: test pinning exact output text for fixed inputs.

## 3. Requirements, Constraints & Guidelines

- **REQ-001**: T1 shall leave exactly one lifecycle decider: either the
  supervisor routes close/recovery decisions through
  `WorkspaceLifecycleTransition`, or `Sources/RVIsolation/Lifecycle/` is
  deleted and equivalent coverage tests the supervisor's real behavior.
- **REQ-002**: T2 shall collapse the 1:1:1:1 terminal forwarding chain
  (client / wire / server / supervisor / RuntimeTerminal) so each terminal
  operation is defined once and the wire error map is defined once.
- **REQ-003**: T3 shall fuse `classifyStage` and its three documented mirrors
  (`maskedSegments`, `typedInvocationPrefix`, `collectTopLevelAssignmentValues`)
  into one derivation pass producing view plus side-channels in one result.
- **REQ-004**: T4 shall consolidate redirect-operator recognition (Tokenize,
  NormalizeSegments, NormalizeArgv, Normalize) behind one operator grammar
  module with narrow per-callsite queries.
- **REQ-005**: T5 shall move per-command prologue (home acquisition, appearance
  resolution, output emission, exit codes) behind one command context that
  commands receive; the two robot/pretty paths shall become one.
- **REQ-006**: T6 shall move the launch-and-attach session pump out of
  `WorkspaceCommand.swift` behind one seam on the isolation side; workspace,
  TUI, and opencode frontends become thin adapters over it.
- **CON-001**: No observable behavior change. All goldens, vectors, and
  fixtures must pass unmodified unless the ticket explicitly re-pins a golden
  whose bytes change only by refactoring (requires reviewer approval).
- **CON-002**: No toolchain, SwiftPM target, or minimum-OS changes.
- **CON-003**: A ticket may only write its `exclusive-writes` paths.
- **CON-004**: No new `TODO`/`FIXME` in production code.
- **CON-005**: Public interfaces used by other SwiftPM targets keep source
  compatibility unless the breaking change is contained within one ticket's
  exclusive paths and all callers migrate in that ticket.
- **GUD-001**: Prefer deletion over new abstraction (I-1: deletion is an
  acceptable outcome).
- **GUD-002**: Follow the codebase-design vocabulary in code comments and PR
  bodies (module, interface, seam, adapter, depth, leverage, locality).
- **GUD-003**: Mirror the `SetupFlow`/`SetupIntent` shape for T5 (in-repo
  template). Mirror `IsolationBackend` factories for seam design where a new
  seam is introduced.

## 4. Interfaces & Data Contracts

No new external APIs. Per-ticket interface direction (implementer designs the
concrete shape; reviewer checks depth):

- T1: one decider interface `(State, Event) -> (State, Effects)` consumed by
  the supervisor as effect interpreter, OR no Lifecycle module at all.
- T2: one terminal dispatch; one `TerminalControlError -> wire code` map at
  the wire seam; queue-plus-protocol interaction in one owned module.
- T3: one pass result bundling classified view + masked lexemes + erased
  prefix + assignment-value budget.
- T4: one redirect grammar module; callsites query (tokenizer / segment /
  argv views) without re-scanning raw text.
- T5: one command context value (home, appearance, emit, exit) constructed
  once per invocation; commands keep argv shape + run/render logic.
- T6: one session-engine interface taking a launch request
  (project/profile/runtime kind, stdio policy) and owning PTY, bridge,
  resize, event pump, and exit propagation.

## 5. Acceptance Criteria

- **AC-001**: Given the base commit test suite, When a ticket lands, Then the
  full `swift test` suite passes with zero failures.
- **AC-002**: Given each ticket's before-tree, When the ticket lands, Then no
  golden/vector/fixture file outside its exclusive-writes changes bytes.
- **AC-003**: Given T1 lands, When grepping production sources, Then either
  `WorkspaceLifecycleTransition` has production callers or `Lifecycle/` no
  longer exists.
- **AC-004**: Given T5 lands, When grepping `Sources/RVCLI`, Then the
  `HOME is not set` stanza appears in exactly one module.
- **AC-005**: Given T3 lands, When grepping `Sources/RVEngine`, Then no
  "mirror" comment justifies a duplicated strip sequence.

## 5b. Tickets (task graph)

Frontier at start: T1, T3, T5. Chains serialize on shared files
(WorkspaceSessionSupervisor.swift, Normalize.swift, Commands/*). T6 needs T2
because the session engine lands on the isolation side.

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | Rewire or remove the shadow lifecycle state machine (I-1) | none | `Sources/RVIsolation/Lifecycle/**`, `Sources/RVIsolation/WorkspaceSessionSupervisor.swift`, `Sources/RVIsolation/WorkspaceRecovery.swift`, `Tests/RVIsolationTests/WorkspaceLifecycleTests.swift`, `Tests/RVIsolationTests/WorkspaceRecoveryTests.swift` | 1. AC-003 holds. 2. Close-leader election + retryable-vs-terminal close covered through the surviving interface. 3. `swift test --filter RVIsolationTests` green. | >=1500 |
| T2 | Collapse the terminal control-plane mirror (I-2) | T1 | `Sources/RVIsolation/WorkspaceHostClient.swift`, `Sources/RVIsolation/WorkspaceHostServer.swift`, `Sources/RVIsolation/WorkspaceSessionSupervisor.swift`, `Sources/RVIsolation/RuntimeTerminal.swift`, `Sources/RVIsolation/TerminalStream.swift`, `Sources/RVIsolation/WorkspaceControlProtocol.swift`, `Tests/RVIsolationTests/WorkspaceClientQueueTests.swift`, `Tests/RVIsolationTests/TerminalStreamTests.swift` | 1. Each terminal op defined once; wire error map defined once. 2. testing-only setters `testingSetSupportsEnsureTerminalRuntime`, `testingSetSupportsResourceProfiles`, `testingInjectMalformedTerminalFrame` removed or unused. 3. `swift test --filter RVIsolationTests` green. | >=1500 |
| T3 | Fuse the matching-derivation fan-out (E-1) | none | `Sources/RVEngine/ShellPipeline/Pipeline.swift`, `Sources/RVEngine/NormalizeInvocation.swift`, `Sources/RVEngine/Normalize.swift`, `Tests/RVEngineTests/**` | 1. AC-005 holds; one pass yields view + side-channels. 2. All engine goldens pass byte-identical. 3. `swift test --filter RVEngineTests` green. | 101-1499 |
| T4 | Unify redirect-operator lexing (E-2) | T3 | `Sources/RVEngine/ShellPipeline/Tokenize.swift`, `Sources/RVEngine/NormalizeSegments.swift`, `Sources/RVEngine/NormalizeArgv.swift`, `Sources/RVEngine/Normalize.swift`, `Tests/RVEngineTests/**` | 1. One grammar module; four callsites query it. 2. `>&1`, `&>>`, `<>`, `>|`, fd-prefixed forms behave identically (goldens green). 3. `swift test --filter RVEngineTests` green. | 101-1499 |
| T5 | Deepen the per-command context (C-1) | none | `Sources/RVCLI/**`, `Tests/RVCLITests/**` | 1. AC-004 holds; one robot/pretty resolution path. 2. `OutputModeResolver` deleted or absorbed. 3. `swift test --filter RVCLITests` green. | 101-1499 |
| T6 | Move the session engine behind the isolation seam (C-2) | T5, T2 | `Sources/RVCLI/Commands/WorkspaceCommand.swift`, `Sources/RVCLI/Commands/WorkspaceTUICommand.swift`, `Sources/RVCLI/Commands/OpenCodeCommand.swift`, `Sources/RVCLI/Commands/OpenCodePrepare.swift`, `Sources/RVIsolation/WorkspaceSession*.swift` (new files only), `Tests/RVCLITests/Workspace*`, `Tests/RVCLITests/OpenCode*`, `Tests/RVIsolationTests/Workspace*` | 1. No PTY pump code remains in `WorkspaceCommand.swift` (no `nextTerminalEvent` pump, no resize polling). 2. `#if !os(macOS)` refusal + NUL/absolute-path validation defined once and shared by run/runAgent/runCustom. 3. `swift test --filter RVCLITests` and `--filter RVIsolationTests` green. | 101-1499 |

Specialist skills per ticket: T1/T2/T6 `swift-concurrency` (supervisor/PTY
async code) + `swift-testing-pro`; T3/T4 `swift-testing-pro` (goldens);
T5 `swift-testing-pro`.

## 6. Test Automation Strategy

- **Test Levels**: Unit (goldens, vectors), Integration (supervisor/host,
  CLI runs). No new E2E harness.
- **Frameworks**: Swift Testing / XCTest as already used per target; run
  `swift test --filter <Target>Tests` per ticket, full `swift test` before PR.
- **Test Data Management**: existing goldens/vectors/fixtures; re-pin only
  with reviewer approval (CON-001).
- **CI/CD Integration**: PR CI must be green before marking ready.
- **Coverage Requirements**: no threshold change; every deleted test must have
  a surviving equivalent through the new interface (replace-don't-layer).
- **Performance Testing**: none (refactors must not regress; HookDispatch fast
  path untouched).

## 7. Rationale & Context

Hot-spot analysis (`git log --oneline -80`) shows RVIsolation supervision,
RVEngine shell pipeline, and RVCLI commands churn most; deepening there pays
back fastest. Each ticket passed an adversarial check: deletion test (would
removal concentrate complexity?), real drift evidence (mirror comments,
zero-ref greps, 15× stanza counts), and an in-repo deep-module template
(`SetupFlow`, `IsolationBackend`) proving the target shape fits this codebase.

Rejected: I-3/E-3/C-3 (Worth exploring, need product/team confirmation),
E-4/C-4 (Speculative). No ADRs exist in-repo; nothing to re-litigate.

## 8. Dependencies & External Integrations

### Technology Platform Dependencies
- **PLT-001**: Swift toolchain pinned by `.swift-version` - no migration
  (CON-002).

No external systems, services, infrastructure, data, or compliance
dependencies: pure in-repo refactor.

## 9. Examples & Edge Cases

```swift
// T5 target shape (mirrors SetupFlow/SetupIntent):
struct CommandContext { /* home, appearance, emit, exit — built once */ }
struct ScanCommand: ParsableCommand {
  func run() throws {
    let ctx = try CommandContext.current(invocation: self)
    try ScanRun.execute(args: self.args, ctx: ctx)
  }
}
```

Edge cases: T1 close-during-redeem interleavings; T2 overflow/replay-batch
backpressure; T3 assignment-value budget parity; T4 `2>&1b` mid-word splits;
T5 CI-probe behavior parity; T6 detach-on-every-exit-path parity.

## 10. Validation Criteria

- Full `swift test` green on each ticket branch after rebase on base.
- `git diff --stat` touches only exclusive-writes paths.
- No new `TODO`/`FIXME` (grep check).
- PR body links spec + ticket id and lists review skills used.

## 11. Related Specifications / Further Reading

- `spec/spec-architecture-type-system-enums.md` (prior art: type-system
  tightenings in this repo)
- HTML discovery report (outside repo, see Introduction)
